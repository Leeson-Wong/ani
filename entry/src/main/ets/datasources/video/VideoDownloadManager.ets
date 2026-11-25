import { HlsDownloader, HlsDownloadResult } from './HlsDownloader';
import { VideoCache } from './VideoCache';
import { Episode, PlayRoute } from '../../models/cms/MaccmsModels';
import { Prefs, StoredVideoTask } from '../../db/Prefs';
import { NetWatch } from '../../common/NetWatch';
import { TransferScheduler } from '../../common/TransferScheduler';
import { Log } from '../../common/Logger';

/** 单集下载任务(字段 @Trace,页面绑定实时刷新) */
@ObservedV2
export class VideoTaskVM {
  readonly sourceId: number;
  readonly vodId: number;
  readonly title: string;
  readonly cover: string;
  readonly routeIndex: number;
  readonly episodeIndex: number;
  readonly episodeName: string;
  readonly altUrls: string[]; // 同集其他线路直链(主直链死链时换一次)
  @Trace status: string = 'queued'; // queued | downloading | wifi-wait | paused | done | failed
  @Trace done: number = 0;
  @Trace total: number = 0;
  @Trace bytes: number = 0;
  m3u8Url: string; // 可被死链换线改写
  triedAlt: boolean = false;

  constructor(sourceId: number, vodId: number, title: string, cover: string, routeIndex: number,
    episodeIndex: number, episodeName: string, m3u8Url: string, altUrls: string[]) {
    this.sourceId = sourceId;
    this.vodId = vodId;
    this.title = title;
    this.cover = cover;
    this.routeIndex = routeIndex;
    this.episodeIndex = episodeIndex;
    this.episodeName = episodeName;
    this.m3u8Url = m3u8Url;
    this.altUrls = altUrls;
  }

  percent(): number {
    if (this.total <= 0) {
      return 0;
    }
    return Math.floor(this.done / this.total * 100);
  }
}

/**
 * 视频下载队列:一集一个任务,串行下载(集大,不并发多集)。
 * 队列快照写 Prefs,重启恢复;「仅 Wi-Fi」开且当前非 Wi-Fi 时任务挂 wifi-wait,网络恢复自动续跑。
 */
export class VideoDownloadManager {
  static readonly tasks: VideoTaskVM[] = [];
  private static readonly queue: VideoTaskVM[] = [];
  private static running: boolean = false;
  private static restored: boolean = false;
  private static listeners: (() => void)[] = [];
  private static netCb: (() => void) | null = null;

  static onChange(cb: () => void): void {
    VideoDownloadManager.listeners.push(cb);
  }

  static offChange(cb: () => void): void {
    const i = VideoDownloadManager.listeners.indexOf(cb);
    if (i >= 0) {
      VideoDownloadManager.listeners.splice(i, 1);
    }
  }

  private static notify(): void {
    for (const cb of VideoDownloadManager.listeners) {
      cb();
    }
  }

  /** 网络恢复时自动重试 wifi-wait 的任务 */
  private static ensureNetListener(): void {
    if (VideoDownloadManager.netCb === null) {
      VideoDownloadManager.netCb = () => {
        if (VideoDownloadManager.queue.length > 0) {
          VideoDownloadManager.pump();
        }
      };
      NetWatch.onChange(VideoDownloadManager.netCb);
    }
  }

  private static persist(): void {
    const rows: StoredVideoTask[] = [];
    for (const t of VideoDownloadManager.tasks) {
      const row: StoredVideoTask = {
        sourceId: t.sourceId, vodId: t.vodId, title: t.title, cover: t.cover,
        routeIndex: t.routeIndex, episodeIndex: t.episodeIndex, episodeName: t.episodeName,
        status: t.status === 'downloading' ? 'queued' : t.status,
        done: t.done, total: t.total, bytes: t.bytes,
        m3u8Url: t.m3u8Url, altUrls: t.altUrls.slice(0),
        outFile: VideoCache.episodeFile(t.sourceId, t.vodId, t.episodeIndex)
      };
      rows.push(row);
    }
    Prefs.saveVideoQueue(rows);
  }

  /** 进程启动后恢复;需先 Prefs.init + VideoCache.init */
  static restore(): void {
    if (VideoDownloadManager.restored || !Prefs.isReady) {
      return;
    }
    VideoDownloadManager.restored = true;
    const rows = Prefs.getVideoQueue();
    for (const row of rows) {
      if (row.status === 'done' || Prefs.getDownloadedEpisodes(row.sourceId, row.vodId).indexOf(row.episodeIndex) >= 0) {
        continue;
      }
      const vm = new VideoTaskVM(row.sourceId, row.vodId, row.title, row.cover, row.routeIndex,
        row.episodeIndex, row.episodeName, row.m3u8Url, row.altUrls);
      vm.done = row.done;
      vm.total = row.total;
      vm.bytes = row.bytes;
      vm.status = row.status === 'paused' ? 'paused' : 'queued';
      VideoDownloadManager.tasks.push(vm);
      if (vm.status === 'queued') {
        VideoDownloadManager.queue.push(vm);
      }
    }
    if (VideoDownloadManager.tasks.length > 0) {
      VideoDownloadManager.ensureNetListener();
      VideoDownloadManager.notify();
      VideoDownloadManager.pump();
    }
  }

  static isDownloaded(sourceId: number, vodId: number, episodeIndex: number): boolean {
    return VideoCache.isEpisodeDownloaded(sourceId, vodId, episodeIndex);
  }

  /** 该集的进行中任务(不含 done/failed) */
  static taskFor(sourceId: number, vodId: number, episodeIndex: number): VideoTaskVM | undefined {
    return VideoDownloadManager.tasks.find((t: VideoTaskVM) =>
      t.sourceId === sourceId && t.vodId === vodId && t.episodeIndex === episodeIndex
      && t.status !== 'done' && t.status !== 'failed');
  }

  /** 入队一批集;返回实际新增数。altUrls 取同集其他线路的 m3u8 直链 */
  static enqueue(sourceId: number, vodId: number, title: string, cover: string,
    routeIndex: number, episodes: Episode[], routes: PlayRoute[]): number {
    let added = 0;
    for (const ep of episodes) {
      if (VideoDownloadManager.isDownloaded(sourceId, vodId, ep.index)) {
        continue;
      }
      const dup = VideoDownloadManager.tasks.find((t: VideoTaskVM) =>
        t.sourceId === sourceId && t.vodId === vodId && t.episodeIndex === ep.index && t.status !== 'failed');
      if (dup !== undefined) {
        continue;
      }
      if (!ep.url.includes('.m3u8')) {
        continue; // 非直链暂不支持离线
      }
      const alts: string[] = [];
      for (const r of routes) {
        if (r.index === routeIndex) {
          continue;
        }
        const same = r.episodes.find((e: Episode) => e.index === ep.index);
        if (same !== undefined && same.url.includes('.m3u8')) {
          alts.push(same.url);
        }
      }
      const vm = new VideoTaskVM(sourceId, vodId, title, cover, routeIndex, ep.index, ep.name, ep.url, alts);
      VideoDownloadManager.tasks.push(vm);
      VideoDownloadManager.queue.push(vm);
      added++;
    }
    if (added > 0) {
      VideoDownloadManager.ensureNetListener();
      VideoDownloadManager.persist();
      VideoDownloadManager.notify();
      VideoDownloadManager.pump();
    }
    return added;
  }

  static pause(vm: VideoTaskVM): void {
    if (vm.status !== 'queued' && vm.status !== 'downloading' && vm.status !== 'wifi-wait') {
      return;
    }
    vm.status = 'paused';
    const qi = VideoDownloadManager.queue.indexOf(vm);
    if (qi >= 0) {
      VideoDownloadManager.queue.splice(qi, 1);
    }
    VideoDownloadManager.persist();
    VideoDownloadManager.notify();
  }

  static resume(vm: VideoTaskVM): void {
    if (vm.status !== 'paused') {
      return;
    }
    vm.status = 'queued';
    VideoDownloadManager.queue.push(vm);
    VideoDownloadManager.persist();
    VideoDownloadManager.notify();
    VideoDownloadManager.pump();
  }

  /** 移除任务行并删掉半成品文件 */
  static remove(vm: VideoTaskVM): void {
    vm.status = 'removed';
    const qi = VideoDownloadManager.queue.indexOf(vm);
    if (qi >= 0) {
      VideoDownloadManager.queue.splice(qi, 1);
    }
    const ti = VideoDownloadManager.tasks.indexOf(vm);
    if (ti >= 0) {
      VideoDownloadManager.tasks.splice(ti, 1);
    }
    VideoCache.deleteEpisodeFile(vm.sourceId, vm.vodId, vm.episodeIndex);
    VideoDownloadManager.persist();
    VideoDownloadManager.notify();
  }

  static retry(vm: VideoTaskVM): void {
    if (vm.status !== 'failed') {
      return;
    }
    vm.status = 'queued';
    vm.triedAlt = false;
    vm.done = 0;
    vm.total = 0;
    VideoDownloadManager.queue.push(vm);
    VideoDownloadManager.persist();
    VideoDownloadManager.notify();
    VideoDownloadManager.pump();
  }

  static clearFinished(): void {
    const keep = VideoDownloadManager.tasks.filter((t: VideoTaskVM) =>
      t.status !== 'done' && t.status !== 'failed');
    VideoDownloadManager.tasks.length = 0;
    for (const t of keep) {
      VideoDownloadManager.tasks.push(t);
    }
    VideoDownloadManager.persist();
    VideoDownloadManager.notify();
  }

  static activeCount(): number {
    return VideoDownloadManager.tasks.filter((t: VideoTaskVM) =>
      t.status === 'queued' || t.status === 'downloading' || t.status === 'wifi-wait').length;
  }

  private static async pump(): Promise<void> {
    if (VideoDownloadManager.running) {
      return;
    }
    VideoDownloadManager.running = true;
    TransferScheduler.retain();
    while (VideoDownloadManager.queue.length > 0) {
      const t = VideoDownloadManager.queue[0];
      if (t === undefined || t.status === 'paused' || t.status === 'removed') {
        VideoDownloadManager.queue.shift();
        continue;
      }
      // 仅 Wi-Fi:当前非 Wi-Fi 时挂起,等 NetWatch 回调再进
      if (Prefs.getWifiOnly() && !NetWatch.get().wifi) {
        if (t.status !== 'wifi-wait') {
          t.status = 'wifi-wait';
          VideoDownloadManager.notify();
        }
        break; // 串行队列,队头等网即可
      }
      if (t.status !== 'downloading') {
        t.status = 'downloading';
        VideoDownloadManager.notify();
      }
      VideoDownloadManager.persist();
      const base = VideoCache.episodeBase(t.sourceId, t.vodId, t.episodeIndex);
      const result: HlsDownloadResult = await HlsDownloader.download(t.m3u8Url, base, 4,
        (done: number, total: number, bytes: number) => {
          t.done = done;
          t.total = total;
          t.bytes = bytes;
        }, () => t.status === 'paused' || t.status === 'removed');
      if (result.stopped) {
        VideoDownloadManager.persist();
        VideoDownloadManager.notify();
        continue;
      }
      if (result.ok) {
        t.done = result.done;
        t.total = result.total;
        t.bytes = result.bytes;
        t.status = 'done';
        Prefs.addDownloadedEpisode(t.sourceId, t.vodId, t.episodeIndex);
        // 真实时长(EXTINF 合计)留给本地代理播放列表;旧断点无此值时按 0 跳过
        if (result.estDurSec > 0) {
          Prefs.setVideoDurationSec(VideoCache.videoKey(t.sourceId, t.vodId), t.episodeIndex, result.estDurSec);
        }
        Log.info('episode downloaded', t.episodeName, result.message);
      } else if (result.done === 0 && !t.triedAlt && t.altUrls.length > 0) {
        // 一段都没写出来 = playlist/直链问题,换备用线路重跑一次
        t.triedAlt = true;
        t.m3u8Url = t.altUrls.shift() as string;
        Log.warn('episode dead link, retry alt route', t.episodeName, t.m3u8Url);
        continue; // 原地再跑(仍在队头)
      } else {
        t.status = 'failed';
        Log.warn('episode download failed', t.episodeName, result.message);
      }
      VideoDownloadManager.queue.shift();
      VideoDownloadManager.persist();
      VideoDownloadManager.notify();
    }
    TransferScheduler.release();
    VideoDownloadManager.running = false;
  }
}
