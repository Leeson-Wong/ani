import { MangaSources } from './MangaSource';
import { MangaCache } from './MangaCache';
import { ComicSnapshot, MangaChapter, MangaDetail } from '../../models/manga/MangaModels';
import { Prefs, StoredDownloadTask } from '../../db/Prefs';
import { Log } from '../../common/Logger';
import { TransferScheduler } from '../../common/TransferScheduler';

/** 单章下载任务(字段 @Trace,页面绑定实时刷新) */
@ObservedV2
export class DownloadTaskVM {
  readonly sourceId: string; // 漫画源 id:下载按任务源路由,双源队列互不干扰
  readonly pathWord: string;
  readonly comicName: string;
  readonly uuid: string;
  readonly chapterName: string;
  @Trace status: string = 'queued'; // queued | downloading | paused | done | failed
  @Trace done: number = 0;
  @Trace total: number = 0;

  constructor(sourceId: string, pathWord: string, comicName: string, uuid: string, chapterName: string) {
    this.sourceId = sourceId;
    this.pathWord = pathWord;
    this.comicName = comicName;
    this.uuid = uuid;
    this.chapterName = chapterName;
  }
}

/**
 * 全局漫画下载队列:详情页多选章节入队,串行逐章下载(章内 3 并发)。
 * 队列快照写 Prefs,进程重启后恢复;未完成的任务重新排队,暂停的保持暂停。
 */
export class DownloadManager {
  static readonly tasks: DownloadTaskVM[] = [];
  private static readonly queue: DownloadTaskVM[] = [];
  private static running: boolean = false;
  private static restored: boolean = false;
  private static listeners: (() => void)[] = [];

  static onChange(cb: () => void): void {
    DownloadManager.listeners.push(cb);
  }

  static offChange(cb: () => void): void {
    const i = DownloadManager.listeners.indexOf(cb);
    if (i >= 0) {
      DownloadManager.listeners.splice(i, 1);
    }
  }

  private static notify(): void {
    for (const cb of DownloadManager.listeners) {
      cb();
    }
  }

  /** 队列变化后落盘快照(不含已缓存文件的实际字节,只存任务状态与进度) */
  private static persist(): void {
    const rows: StoredDownloadTask[] = [];
    for (const t of DownloadManager.tasks) {
      const row: StoredDownloadTask = {
        sourceId: t.sourceId,
        pathWord: t.pathWord,
        comicName: t.comicName,
        uuid: t.uuid,
        chapterName: t.chapterName,
        status: t.status,
        done: t.done,
        total: t.total
      };
      rows.push(row);
    }
    Prefs.saveDownloadQueue(rows);
  }

  /** 进程启动后恢复队列:需先 Prefs.init + MangaCache.init。
   *  downloading/queued → 重新排队续传(已下图片走本地秒过);paused 保持暂停不自动跑。 */
  static restore(): void {
    if (DownloadManager.restored || !Prefs.isReady) {
      return; // Prefs 未就绪时直接返回,等启动回调里再恢复
    }
    DownloadManager.restored = true;
    const rows = Prefs.getDownloadQueue();
    for (const row of rows) {
      // 已完成过的章节不再重复下载
      if (Prefs.getDownloadedChapters(row.pathWord).indexOf(row.uuid) >= 0) {
        continue;
      }
      // 旧版本队列快照没有 sourceId:那批任务全属 copymanga,按它恢复(不跟随当前源)
      const sid = row.sourceId !== undefined && row.sourceId.length > 0 ? row.sourceId : 'copymanga';
      const vm = new DownloadTaskVM(sid, row.pathWord, row.comicName, row.uuid, row.chapterName);
      vm.total = row.total;
      vm.done = row.done;
      vm.status = row.status === 'paused' ? 'paused' : 'queued';
      DownloadManager.tasks.push(vm);
      if (vm.status === 'queued') {
        DownloadManager.queue.push(vm);
      }
    }
    if (DownloadManager.tasks.length > 0) {
      DownloadManager.notify();
      DownloadManager.pump();
    }
    DownloadManager.verifyIntegrity(); // 异步复核 dl_ 标记,不阻塞队列恢复
  }

  /** 启动后复核所有 dl_ 标记:章节清单缺失或图片不全的章节移出"已缓存",
   *  详情页重新显示可下载,杜绝"标了已缓存却翻不出图"。每部漫画之间让出主线程。 */
  private static verifyIntegrity(): void {
    const comics = Prefs.allDownloadedComics();
    let i = 0;
    let changed = false;
    const step = (): void => {
      while (i < comics.length) {
        const pw = comics[i++];
        const marks = Prefs.getDownloadedChapters(pw);
        const keep: string[] = [];
        for (const uuid of marks) {
          const list = MangaCache.loadChapterList(uuid);
          if (list === null || !MangaCache.allCached(list.images)) {
            changed = true;
            Log.warn('unmark incomplete downloaded chapter', uuid);
            continue;
          }
          keep.push(uuid);
        }
        if (keep.length !== marks.length) {
          Prefs.setDownloadedChapters(pw, keep);
        }
        setTimeout(step, 0);
        return;
      }
      if (changed) {
        DownloadManager.notify(); // 详情页监听后刷新徽标
      }
    };
    step();
  }

  /** 章节是否已完成下载(持久标记) */
  static isDownloaded(pathWord: string, uuid: string): boolean {
    return Prefs.getDownloadedChapters(pathWord).indexOf(uuid) >= 0;
  }

  /** 找章节的进行中任务(无则 undefined) */
  static taskFor(pathWord: string, uuid: string): DownloadTaskVM | undefined {
    return DownloadManager.tasks.find((t: DownloadTaskVM) =>
      t.pathWord === pathWord && t.uuid === uuid && t.status !== 'done' && t.status !== 'failed');
  }

  /** 入队一批章节;返回实际新增数(已完成/已排队自动跳过)。
   *  同时确保整部快照+封面已落盘(离线详情/阅读器/离线库都以此为准)。
   *  调用方页面需先 MangaCache.init(context)。 */
  static enqueue(sourceId: string, detail: MangaDetail, chapters: MangaChapter[]): number {
    const pathWord = detail.pathWord;
    const downloaded = Prefs.getDownloadedChapters(pathWord);
    let added = 0;
    for (const ch of chapters) {
      if (downloaded.indexOf(ch.uuid) >= 0) {
        continue;
      }
      const dup = DownloadManager.tasks.find((t: DownloadTaskVM) =>
        t.pathWord === pathWord && t.uuid === ch.uuid && t.status !== 'failed');
      if (dup !== undefined) {
        continue;
      }
      const vm = new DownloadTaskVM(sourceId, pathWord, detail.name, ch.uuid, ch.name);
      DownloadManager.tasks.push(vm);
      DownloadManager.queue.push(vm);
      added++;
    }
    DownloadManager.ensureSnapshot(sourceId, detail, chapters);
    if (added > 0) {
      DownloadManager.persist();
      DownloadManager.notify();
      DownloadManager.pump();
    }
    return added;
  }

  /** 快照缺失或章节有更新时重写(联网时调用;封面顺带进本地缓存) */
  private static ensureSnapshot(sourceId: string, detail: MangaDetail, chapters: MangaChapter[]): void {
    const existing = MangaCache.loadComicSnapshot(detail.pathWord);
    if (existing !== null && existing.chapters.length === chapters.length) {
      return;
    }
    const snap: ComicSnapshot = {
      detail: detail,
      chapters: chapters,
      savedAt: new Date().getTime(),
      sourceId: sourceId
    };
    MangaCache.saveComicSnapshot(snap);
    MangaCache.download(detail.cover).then((_ok: boolean) => {
    }); // 封面只求进缓存,成败无所谓
  }

  /** 暂停:排队中直接从队列摘除;下载中标记 paused,worker 在下一张前停手 */
  static pause(vm: DownloadTaskVM): void {
    if (vm.status !== 'queued' && vm.status !== 'downloading') {
      return;
    }
    vm.status = 'paused';
    const qi = DownloadManager.queue.indexOf(vm);
    if (qi >= 0) {
      DownloadManager.queue.splice(qi, 1);
    }
    DownloadManager.persist();
    DownloadManager.notify();
  }

  /** 继续:重新排队;已下的图片在 downloadAll 里走本地缓存,只补缺口 */
  static resume(vm: DownloadTaskVM): void {
    if (vm.status !== 'paused') {
      return;
    }
    vm.status = 'queued';
    DownloadManager.queue.push(vm);
    DownloadManager.persist();
    DownloadManager.notify();
    DownloadManager.pump();
  }

  /** 移除任务行(不动已缓存文件;下载中会停手) */
  static remove(vm: DownloadTaskVM): void {
    vm.status = 'removed'; // 内部标记:触发 worker 停手,且不让 pump 误标完成
    const qi = DownloadManager.queue.indexOf(vm);
    if (qi >= 0) {
      DownloadManager.queue.splice(qi, 1);
    }
    const ti = DownloadManager.tasks.indexOf(vm);
    if (ti >= 0) {
      DownloadManager.tasks.splice(ti, 1);
    }
    DownloadManager.persist();
    DownloadManager.notify();
  }

  static retry(vm: DownloadTaskVM): void {
    if (vm.status !== 'failed') {
      return;
    }
    vm.status = 'queued';
    vm.done = 0;
    vm.total = 0;
    DownloadManager.queue.push(vm);
    DownloadManager.persist();
    DownloadManager.notify();
    DownloadManager.pump();
  }

  /** 清掉已完成/失败的任务行(只影响列表展示,不动已缓存文件) */
  static clearFinished(): void {
    const keep = DownloadManager.tasks.filter((t: DownloadTaskVM) =>
      t.status !== 'done' && t.status !== 'failed');
    DownloadManager.tasks.length = 0;
    for (const t of keep) {
      DownloadManager.tasks.push(t);
    }
    DownloadManager.persist();
    DownloadManager.notify();
  }

  static activeCount(): number {
    return DownloadManager.tasks.filter((t: DownloadTaskVM) =>
      t.status === 'queued' || t.status === 'downloading').length;
  }

  private static async pump(): Promise<void> {
    if (DownloadManager.running) {
      return;
    }
    DownloadManager.running = true;
    TransferScheduler.retain(); // 队列有活干,申请后台连续任务(退后台不被冻结)
    while (DownloadManager.queue.length > 0) {
      const t = DownloadManager.queue.shift();
      if (t === undefined) {
        break;
      }
      if (t.status === 'paused') {
        continue; // 暂停期间被摘除的任务,跳到下一章
      }
      t.status = 'downloading';
      DownloadManager.notify();
      DownloadManager.persist();
      try {
        // 按任务自己的源路由(源被移除时回退 copymanga,老任务行为不变)
        const src = MangaSources.byId(t.sourceId) ?? MangaSources.byId('copymanga');
        const imgs = await (src !== undefined ? src : MangaSources.current()).chapterImages(t.pathWord, t.uuid);
        MangaCache.saveChapterList(t.uuid, { name: imgs.chapterName, images: imgs.images });
        t.total = imgs.images.length;
        const stats = await MangaCache.downloadAll(imgs.images, 3, (_url: string, done: number, _total: number) => {
          t.done = done;
        }, () => t.status === 'paused' || t.status === 'removed');
        if (t.status === 'paused' || t.status === 'removed') {
          // 暂停/移除:已下图片留在沙箱,续传时秒过;不标记完成、不写完成标记
          DownloadManager.persist();
          DownloadManager.notify();
          continue;
        }
        if (stats.fail > 0) {
          // 有图片没下成功:不写已缓存标记,标失败让用户重试(重试只补缺口)
          t.status = 'failed';
          Log.warn('chapter download incomplete', t.chapterName, `ok=${stats.ok} fail=${stats.fail}`);
        } else {
          t.status = 'done';
          Prefs.addDownloadedChapter(t.pathWord, t.uuid);
          Log.info('chapter downloaded', t.chapterName);
        }
      } catch (e) {
        if (t.status !== 'paused' && t.status !== 'removed') {
          t.status = 'failed';
          Log.warn('chapter download failed', t.chapterName, `${e}`);
        }
      }
      DownloadManager.persist();
      DownloadManager.notify();
    }
    TransferScheduler.release(); // 队列空了,释放后台连续任务
    DownloadManager.running = false;
  }
}
