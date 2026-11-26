import { fileIo } from '@kit.CoreFileKit';
import { Context } from '@kit.AbilityKit';
import { Log } from '../../common/Logger';
import { HttpClient } from '../http/HttpClient';
import { ComicSnapshot } from '../../models/manga/MangaModels';

/** 已缓存章节的图片清单(离线兜底用) */
export interface CachedChapter {
  name: string;
  images: string[];
}

/** 一次批量下载的成败统计(pump 据此决定标 done 还是 failed) */
export interface DownloadStats {
  ok: number;
  fail: number;
}

/**
 * 漫画本地缓存:图片并发下载到沙箱,阅读走 file:// 秒开;
 * 章节图片清单同步落盘,断网也能看已看过的章节。
 */
export class MangaCache {
  private static root: string = '';
  private static mem: Map<string, string> = new Map(); // url → 本地绝对路径

  static init(context: Context): void {
    if (MangaCache.root === '') {
      MangaCache.root = `${context.filesDir}/manga_cache`;
      if (!fileIo.accessSync(MangaCache.root)) {
        fileIo.mkdirSync(MangaCache.root, true);
      }
    }
  }

  private static fileName(url: string): string {
    let h = 0;
    for (let i = 0; i < url.length; i++) {
      h = (h * 31 + url.charCodeAt(i)) | 0;
    }
    return `i${(h >>> 0).toString(16)}.img`;
  }

  /** 本地绝对路径;未缓存返回 '' */
  static localPath(url: string): string {
    if (MangaCache.root === '') {
      return '';
    }
    const hit = MangaCache.mem.get(url);
    if (hit !== undefined) {
      return hit;
    }
    const p = `${MangaCache.root}/${MangaCache.fileName(url)}`;
    if (fileIo.accessSync(p)) {
      MangaCache.mem.set(url, p);
      return p;
    }
    return '';
  }

  /** Image 组件可直接用的 src:本地 file:// 或原网络地址 */
  static srcFor(url: string): string {
    const p = MangaCache.localPath(url);
    return p.length > 0 ? `file://${p}` : url;
  }

  static isCached(url: string): boolean {
    return MangaCache.localPath(url).length > 0;
  }

  /** 整话图片是否全部命中本地(决定能否零网络直开) */
  static allCached(urls: string[]): boolean {
    for (const u of urls) {
      if (!MangaCache.isCached(u)) {
        return false;
      }
    }
    return urls.length > 0;
  }

  /** 下载单张(已缓存直接返回 true) */
  static async download(url: string): Promise<boolean> {
    if (MangaCache.localPath(url).length > 0) {
      return true;
    }
    try {
      const data = await HttpClient.getBinary(url,
        { 'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0' },
        { connectMs: 8000, readMs: 20000, quiet: true });
      if (data.byteLength < 1024) {
        return false; // 太小必是错误页
      }
      const p = `${MangaCache.root}/${MangaCache.fileName(url)}`;
      const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(f.fd, data.buffer as ArrayBuffer);
      } finally {
        fileIo.closeSync(f);
      }
      MangaCache.mem.set(url, p);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 并发下载;每张完成回调(用于渐进把 src 换成本地)。
   *  shouldStop 为 true 时 worker 不再领取新图片(进行中的几张会自然收尾),用于暂停/移除任务。
   *  返回成功/失败张数(已缓存的按成功计):失败>0 时调用方不得标"已缓存"。 */
  static async downloadAll(urls: string[], concurrency: number,
    onEach?: (url: string, done: number, total: number) => void,
    shouldStop?: () => boolean): Promise<DownloadStats> {
    let idx = 0;
    let done = 0;
    let ok = 0;
    let fail = 0;
    const total = urls.length;
    const worker = async (): Promise<void> => {
      for (;;) {
        if (shouldStop !== undefined && shouldStop()) {
          return;
        }
        const i = idx;
        idx++;
        if (i >= total) {
          return;
        }
        if (await MangaCache.download(urls[i])) {
          ok++;
        } else {
          fail++;
        }
        done++;
        if (onEach !== undefined) {
          onEach(urls[i], done, total);
        }
      }
    };
    const ws: Promise<void>[] = [];
    for (let k = 0; k < Math.min(concurrency, total); k++) {
      ws.push(worker());
    }
    await Promise.all(ws);
    const stats: DownloadStats = { ok: ok, fail: fail };
    return stats;
  }

  /** 章节图片清单落盘(离线兜底) */
  static saveChapterList(uuid: string, chapter: CachedChapter): void {
    if (MangaCache.root === '') {
      return;
    }
    try {
      const p = `${MangaCache.root}/list_${uuid}.json`;
      const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(f.fd, JSON.stringify(chapter));
      } finally {
        fileIo.closeSync(f);
      }
    } catch (e) {
      Log.warn('save chapter list failed', `${e}`);
    }
  }

  static loadChapterList(uuid: string): CachedChapter | null {
    if (MangaCache.root === '') {
      return null;
    }
    const p = `${MangaCache.root}/list_${uuid}.json`;
    if (!fileIo.accessSync(p)) {
      return null;
    }
    try {
      const text = fileIo.readTextSync(p);
      return JSON.parse(text) as CachedChapter;
    } catch (e) {
      return null;
    }
  }

  /** 整部漫画快照落盘(详情+章节列表;下载入队/详情页联网成功时写入) */
  static saveComicSnapshot(snapshot: ComicSnapshot): void {
    if (MangaCache.root === '') {
      return;
    }
    try {
      const p = `${MangaCache.root}/comic_${snapshot.detail.pathWord}.json`;
      const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(f.fd, JSON.stringify(snapshot));
      } finally {
        fileIo.closeSync(f);
      }
    } catch (e) {
      Log.warn('save comic snapshot failed', `${e}`);
    }
  }

  static loadComicSnapshot(pathWord: string): ComicSnapshot | null {
    if (MangaCache.root === '') {
      return null;
    }
    const p = `${MangaCache.root}/comic_${pathWord}.json`;
    if (!fileIo.accessSync(p)) {
      return null;
    }
    try {
      const text = fileIo.readTextSync(p);
      return JSON.parse(text) as ComicSnapshot;
    } catch (e) {
      return null;
    }
  }

  /** 所有本地快照的漫画 pathWord(离线库列表用) */
  static allSnapshotComics(): string[] {
    if (MangaCache.root === '') {
      return [];
    }
    const out: string[] = [];
    try {
      const names = fileIo.listFileSync(MangaCache.root);
      for (const n of names) {
        if (n.startsWith('comic_') && n.endsWith('.json')) {
          out.push(n.substring(6, n.length - 5));
        }
      }
    } catch (e) {
      Log.warn('list snapshot comics failed', `${e}`);
    }
    return out;
  }

  /** 删除整部漫画的离线数据:快照 + 章节清单 + 按清单登记的图片与封面。
   *  图片按 URL hash 全局去重,但同一 URL 只会出现在同一部漫画的章节里,直接删是安全的。
   *  调用方需随后 Prefs.setDownloadedChapters(pathWord, []) 清掉已缓存标记。 */
  static deleteComic(pathWord: string): void {
    if (MangaCache.root === '') {
      return;
    }
    const snap = MangaCache.loadComicSnapshot(pathWord);
    const stale: string[] = [];
    if (snap !== null) {
      for (const ch of snap.chapters) {
        const list = MangaCache.loadChapterList(ch.uuid);
        if (list !== null) {
          for (const url of list.images) {
            stale.push(url);
          }
        }
        try {
          fileIo.unlinkSync(`${MangaCache.root}/list_${ch.uuid}.json`);
        } catch (e) {
          // 清单本就不存在,忽略
        }
      }
      stale.push(snap.detail.cover);
    }
    for (const url of stale) {
      const p = `${MangaCache.root}/${MangaCache.fileName(url)}`;
      try {
        if (fileIo.accessSync(p)) {
          fileIo.unlinkSync(p);
        }
      } catch (e) {
        // 单个文件删除失败不阻断整体
      }
      MangaCache.mem.delete(url);
    }
    try {
      fileIo.unlinkSync(`${MangaCache.root}/comic_${pathWord}.json`);
    } catch (e) {
      // 快照不存在,忽略
    }
  }
}
