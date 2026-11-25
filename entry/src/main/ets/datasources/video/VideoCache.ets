import { fileIo } from '@kit.CoreFileKit';
import { Context } from '@kit.AbilityKit';
import { CmsVideo } from '../../models/cms/MaccmsModels';
import { Prefs } from '../../db/Prefs';
import { Log } from '../../common/Logger';

/** 视频离线快照:详情+线路+集数表(详情页离线兜底),外加确定性产物路径规则 */
export interface VideoSnapshot {
  video: CmsVideo;
  savedAt: number;
}

/**
 * 视频离线存储:
 *   快照   filesDir/video_cache/vod_{sourceId}_{vodId}.json
 *   成片   filesDir/video_cache/v_{sourceId}_{vodId}_e{episodeIndex}.ts
 *   断点   同名 .sidecar.json(下载中才有,完成即删)
 * 路径确定性 → 不查队列也能知道某集的本地文件,删除/离线播放都简单。
 */
export class VideoCache {
  private static root: string = '';

  static init(context: Context): void {
    if (VideoCache.root === '') {
      VideoCache.root = `${context.filesDir}/video_cache`;
      if (!fileIo.accessSync(VideoCache.root)) {
        fileIo.mkdirSync(VideoCache.root, true);
      }
    }
  }

  static videoKey(sourceId: number, vodId: number): string {
    return `${sourceId}_${vodId}`;
  }

  static episodeFile(sourceId: number, vodId: number, episodeIndex: number): string {
    return `${VideoCache.root}/v_${VideoCache.videoKey(sourceId, vodId)}_e${episodeIndex}.ts`;
  }

  static episodeBase(sourceId: number, vodId: number, episodeIndex: number): string {
    // 无扩展名的产物基名:成片 .ts,断点 .sidecar.json
    return `${VideoCache.root}/v_${VideoCache.videoKey(sourceId, vodId)}_e${episodeIndex}`;
  }

  /** 快照落盘(详情页联网成功时写穿透) */
  static saveVideo(video: CmsVideo): void {
    if (VideoCache.root === '') {
      return;
    }
    try {
      const p = `${VideoCache.root}/vod_${VideoCache.videoKey(video.sourceId, video.vodId)}.json`;
      const snap: VideoSnapshot = { video: video, savedAt: new Date().getTime() };
      const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(f.fd, JSON.stringify(snap));
      } finally {
        fileIo.closeSync(f);
      }
    } catch (e) {
      Log.warn('save video snapshot failed', `${e}`);
    }
  }

  static loadVideo(sourceId: number, vodId: number): VideoSnapshot | null {
    if (VideoCache.root === '') {
      return null;
    }
    const p = `${VideoCache.root}/vod_${VideoCache.videoKey(sourceId, vodId)}.json`;
    if (!fileIo.accessSync(p)) {
      return null;
    }
    try {
      return JSON.parse(fileIo.readTextSync(p)) as VideoSnapshot;
    } catch (e) {
      return null;
    }
  }

  /** 某集是否已下载(标记 + 文件都在才算) */
  static isEpisodeDownloaded(sourceId: number, vodId: number, episodeIndex: number): boolean {
    if (Prefs.getDownloadedEpisodes(sourceId, vodId).indexOf(episodeIndex) < 0) {
      return false;
    }
    return fileIo.accessSync(VideoCache.episodeFile(sourceId, vodId, episodeIndex));
  }

  /** 某集时长毫秒(代理播放列表要用):优先用下载时记录的真实值,
   *  否则按 ~1.2MB/s 码率粗估(360资源约 10Mbps);再不行 25 分钟兜底 */
  static estimateDurationMs(sourceId: number, vodId: number, episodeIndex: number): number {
    const real = Prefs.getVideoDurationSec(VideoCache.videoKey(sourceId, vodId), episodeIndex);
    if (real > 0) {
      return real * 1000;
    }
    const size = VideoCache.episodeSize(sourceId, vodId, episodeIndex);
    if (size > 1024 * 1024) {
      return Math.round(size / 1.2); // 字节/秒≈1.2MB
    }
    return 25 * 60 * 1000;
  }

  /** 单集体积(字节);文件不存在返回 0 */
  static episodeSize(sourceId: number, vodId: number, episodeIndex: number): number {
    const p = VideoCache.episodeFile(sourceId, vodId, episodeIndex);
    if (!fileIo.accessSync(p)) {
      return 0;
    }
    try {
      return fileIo.statSync(p).size;
    } catch (e) {
      return 0;
    }
  }

  /** 所有有快照的 `{sourceId}_{vodId}`(离线库列表用) */
  static allSnapshots(): string[] {
    if (VideoCache.root === '') {
      return [];
    }
    const out: string[] = [];
    try {
      const names = fileIo.listFileSync(VideoCache.root);
      for (const n of names) {
        if (n.startsWith('vod_') && n.endsWith('.json')) {
          out.push(n.substring(4, n.length - 5));
        }
      }
    } catch (e) {
      Log.warn('list video snapshots failed', `${e}`);
    }
    return out;
  }

  /** 删除一集的成片与断点(不撤 dl_ 标记,调用方决定) */
  static deleteEpisodeFile(sourceId: number, vodId: number, episodeIndex: number): void {
    const base = VideoCache.episodeBase(sourceId, vodId, episodeIndex);
    const files: string[] = [`${base}.ts`, `${base}.sidecar.json`];
    for (const p of files) {
      try {
        if (fileIo.accessSync(p)) {
          fileIo.unlinkSync(p);
        }
      } catch (e) {
        // 忽略
      }
    }
  }

  /** 删除整部:成片/断点/快照/标记 */
  static deleteVideo(sourceId: number, vodId: number): void {
    const snap = VideoCache.loadVideo(sourceId, vodId);
    if (snap !== null) {
      for (const route of snap.video.routes) {
        for (const ep of route.episodes) {
          VideoCache.deleteEpisodeFile(sourceId, vodId, ep.index);
        }
      }
      try {
        fileIo.unlinkSync(`${VideoCache.root}/vod_${VideoCache.videoKey(sourceId, vodId)}.json`);
      } catch (e) {
        // 忽略
      }
    }
    Prefs.setDownloadedEpisodes(sourceId, vodId, []);
  }
}
