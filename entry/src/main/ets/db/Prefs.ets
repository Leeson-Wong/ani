import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';

/** 持久化的一条下载任务(队列重启后据此恢复) */
export interface StoredDownloadTask {
  pathWord: string;
  comicName: string;
  uuid: string;
  chapterName: string;
  status: string;
  done: number;
  total: number;
}

/** 持久化的一条视频下载任务(一集一条) */
export interface StoredVideoTask {
  sourceId: number;
  vodId: number;
  title: string;
  cover: string;
  routeIndex: number;
  episodeIndex: number;
  episodeName: string;
  status: string; // queued | downloading | wifi-wait | paused | done | failed
  done: number; // 已完成段数
  total: number; // 总段数
  bytes: number;
  m3u8Url: string;
  altUrls: string[]; // 同集其他线路的直链(死链自动换一次)
  outFile: string;
}

/** 轻量 KV:搜索历史 / 漫画阅读进度 */
export class Prefs {
  private static store: preferences.Preferences | null = null;

  static async init(context: Context): Promise<void> {
    if (Prefs.store !== null) {
      return;
    }
    Prefs.store = await preferences.getPreferences(context, 'ani_prefs');
  }

  /** 偏好是否已就绪;未就绪时不要做队列恢复(否则会误置恢复标志) */
  static get isReady(): boolean {
    return Prefs.store !== null;
  }

  static getSearchHistory(): string[] {
    if (Prefs.store === null) {
      return [];
    }
    const raw = Prefs.store.getSync('searchHistory', '[]') as string;
    try {
      return JSON.parse(raw) as string[];
    } catch (e) {
      return [];
    }
  }

  static pushSearchHistory(keyword: string): void {
    if (Prefs.store === null || keyword.trim().length === 0) {
      return;
    }
    const list = Prefs.getSearchHistory().filter((k: string) => k !== keyword);
    list.unshift(keyword);
    const trimmed = list.slice(0, 20);
    Prefs.store.putSync('searchHistory', JSON.stringify(trimmed));
    Prefs.store.flush();
  }

  static getMangaProgress(pathWord: string): string {
    if (Prefs.store === null) {
      return '';
    }
    return Prefs.store.getSync(`manga_${pathWord}`, '') as string; // "chapterUuid|chapterName|chapterIndex"
  }

  static saveMangaProgress(pathWord: string, chapterUuid: string, chapterName: string, chapterIndex: number): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.putSync(`manga_${pathWord}`, `${chapterUuid}|${chapterName}|${chapterIndex}`);
    Prefs.store.flush();
  }

  /** 章节内的阅读位置(滚动偏移):"uuid|yOffset"。重进同一话时恢复到大致位置 */
  static getMangaScrollPos(pathWord: string): string {
    if (Prefs.store === null) {
      return '';
    }
    return Prefs.store.getSync(`mangapos_${pathWord}`, '') as string;
  }

  static saveMangaScrollPos(pathWord: string, chapterUuid: string, yOffset: number): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.putSync(`mangapos_${pathWord}`, `${chapterUuid}|${Math.max(0, Math.round(yOffset))}`);
    Prefs.store.flush();
  }

  /** 已完成离线下载的章节(Persisted) */
  static getDownloadedChapters(pathWord: string): string[] {
    if (Prefs.store === null) {
      return [];
    }
    const raw = Prefs.store.getSync(`dl_${pathWord}`, '[]') as string;
    try {
      return JSON.parse(raw) as string[];
    } catch (e) {
      return [];
    }
  }

  /** 下载队列快照(含 queued/downloading/paused/failed/done),进程重启后恢复 */
  static getDownloadQueue(): StoredDownloadTask[] {
    if (Prefs.store === null) {
      return [];
    }
    const raw = Prefs.store.getSync('downloadQueue', '[]') as string;
    try {
      return JSON.parse(raw) as StoredDownloadTask[];
    } catch (e) {
      return [];
    }
  }

  static saveDownloadQueue(tasks: StoredDownloadTask[]): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.putSync('downloadQueue', JSON.stringify(tasks));
    Prefs.store.flush();
  }

  static addDownloadedChapter(pathWord: string, uuid: string): void {
    if (Prefs.store === null) {
      return;
    }
    const list = Prefs.getDownloadedChapters(pathWord);
    if (list.indexOf(uuid) >= 0) {
      return;
    }
    list.push(uuid);
    Prefs.store.putSync(`dl_${pathWord}`, JSON.stringify(list));
    Prefs.store.flush();
  }

  /** 覆写某部漫画的已缓存章节清单(完整性复核时剔除缺图章节) */
  static setDownloadedChapters(pathWord: string, uuids: string[]): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.putSync(`dl_${pathWord}`, JSON.stringify(uuids));
    Prefs.store.flush();
  }

  /** 所有带 dl_ 标记的漫画 pathWord(启动完整性复核用) */
  static allDownloadedComics(): string[] {
    if (Prefs.store === null) {
      return [];
    }
    const all = Prefs.store.getAllSync();
    const out: string[] = [];
    for (const k of Object.keys(all)) {
      if (k.startsWith('dl_')) {
        out.push(k.substring(3));
      }
    }
    return out;
  }

  /** ===== 视频下载 ===== */

  /** 已完成离线下载的视频集数(key = `{sourceId}_{vodId}`) */
  static getDownloadedEpisodes(sourceId: number, vodId: number): number[] {
    if (Prefs.store === null) {
      return [];
    }
    const raw = Prefs.store.getSync(`vdl_${sourceId}_${vodId}`, '[]') as string;
    try {
      return JSON.parse(raw) as number[];
    } catch (e) {
      return [];
    }
  }

  static addDownloadedEpisode(sourceId: number, vodId: number, episodeIndex: number): void {
    if (Prefs.store === null) {
      return;
    }
    const list = Prefs.getDownloadedEpisodes(sourceId, vodId);
    if (list.indexOf(episodeIndex) >= 0) {
      return;
    }
    list.push(episodeIndex);
    Prefs.store.putSync(`vdl_${sourceId}_${vodId}`, JSON.stringify(list));
    Prefs.store.flush();
  }

  static setDownloadedEpisodes(sourceId: number, vodId: number, idxs: number[]): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.putSync(`vdl_${sourceId}_${vodId}`, JSON.stringify(idxs));
    Prefs.store.flush();
  }

  /** 所有带 vdl_ 标记的 `{sourceId}_{vodId}` key(离线库列表用) */
  static allDownloadedVideos(): string[] {
    if (Prefs.store === null) {
      return [];
    }
    const all = Prefs.store.getAllSync();
    const out: string[] = [];
    for (const k of Object.keys(all)) {
      if (k.startsWith('vdl_')) {
        out.push(k.substring(4));
      }
    }
    return out;
  }

  /** 视频下载队列快照(进程重启后恢复) */
  static getVideoQueue(): StoredVideoTask[] {
    if (Prefs.store === null) {
      return [];
    }
    const raw = Prefs.store.getSync('videoQueue', '[]') as string;
    try {
      return JSON.parse(raw) as StoredVideoTask[];
    } catch (e) {
      return [];
    }
  }

  static saveVideoQueue(tasks: StoredVideoTask[]): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.putSync('videoQueue', JSON.stringify(tasks));
    Prefs.store.flush();
  }

  /** 仅 Wi-Fi 下载(默认开) */
  static getWifiOnly(): boolean {
    if (Prefs.store === null) {
      return true;
    }
    return (Prefs.store.getSync('wifiOnly', true) as boolean);
  }

  static setWifiOnly(v: boolean): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.putSync('wifiOnly', v);
    Prefs.store.flush();
  }

  /** 当前漫画数据源 id(多源切换;'copymanga' = 拷贝漫画) */
  static getMangaSourceId(): string {
    if (Prefs.store === null) {
      return 'copymanga';
    }
    const v = Prefs.store.getSync('mangaSourceId', 'copymanga') as string;
    return v.length > 0 ? v : 'copymanga';
  }

  static setMangaSourceId(v: string): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.putSync('mangaSourceId', v);
    Prefs.store.flush();
  }

  /** ===== 数据源稳定性 ===== */

  /** 漫画 API 最近一次命中的域名(域名池自动回退时记录,下次优先) */
  static getMangaApiBase(): string {
    if (Prefs.store === null) {
      return '';
    }
    return Prefs.store.getSync('mangaApiBase', '') as string;
  }

  static setMangaApiBase(v: string): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.putSync('mangaApiBase', v);
    Prefs.store.flush();
  }

  /** 用户自定义的漫画 API 域名('' = 未设置,走内置域名池自动回退) */
  static getMangaApiCustom(): string {
    if (Prefs.store === null) {
      return '';
    }
    return Prefs.store.getSync('mangaApiCustom', '') as string;
  }

  static setMangaApiCustom(v: string): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.putSync('mangaApiCustom', v);
    Prefs.store.flush();
  }

  /** 上次源复活探测的时间戳(每日一次的门闩) */
  static getLastSourceRevive(): number {
    if (Prefs.store === null) {
      return 0;
    }
    return Number(Prefs.store.getSync('lastSourceRevive', 0));
  }

  static setLastSourceRevive(v: number): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.putSync('lastSourceRevive', v);
    Prefs.store.flush();
  }

  /** 某集真实时长秒(下载完成时记录;本地代理播放列表用) */
  static getVideoDurationSec(videoKey: string, episodeIndex: number): number {
    if (Prefs.store === null) {
      return 0;
    }
    return Number(Prefs.store.getSync(`vdur_${videoKey}_e${episodeIndex}`, 0));
  }

  static setVideoDurationSec(videoKey: string, episodeIndex: number, sec: number): void {
    if (Prefs.store === null || sec <= 0) {
      return;
    }
    Prefs.store.putSync(`vdur_${videoKey}_e${episodeIndex}`, sec);
    Prefs.store.flush();
  }
}
