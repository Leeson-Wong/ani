import { MangaClient } from '../../datasources/manga/MangaClient';
import { MangaCache } from '../../datasources/manga/MangaCache';
import { MangaChapter, MangaChapterImages } from '../../models/manga/MangaModels';
import { Nav } from '../../common/Nav';
import { MangaReaderNavParam } from '../../common/NavParams';
import { AppChrome } from '../../common/AppChrome';
import { Prefs } from '../../db/Prefs';
import { Log } from '../../common/Logger';

/** 单页 VM:src 从网络渐进换成本地 file://,@Trace 驱动 Image 刷新 */
@ObservedV2
class PageVM {
  readonly url: string;
  @Trace src: string;
  @Trace failed: boolean = false; // 加载失败(离线未缓存)时显示占位

  constructor(url: string, src: string) {
    this.url = url;
    this.src = src;
  }
}

/** 漫画阅读器:本地缓存秒开 + 并发预下载 + 自动预载下一话 + 离线兜底 */
@ComponentV2
export struct MangaReaderPage {
  @Local pages: PageVM[] = [];
  @Local chapterName: string = '';
  @Local loading: boolean = true;
  @Local error: string = '';
  @Local showChrome: boolean = false;
  @Local showChapterSheet: boolean = false;
  @Local chapters: MangaChapter[] = [];
  @Local chapterIndex: number = 0;
  @Local cacheDone: number = 0;
  @Local cacheTotal: number = 0;
  @Local offline: boolean = false;
  scroller: Scroller = new Scroller();
  private pathWord: string = '';
  private comicName: string = '';
  private startUuid: string = '';
  private currentUuid: string = '';
  private chromeTimer: number = -1;
  private firstLoad: boolean = true; // 首次进本页时才恢复章节内滚动位置
  private lastY: number = 0; // onDidScroll 维护;退出阶段组件已解绑,currentOffset() 会返回 undefined 不能用

  /** 点图片呼出信息栏+菜单;无操作 3 秒后自动淡出 */
  private revealChrome(): void {
    this.clearChromeTimer();
    this.showChrome = true;
    this.chromeTimer = setTimeout(() => {
      this.showChrome = false;
      this.chromeTimer = -1;
    }, 3000);
  }

  private dismissChrome(): void {
    this.clearChromeTimer();
    this.showChrome = false;
  }

  private clearChromeTimer(): void {
    if (this.chromeTimer >= 0) {
      clearTimeout(this.chromeTimer);
      this.chromeTimer = -1;
    }
  }

  /** 信息栏右侧缓存文案 */
  private cacheLabel(): string {
    if (this.offline) {
      return '离线';
    }
    if (this.loading && this.pages.length === 0) {
      return '加载中';
    }
    if (this.cacheTotal > 0 && this.cacheDone >= this.cacheTotal) {
      return '缓存完成';
    }
    if (this.cacheTotal > 0) {
      return `缓存 ${this.cacheDone}/${this.cacheTotal}`;
    }
    return '';
  }

  async aboutToAppear(): Promise<void> {
    const params = Nav.stack.getParamByName('MangaReader') as MangaReaderNavParam[];
    const p = params !== undefined && params.length > 0 ? params[params.length - 1] : undefined;
    if (p === undefined) {
      return;
    }
    this.pathWord = p.pathWord;
    this.comicName = p.comicName;
    this.startUuid = p.startChapterUuid;
    // 全屏态:让外壳撤掉安全区避让,画面从屏幕上边一直铺到下边
    AppChrome.setFullscreen(true);
    // 进阅读器即隐藏系统状态栏/手势条,不等章节加载完,避免首帧闪出
    await AppChrome.hideSystemBars(getContext(this));
    MangaCache.init(getContext(this));
    // ① 章节列表本地优先:有快照立即用它(离线直进阅读),网络刷新放后台
    const snap = MangaCache.loadComicSnapshot(this.pathWord);
    if (snap !== null && snap.chapters.length > 0) {
      this.chapters = snap.chapters;
    }
    MangaClient.chapters(this.pathWord).then((chs: MangaChapter[]) => {
      this.chapters = chs;
      // 后台刷新到新列表后,重算当前话序号(目录高亮/上下话按钮依赖它)
      const idx = this.chapters.findIndex((c: MangaChapter) => c.uuid === this.currentUuid);
      if (idx >= 0) {
        this.chapterIndex = idx;
      }
    }).catch((_e: Object) => {
      // 无网络且无快照时走下面的空列表兜底
    });
    let uuid = this.startUuid;
    if (uuid.length === 0) {
      const saved = Prefs.getMangaProgress(this.pathWord);
      uuid = saved.length > 0 ? saved.split('|')[0] : '';
    }
    if (uuid.length === 0 && this.chapters.length > 0) {
      uuid = this.chapters[0].uuid;
    }
    if (uuid.length === 0) {
      // 没有进度、本地也没有章节列表且网络拉不到:给明确错误而不是空转
      this.loading = false;
      this.error = '章节列表加载失败(无网络且无本地缓存)';
      return;
    }
    this.loadChapterByUuid(uuid);
  }

  /** 记录某话的章节内滚动位置(换话/退出前调用;y 来自 onDidScroll 的 lastY) */
  private saveScrollPos(uuid: string): void {
    if (uuid.length === 0 || this.pages.length === 0) {
      return;
    }
    Prefs.saveMangaScrollPos(this.pathWord, uuid, this.lastY);
  }

  async loadChapterByUuid(uuid: string, scrollTop: boolean = true): Promise<void> {
    this.dismissChrome(); // 翻话时收起信息栏与菜单
    if (uuid.length === 0) {
      this.error = '没有更多章节';
      return;
    }
    // 换话前把当前话读到的滚动位置记下来
    if (this.currentUuid !== uuid) {
      this.saveScrollPos(this.currentUuid);
    }
    this.loading = true;
    this.error = '';
    this.offline = false;
    // ① 本地直开:清单命中且图片全部已缓存(二次进入/批量下载过)→ 零网络
    const pre = MangaCache.loadChapterList(uuid);
    if (pre !== null && MangaCache.allCached(pre.images)) {
      this.applyChapter(uuid, pre.name, pre.images, scrollTop, false);
      this.loading = false;
      return;
    }
    // ② 走网络(顺带把清单落盘)
    try {
      let imgs: MangaChapterImages | null = null;
      try {
        imgs = await MangaClient.chapterImages(this.pathWord, uuid);
        MangaCache.saveChapterList(uuid, { name: imgs.chapterName, images: imgs.images });
      } catch (e) {
        // 网络失败 → 离线兜底(清单有缓存就用,图片有几张算几张)
        const cached = MangaCache.loadChapterList(uuid);
        if (cached !== null && cached.images.length > 0) {
          const fallback: MangaChapterImages = {
            chapterUuid: uuid, chapterName: cached.name, images: cached.images, prevUuid: '', nextUuid: ''
          };
          imgs = fallback;
          this.offline = true;
        }
      }
      if (imgs === null) {
        this.error = '章节加载失败(无网络且无缓存)';
        return;
      }
      // 离线兜底时不做无谓的下载尝试(每张都要白等超时),未缓存页靠 onError 占位
      this.applyChapter(uuid, imgs.chapterName, imgs.images, scrollTop, !this.offline);
    } catch (e) {
      this.error = `${e}`;
      Log.warn('manga chapter load failed', this.error);
    } finally {
      this.loading = false;
    }
  }

  /** 渲染一话;needDownload=false 时全本地零网络(不触发下载与预载) */
  private applyChapter(uuid: string, name: string, images: string[], scrollTop: boolean,
    needDownload: boolean): void {
    this.currentUuid = uuid;
    this.chapterName = name;
    const idx = this.chapters.findIndex((c: MangaChapter) => c.uuid === uuid);
    this.chapterIndex = idx >= 0 ? idx : 0;
    Prefs.saveMangaProgress(this.pathWord, uuid, name, this.chapterIndex);
    // 已缓存的直接 file:// 秒开;未缓存的先网络占位
    const vms: PageVM[] = [];
    for (const u of images) {
      vms.push(new PageVM(u, MangaCache.srcFor(u)));
    }
    this.pages = vms;
    if (scrollTop) {
      this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
      // 首次进入同一话时恢复上次的章节内位置(偏移为近似值,图片加载后略有偏差)
      if (this.firstLoad) {
        this.firstLoad = false;
        const sp = Prefs.getMangaScrollPos(this.pathWord);
        const sep = sp.indexOf('|');
        if (sep > 0 && sp.substring(0, sep) === uuid) {
          const y = Number(sp.substring(sep + 1));
          if (y > 0) {
            setTimeout(() => {
              if (this.currentUuid === uuid) {
                this.scroller.scrollTo({ xOffset: 0, yOffset: y, animation: false });
              }
            }, 350);
          }
        }
      }
    }
    this.cacheDone = images.length;
    this.cacheTotal = images.length;
    if (!needDownload) {
      return;
    }
    // 后台并发下载本话全部图片,完成一张换一张 src
    this.cacheDone = 0;
    MangaCache.downloadAll(images, 3, (url: string, done: number, total: number) => {
      this.cacheDone = done;
      this.cacheTotal = total;
      const p = MangaCache.localPath(url);
      if (p.length > 0) {
        const vm = this.pages.find((v: PageVM) => v.url === url);
        if (vm !== undefined) {
          vm.src = `file://${p}`;
        }
      }
    }).then(() => {
      // 本话下完 → 预载下一话(清单+图片),翻过去就是全本地
      this.prefetchNext();
    }).catch(() => {
    });
  }

  /** 预载下一话:静默拉清单并下载全部图片 */
  async prefetchNext(): Promise<void> {
    const next = this.chapters[this.chapterIndex + 1];
    if (next === undefined) {
      return;
    }
    try {
      let urls: string[] = [];
      const cachedList = MangaCache.loadChapterList(next.uuid);
      if (cachedList !== null && cachedList.images.length > 0) {
        urls = cachedList.images;
      } else {
        const ni = await MangaClient.chapterImages(this.pathWord, next.uuid);
        MangaCache.saveChapterList(next.uuid, { name: ni.chapterName, images: ni.images });
        urls = ni.images;
      }
      await MangaCache.downloadAll(urls, 2);
      Log.info('next chapter prefetched', next.name);
    } catch (e) {
      // 预载失败静默(联网时正常路径不受影响)
    }
  }

  /** 单图重试:联网补下成功换本地 src;仍失败回到占位(离线时的未缓存页) */
  private retryImage(vm: PageVM): void {
    vm.failed = false;
    MangaCache.download(vm.url).then((ok: boolean) => {
      const p = ok ? MangaCache.localPath(vm.url) : '';
      if (p.length > 0) {
        vm.src = `file://${p}`;
      } else {
        vm.failed = true;
      }
    });
  }

  async goChapter(delta: number): Promise<void> {
    const target = this.chapterIndex + delta;
    if (target < 0 || target >= this.chapters.length) {
      return;
    }
    const ch = this.chapters[target];
    await this.loadChapterByUuid(ch.uuid);
  }

  aboutToDisappear(): void {
    this.saveScrollPos(this.currentUuid);
    this.dismissChrome();
    AppChrome.setFullscreen(false);
    AppChrome.showSystemBars(getContext(this));
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 图片滚动区:点图片呼出菜单,滑动手势完全交给 Scroll
        Scroll(this.scroller) {
          Column() {
            ForEach(this.pages, (vm: PageVM, idx: number) => {
              if (vm.failed) {
                // 离线遇到没缓存的页:占位+重试,不整话报废
                Column({ space: 10 }) {
                  Text('此页未缓存')
                    .fontSize(14)
                    .fontColor('#999999')
                  Text('联网后点下方按钮补下')
                    .fontSize(12)
                    .fontColor('#666666')
                  Button('联网重试')
                    .fontSize(13)
                    .backgroundColor('#8A5CF6')
                    .onClick(() => {
                      this.retryImage(vm);
                    })
                }
                .width('100%')
                .height(420)
                .justifyContent(FlexAlign.Center)
                .backgroundColor('#101010')
              } else {
                Image(vm.src)
                  .width('100%')
                  .objectFit(ImageFit.Fill)
                  .alt($r('app.media.startIcon'))
                  .draggable(false)
                  .onError(() => {
                    vm.failed = true;
                  })
                  .onClick(() => {
                    if (this.showChrome) {
                      this.dismissChrome();
                    } else {
                      this.revealChrome();
                    }
                  })
              }
              if (idx === this.pages.length - 1) {
                // 底部:下一话
                Column({ space: 8 }) {
                  Text(`${this.chapterName} 完`)
                    .fontSize(13)
                    .fontColor('#999999')
                  Button(this.chapterIndex < this.chapters.length - 1 ? '下一话' : '已是最后一话')
                    .fontSize(15)
                    .backgroundColor('#8A5CF6')
                    .enabled(this.chapterIndex < this.chapters.length - 1)
                    .onClick(() => {
                      this.goChapter(1);
                    })
                }
                .width('100%')
                .padding(20)
              }
            }, (vm: PageVM) => vm.url)
          }
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onDidScroll((_x: number, y: number, _s: ScrollState) => {
          this.lastY = y; // 滚动位置随时记录,退出/换话直接用,不查 scroller
        })
        // 全屏模式:系统栏已隐藏,内容铺满屏幕,不避让上下安全区

        // 信息栏:默认隐藏,点漫画呼出,3 秒不操作自动淡出;贴顶显示,不避让刘海
        if (this.showChrome) {
          Row() {
            Text(`${this.comicName} · ${this.chapterName}`)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(this.cacheLabel())
              .fontSize(11)
              .fontColor('#DDDDDD')
              .margin({ left: 10 })
          }
          .width('100%')
          .padding({ top: 8, bottom: 8, left: 14, right: 14 })
          .backgroundColor('#CC1E1E1E')
        }

        if (this.loading && this.pages.length === 0) {
          Column({ space: 8 }) {
            LoadingProgress().width(32).height(32)
            Text('加载中…')
              .fontSize(13)
              .fontColor('#FFFFFF')
          }
          .padding(14)
          .backgroundColor('#88000000')
          .borderRadius(10)
          .alignSelf(ItemAlign.Center)
        }

        if (this.error.length > 0) {
          Column({ space: 8 }) {
            Text(this.error)
              .fontSize(13)
              .fontColor('#FF9A9A')
            Button('重试')
              .fontSize(13)
              .onClick(() => {
                this.loadChapterByUuid(this.currentUuid);
              })
          }
          .padding(14)
          .backgroundColor('#88000000')
          .borderRadius(10)
          .alignSelf(ItemAlign.Center)
        }

        // 菜单层:与信息栏一起呼出,点空白处关闭
        if (this.showChrome) {
          Column() {
            Blank()
            Row() {
              Button('上一话')
                .fontSize(14)
                .layoutWeight(1)
                .backgroundColor('#66000000')
                .fontColor(Color.White)
                .enabled(this.chapterIndex > 0)
                .onClick(() => {
                  this.dismissChrome();
                  this.goChapter(-1);
                })
              Button('目录')
                .fontSize(14)
                .layoutWeight(1)
                .backgroundColor('#66000000')
                .fontColor(Color.White)
                .onClick(() => {
                  this.dismissChrome();
                  this.showChapterSheet = true;
                })
              Button('回顶部')
                .fontSize(14)
                .layoutWeight(1)
                .backgroundColor('#66000000')
                .fontColor(Color.White)
                .onClick(() => {
                  this.dismissChrome();
                  this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: 300 } });
                })
              Button('下一话')
                .fontSize(14)
                .layoutWeight(1)
                .backgroundColor('#66000000')
                .fontColor(Color.White)
                .enabled(this.chapterIndex < this.chapters.length - 1)
                .onClick(() => {
                  this.dismissChrome();
                  this.goChapter(1);
                })
            }
            .width('100%')
            .padding({ top: 10, bottom: 14 })
            .backgroundColor('#CC1E1E1E')
          }
          .width('100%')
          .height('100%')
          .alignSelf(ItemAlign.Center)
          .onClick(() => {
            this.dismissChrome();
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      .bindSheet($$this.showChapterSheet, this.chapterSheet(), {
        height: SheetSize.MEDIUM,
        showClose: true,
        title: { title: `${this.comicName} · 目录` }
      })
    }
    .hideTitleBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onBackPressed(() => {
      if (this.showChrome) {
        this.dismissChrome();
        return true;
      }
      return false;
    })
  }

  @Builder
  chapterSheet() {
    List() {
      ForEach(this.chapters, (ch: MangaChapter, index: number) => {
        ListItem() {
          Text(ch.name)
            .fontSize(14)
            .fontColor(index === this.chapterIndex ? '#8A5CF6' : '#444444')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ top: 10, bottom: 10 })
            .width('100%')
            .onClick(() => {
              this.showChapterSheet = false;
              this.loadChapterByUuid(ch.uuid);
            })
        }
      }, (ch: MangaChapter) => ch.uuid)
    }
    .width('100%')
    .height('100%')
    .divider({ strokeWidth: 0.5, color: '#11000000' })
  }
}

@Builder
export function mangaReaderBuilder() {
  MangaReaderPage()
}
