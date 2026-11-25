import { promptAction } from '@kit.ArkUI';
import { MangaClient } from '../../datasources/manga/MangaClient';
import { MangaCache } from '../../datasources/manga/MangaCache';
import { DownloadManager, DownloadTaskVM } from '../../datasources/manga/DownloadManager';
import { ComicSnapshot, MangaChapter, MangaDetail } from '../../models/manga/MangaModels';
import { Nav } from '../../common/Nav';
import { MangaDetailNavParam, MangaReaderNavParam } from '../../common/NavParams';
import { Prefs } from '../../db/Prefs';
import { Log } from '../../common/Logger';

/** 章节行在屏幕上的纵向范围,用于滑动多选的命中判断 */
interface RowRect {
  uuid: string;
  top: number;
  bottom: number;
}

/** 漫画详情:信息 + 章节列表 + 多选批量下载(全局下载队列) */
@ComponentV2
export struct MangaDetailPage {
  @Local detail: MangaDetail | null = null;
  @Local chapters: MangaChapter[] = [];
  @Local displayOrder: string = 'asc';
  @Local loading: boolean = true;
  @Local progressChapter: string = '';
  @Local selectMode: boolean = false;
  @Local selectedUuids: string[] = [];
  @Local downloadedUuids: string[] = [];
  @Local offlineMode: boolean = false; // 网络失败但快照顶上时的提示
  @Local dlVersion: number = 0; // DownloadManager 变更信号(驱动任务行数重算)
  private pathWord: string = '';
  private fallbackName: string = '';
  private dlCb: (() => void) | null = null;
  // 滑动多选:按下起点 + 当前划到的章节
  private rowRects: RowRect[] = [];
  @Local dragActive: boolean = false;
  private dragAnchor: string = '';
  private dragSelect: boolean = true;
  private dragLast: string = '';
  listScroller: Scroller = new Scroller();
  private listH: number = 0; // 列表视口高度(边缘自动滚动用)
  private listTop: number = 0; // 列表在窗口里的纵向起点(与行命中坐标同坐标系)

  async aboutToAppear(): Promise<void> {
    const params = Nav.stack.getParamByName('MangaDetail') as MangaDetailNavParam[];
    const p = params !== undefined && params.length > 0 ? params[params.length - 1] : undefined;
    if (p === undefined) {
      return;
    }
    this.pathWord = p.pathWord;
    this.fallbackName = p.name;
    MangaCache.init(getContext(this));
    DownloadManager.restore(); // 幂等:详情页横幅也能看到恢复的队列
    this.downloadedUuids = Prefs.getDownloadedChapters(this.pathWord);
    this.dlCb = () => {
      this.downloadedUuids = Prefs.getDownloadedChapters(this.pathWord);
      this.dlVersion++;
    };
    DownloadManager.onChange(this.dlCb);
    this.loading = true;
    // ① 本地快照先顶上:有快照立即渲染(离线也能进详情),网络刷新放后面
    const snap = MangaCache.loadComicSnapshot(this.pathWord);
    if (snap !== null) {
      this.detail = snap.detail;
      this.chapters = snap.chapters;
      this.loading = false;
    }
    // ② 网络拉最新;成功则写穿透快照(离线兜底数据始终保持较新)
    try {
      const d = await MangaClient.detail(this.pathWord);
      const chs = await MangaClient.chapters(this.pathWord);
      this.detail = d;
      this.chapters = chs;
      this.offlineMode = false;
      const fresh: ComicSnapshot = { detail: d, chapters: chs, savedAt: new Date().getTime() };
      MangaCache.saveComicSnapshot(fresh);
      MangaCache.download(d.cover).then((_ok: boolean) => {
      }); // 封面进本地缓存,离线库/详情页离线打开时用
    } catch (e) {
      if (this.detail === null) {
        promptAction.showToast({ message: `加载失败:${e}` });
      } else {
        this.offlineMode = true; // 快照已渲染,静默降级
        Log.warn('detail offline, using snapshot', this.pathWord, `${e}`);
      }
    } finally {
      this.loading = false;
    }
    const saved = Prefs.getMangaProgress(this.pathWord);
    if (saved.length > 0) {
      this.progressChapter = saved.split('|')[1] ?? '';
    }
  }

  aboutToDisappear(): void {
    if (this.dlCb !== null) {
      DownloadManager.offChange(this.dlCb);
    }
  }

  orderedChapters(): MangaChapter[] {
    // chapters 已按站方 index 升序(第 1 话在前);desc = 新话在前
    if (this.displayOrder === 'desc') {
      return [...this.chapters].reverse();
    }
    return this.chapters;
  }

  /** 该漫画的进行中任务(横幅用;读 dlVersion 建立依赖) */
  activeTasks(): DownloadTaskVM[] {
    this.dlVersion;
    return DownloadManager.tasks.filter((t: DownloadTaskVM) =>
      t.pathWord === this.pathWord && (t.status === 'queued' || t.status === 'downloading'));
  }

  /** 章节行右侧状态文案:'' | 已缓存 | x/y | 排队 | 失败 | 未缓存(读 dlVersion 建立依赖) */
  chapterBadge(uuid: string): string {
    this.dlVersion;
    if (this.downloadedUuids.indexOf(uuid) >= 0) {
      return '已缓存';
    }
    const all = DownloadManager.tasks.filter((t: DownloadTaskVM) =>
      t.pathWord === this.pathWord && t.uuid === uuid);
    const t = all.length > 0 ? all[all.length - 1] : undefined;
    if (t === undefined) {
      // 离线且既没缓存也没任务:明示打开也看不了,不让人误点
      if (this.offlineMode) {
        return '未缓存';
      }
      return '';
    }
    if (t.status === 'queued') {
      return '排队中';
    }
    if (t.status === 'downloading') {
      return `${t.done}/${t.total}`;
    }
    if (t.status === 'paused') {
      return '已暂停';
    }
    if (t.status === 'failed') {
      return '失败';
    }
    return '';
  }

  isSelected(uuid: string): boolean {
    return this.selectedUuids.indexOf(uuid) >= 0;
  }

  toggleSelect(uuid: string): void {
    if (this.isSelected(uuid)) {
      this.selectedUuids = this.selectedUuids.filter((u: string) => u !== uuid);
    } else {
      const next = this.selectedUuids.slice(0);
      next.push(uuid);
      this.selectedUuids = next;
    }
  }

  setSelected(uuid: string, selected: boolean): void {
    const at: number = this.selectedUuids.indexOf(uuid);
    if (selected && at < 0) {
      const next: string[] = this.selectedUuids.slice(0);
      next.push(uuid);
      this.selectedUuids = next;
    } else if (!selected && at >= 0) {
      const next: string[] = this.selectedUuids.slice(0);
      next.splice(at, 1);
      this.selectedUuids = next;
    }
  }

  /** 记录章节行的实时屏幕位置(列表滚动时同步更新) */
  updateRowRect(uuid: string, area: Area): void {
    const top: number = Number(area.globalPosition.y ?? 0);
    const rect: RowRect = {
      uuid: uuid,
      top: top,
      bottom: top + Number(area.height ?? 0)
    };
    let found: boolean = false;
    for (let i: number = 0; i < this.rowRects.length; i++) {
      if (this.rowRects[i].uuid === uuid) {
        this.rowRects[i] = rect;
        found = true;
        break;
      }
    }
    if (!found) {
      this.rowRects.push(rect);
    }
  }

  /** 屏幕纵坐标命中哪一章 */
  uuidAtY(y: number): string {
    for (let i: number = 0; i < this.rowRects.length; i++) {
      const r: RowRect = this.rowRects[i];
      if (y >= r.top - 4 && y <= r.bottom + 4) {
        return r.uuid;
      }
    }
    return '';
  }

  /** 把起点到终点之间的章节统一设为 selected（反向拖动即取消） */
  selectRange(anchor: string, hit: string, selected: boolean): void {
    const ordered: MangaChapter[] = this.orderedChapters();
    let a: number = -1;
    let b: number = -1;
    for (let i: number = 0; i < ordered.length; i++) {
      if (ordered[i].uuid === anchor) {
        a = i;
      }
      if (ordered[i].uuid === hit) {
        b = i;
      }
    }
    if (a < 0 || b < 0) {
      return;
    }
    if (a > b) {
      const t: number = a;
      a = b;
      b = t;
    }
    const next: string[] = this.selectedUuids.slice(0);
    for (let i: number = a; i <= b; i++) {
      const uuid: string = ordered[i].uuid;
      const at: number = next.indexOf(uuid);
      if (selected && at < 0) {
        next.push(uuid);
      } else if (!selected && at >= 0) {
        next.splice(at, 1);
      }
    }
    this.selectedUuids = next;
  }

  /** 从左侧圆圈按下并滑动 -> 经过的行批量设为同一状态；用 windowY 命中，不干扰列表上下滑 */
  onCheckTouch(uuid: string, event: TouchEvent): void {
    if (!this.selectMode) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.dragActive = true;
      this.dragAnchor = uuid;
      this.dragLast = uuid;
      this.dragSelect = !this.isSelected(uuid);
      this.setSelected(uuid, this.dragSelect);
    } else if (event.type === TouchType.Move && this.dragActive) {
      const y: number = event.touches[0].windowY;
      const hit: string = this.uuidAtY(y);
      if (hit.length > 0 && hit !== this.dragLast) {
        this.selectRange(this.dragAnchor, hit, this.dragSelect);
        this.dragLast = hit;
      }
      // 拖到视口上下边缘 90vp 内:每次移动事件滚一小步,连续 Move 就成了匀速滚动
      if (this.listH > 0) {
        const topLimit: number = this.listTop + 90;
        const bottomLimit: number = this.listTop + this.listH - 90;
        if (y < topLimit) {
          this.listScroller.scrollBy(0, -26);
        } else if (y > bottomLimit) {
          this.listScroller.scrollBy(0, 26);
        }
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.dragActive = false;
      this.dragLast = '';
    }
  }

  selectAll(): void {
    this.selectedUuids = this.orderedChapters().map((c: MangaChapter) => c.uuid);
  }

  exitSelectMode(): void {
    this.selectMode = false;
    this.selectedUuids = [];
    this.dragActive = false;
    this.rowRects = [];
  }

  confirmDownload(): void {
    const picked = this.orderedChapters().filter((c: MangaChapter) => this.isSelected(c.uuid));
    if (picked.length === 0) {
      promptAction.showToast({ message: '先勾选要下载的话' });
      return;
    }
    if (this.detail === null) {
      promptAction.showToast({ message: '详情未加载,不能下载' });
      return;
    }
    const added = DownloadManager.enqueue(this.detail, picked);
    this.exitSelectMode();
    promptAction.showToast({ message: added > 0 ? `已加入下载队列(${added} 话),可在「我的→下载管理」查看` : '所选章节已在队列或已缓存' });
  }

  startReading(chapterUuid: string): void {
    const params: MangaReaderNavParam = {
      pathWord: this.pathWord,
      comicName: this.detail !== null ? this.detail.name : this.fallbackName,
      startChapterUuid: chapterUuid
    };
    Nav.stack.pushPathByName('MangaReader', params);
  }

  @Builder
  chapterRow(ch: MangaChapter) {
    Row({ space: 10 }) {
      if (this.selectMode) {
        Text(this.isSelected(ch.uuid) ? '✓' : '')
          .fontSize(14)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .width(22)
          .height(22)
          .borderRadius(11)
          .backgroundColor(this.isSelected(ch.uuid) ? '#8A5CF6' : '#DDDDDD')
          // 圆圈是滑动多选的把手:按住它滑动才范围选中;行其他区域滑动仍只滚动列表
          .onTouch((event: TouchEvent) => {
            this.onCheckTouch(ch.uuid, event);
          })
      }
      Text(ch.name)
        .fontSize(14)
        .fontColor(ch.name === this.progressChapter ? '#8A5CF6' : '#444444')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(this.chapterBadge(ch.uuid))
        .fontSize(11)
        .fontColor(this.chapterBadge(ch.uuid) === '失败' ? '#CC3333' : '#999999')
        .padding({ left: 6, right: 6 })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 14, right: 14 })
    .backgroundColor('#F1F3F5')
    .onAreaChange((_old: Area, newValue: Area) => {
      this.updateRowRect(ch.uuid, newValue);
    })
    .onClick(() => {
      // 多选模式的勾选已由 onTouch 处理，这里只负责非多选时进入阅读
      if (!this.selectMode) {
        this.startReading(ch.uuid);
      }
    })
  }

  @Builder
  navTitle() {
    Row() {
      Text(this.detail !== null ? this.detail.name : this.fallbackName)
        .fontSize(16)
        .fontColor('#333333')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(48)
    .padding({ left: 4, right: 12 })
    .backgroundColor('#F1F3F5')
  }

  build() {
    NavDestination() {
      if (this.loading) {
        Column({ space: 8 }) {
          LoadingProgress().width(36).height(36)
          Text('加载中…').fontSize(13).fontColor('#999999')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.detail !== null) {
        Column() {
          List({ space: 0, scroller: this.listScroller }) {
            // 离线提示横幅:快照顶上时提示数据可能不是最新
            if (this.offlineMode) {
              ListItem() {
                Text('当前离线 · 显示本地缓存的数据')
                  .fontSize(12)
                  .fontColor('#8A5A00')
                  .width('100%')
                  .padding({ top: 8, bottom: 8, left: 14, right: 14 })
                  .backgroundColor('#FFF3D6')
              }
            }

            // 下载进度横幅(有进行中任务才显示)
            if (this.activeTasks().length > 0) {
              ListItem() {
                Column({ space: 4 }) {
                  ForEach(this.activeTasks(), (t: DownloadTaskVM) => {
                    Row({ space: 8 }) {
                      Text(t.status === 'queued' ? '排队' : '下载中')
                        .fontSize(12)
                        .fontColor('#8A5CF6')
                      Text(t.chapterName)
                        .fontSize(12)
                        .fontColor('#444444')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      Text(`${t.done}/${t.total}`)
                        .fontSize(12)
                        .fontColor('#999999')
                    }
                    .width('100%')
                  }, (t: DownloadTaskVM) => `${t.uuid}-${t.done}-${t.status}`)
                  if (DownloadManager.activeCount() > this.activeTasks().length) {
                    Text(`队列中还有 ${DownloadManager.activeCount() - this.activeTasks().length} 话待下载 · 我的→下载管理`)
                      .fontSize(11)
                      .fontColor('#999999')
                  }
                }
                .width('100%')
                .padding(12)
                .backgroundColor('#F1EAFE')
              }
            }

            // 头部:封面 + 信息
            ListItem() {
              Row({ space: 14 }) {
                // 封面走本地缓存优先:离线时详情页封面也能显示
                Image(MangaCache.srcFor(this.detail.cover))
                  .width(104)
                  .height(140)
                  .borderRadius(8)
                  .objectFit(ImageFit.Cover)
                  .alt($r('app.media.startIcon'))
                Column({ space: 5 }) {
                  Text(this.detail.name)
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                  Text(this.detail.author)
                    .fontSize(14)
                    .fontColor('#666666')
                  if (this.detail.themes.length > 0) {
                    Flex({ wrap: FlexWrap.Wrap }) {
                      ForEach(this.detail.themes, (t: string) => {
                        Text(t)
                          .fontSize(11)
                          .fontColor('#8A5CF6')
                          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                          .backgroundColor('#F1EAFE')
                          .borderRadius(4)
                          .margin(2)
                      }, (t: string) => t)
                    }
                  }
                  Text(`更新:${this.detail.updatedAt.substring(0, 10)} · 已缓存 ${this.downloadedUuids.length} 话`)
                    .fontSize(12)
                    .fontColor('#999999')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding(16)
              .backgroundColor('#F1F3F5')
            }

            // 简介
            if (this.detail.description.length > 0) {
              ListItem() {
                Text(this.detail.description)
                  .fontSize(13)
                  .fontColor('#666666')
                  .maxLines(5)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .padding(14)
                  .backgroundColor('#F1F3F5')
              }
            }

            // 章节标题行
            ListItem() {
              Row() {
                Text(`章节(${this.chapters.length})`)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                Blank()
                Text(this.selectMode ? '取消选择' : '选择下载')
                  .fontSize(13)
                  .fontColor('#8A5CF6')
                  .padding(6)
                  .onClick(() => {
                    if (this.selectMode) {
                      this.exitSelectMode();
                    } else {
                      this.dragActive = false;
                      this.rowRects = [];
                      this.selectMode = true;
                    }
                  })
                Text(this.selectMode ? '' : (this.displayOrder === 'asc' ? '正序 ∨' : '倒序 ∨'))
                  .fontSize(13)
                  .fontColor('#8A5CF6')
                  .padding(6)
                  .onClick(() => {
                    this.displayOrder = this.displayOrder === 'asc' ? 'desc' : 'asc';
                  })
              }
              .width('100%')
              .padding({ top: 12, left: 14, right: 8, bottom: 4 })
              .backgroundColor('#F1F3F5')
            }

            // 章节列表(懒加载)
            ForEach(this.orderedChapters(), (ch: MangaChapter) => {
              ListItem() {
                this.chapterRow(ch)
              }
            }, (ch: MangaChapter) => `${ch.uuid}-${this.displayOrder}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .onAreaChange((_old: Area, newValue: Area) => {
            this.listH = Number(newValue.height ?? 0);
            this.listTop = Number(newValue.globalPosition.y ?? 0);
          })
          // 按住圆圈做范围选中时禁用列表滚动，松开恢复；避免上下滑与选择冲突
          .enableScrollInteraction(!this.dragActive)

          // 底部操作栏
          if (this.selectMode) {
            Row({ space: 10 }) {
              Button('取消')
                .fontSize(15)
                .layoutWeight(1)
                .backgroundColor('#F0F0F0')
                .fontColor('#333333')
                .onClick(() => {
                  this.exitSelectMode();
                })
              Button('全选')
                .fontSize(15)
                .layoutWeight(1)
                .backgroundColor('#F0F0F0')
                .fontColor('#333333')
                .onClick(() => {
                  this.selectAll();
                })
              Button(`下载(${this.selectedUuids.length})`)
                .fontSize(15)
                .layoutWeight(2)
                .backgroundColor('#8A5CF6')
                .onClick(() => {
                  this.confirmDownload();
                })
            }
            .width('100%')
            .padding(12)
            .backgroundColor('#F1F3F5')
          } else {
            Button(this.progressChapter.length > 0 ? `继续:${this.progressChapter}` : '从第一话开始阅读')
              .fontSize(15)
              .width('94%')
              .margin({ bottom: 14 })
              .backgroundColor('#8A5CF6')
              .onClick(() => {
                const saved = Prefs.getMangaProgress(this.pathWord);
                const uuid = saved.length > 0 ? saved.split('|')[0] : '';
                if (uuid.length > 0) {
                  this.startReading(uuid);
                } else {
                  const ordered = this.orderedChapters();
                  const first = ordered.length > 0 ? ordered[0] : undefined;
                  if (first !== undefined) {
                    this.startReading(first.uuid);
                  }
                }
              })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#F1F3F5')
      }
    }
    // 自定义标题栏:灰底,与内容区一致(系统默认标题栏是白底会割裂)
    .title(this.navTitle())
    // NavDestination 本身也要灰底:返回键区域和 loading 态(内容未出时整页)否则露系统白底
    .backgroundColor('#F1F3F5')
  }
}

@Builder
export function mangaDetailBuilder() {
  MangaDetailPage()
}
