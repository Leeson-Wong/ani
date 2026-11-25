import { promptAction } from '@kit.ArkUI';
import { statfs } from '@kit.CoreFileKit';
import { MaccmsClient } from '../../datasources/cms/MaccmsClient';
import { CmsSourceManager } from '../../datasources/cms/CmsSourceManager';
import { VideoCache } from '../../datasources/video/VideoCache';
import { VideoDownloadManager, VideoTaskVM } from '../../datasources/video/VideoDownloadManager';
import { HlsDownloader } from '../../datasources/video/HlsDownloader';
import { CmsVideo, Episode, PlayRoute } from '../../models/cms/MaccmsModels';
import { DatabaseHelper } from '../../db/DatabaseHelper';
import { WatchHistoryDao } from '../../db/WatchHistoryDao';
import { WatchHistoryRow } from '../../db/DatabaseHelper';
import { Prefs } from '../../db/Prefs';
import { Nav } from '../../common/Nav';
import { NetWatch } from '../../common/NetWatch';
import { VideoDetailNavParam, PlayerNavParam } from '../../common/NavParams';
import { Log } from '../../common/Logger';

const GB = 1073741824;

function gbText(bytes: number): string {
  return `${(bytes / GB).toFixed(1)}GB`;
}

/** 影视详情:海报/简介/线路 Tab + 集数网格;点击集数进播放器(已下载走本地);
 *  集数可多选批量下载(HLS → 单 .ts,仅 Wi-Fi 默认开) */
@ComponentV2
export struct VideoDetailPage {
  @Local video: CmsVideo | null = null;
  @Local loading: boolean = true;
  @Local offlineMode: boolean = false;
  @Local currentRoute: number = 0;
  @Local history: WatchHistoryRow | null = null;
  @Local selectMode: boolean = false;
  @Local selectedKeys: string[] = [];
  @Local downloadedIdxs: number[] = [];
  @Local dlVersion: number = 0; // VideoDownloadManager 变更信号(徽标重算)
  @Local estimating: boolean = false;
  private param: VideoDetailNavParam | null = null;
  private client: MaccmsClient | null = null;
  private dlCb: (() => void) | null = null;

  async aboutToAppear(): Promise<void> {
    const params = Nav.stack.getParamByName('VideoDetail') as VideoDetailNavParam[];
    const p = params !== undefined && params.length > 0 ? params[params.length - 1] : undefined;
    if (p === undefined) {
      return;
    }
    this.param = p;
    VideoCache.init(getContext(this));
    VideoDownloadManager.restore(); // 幂等
    await DatabaseHelper.init(getContext(this));
    this.dlCb = () => {
      this.downloadedIdxs = Prefs.getDownloadedEpisodes(p.sourceId, p.vodId);
      this.dlVersion++;
    };
    VideoDownloadManager.onChange(this.dlCb);
    this.downloadedIdxs = Prefs.getDownloadedEpisodes(p.sourceId, p.vodId);
    // ① 本地快照先顶上(离线可进详情/播放已下载集)
    const snap = VideoCache.loadVideo(p.sourceId, p.vodId);
    if (snap !== null) {
      this.video = snap.video;
      this.loading = false;
    }
    // ② 网络拉最新 + 写穿透
    this.loading = this.video === null;
    try {
      const source = (await CmsSourceManager.list()).find((s) => s.id === p.sourceId);
      if (source === undefined) {
        throw new Error('源不存在');
      }
      this.client = new MaccmsClient(source.id, source.apiBase);
      this.history = await WatchHistoryDao.get(p.sourceId, p.vodId);
      const fresh = await this.client.detail(p.vodId);
      this.video = fresh;
      this.offlineMode = false;
      VideoCache.saveVideo(fresh);
      if (this.history !== null && this.history.routeIndex < fresh.routes.length) {
        this.currentRoute = this.history.routeIndex;
      }
    } catch (e) {
      if (this.video === null) {
        promptAction.showToast({ message: `加载失败:${e}` });
      } else {
        this.offlineMode = true; // 快照已渲染
        Log.warn('video detail offline, using snapshot', `${e}`);
      }
    } finally {
      this.loading = false;
    }
  }

  aboutToDisappear(): void {
    if (this.dlCb !== null) {
      VideoDownloadManager.offChange(this.dlCb);
    }
  }

  /** 该集徽标:'' | 已缓存 | x% | 排队 | 等Wi-Fi | 失败(读 dlVersion 建立依赖) */
  episodeBadge(ep: Episode): string {
    this.dlVersion;
    if (this.downloadedIdxs.indexOf(ep.index) >= 0) {
      return '已缓存';
    }
    const t = VideoDownloadManager.tasks.find((task: VideoTaskVM) =>
      task.sourceId === (this.video !== null ? this.video.sourceId : -1)
      && task.vodId === (this.video !== null ? this.video.vodId : -1)
      && task.episodeIndex === ep.index && task.status !== 'done');
    if (t === undefined) {
      return '';
    }
    if (t.status === 'queued') {
      return '排队';
    }
    if (t.status === 'wifi-wait') {
      return '等Wi-Fi';
    }
    if (t.status === 'downloading') {
      return t.total > 0 ? `${t.percent()}%` : '准备中';
    }
    if (t.status === 'paused') {
      return '已暂停';
    }
    if (t.status === 'failed') {
      return '失败';
    }
    return '';
  }

  isSelected(ep: Episode): boolean {
    return this.selectedKeys.indexOf(this.keyOf(ep)) >= 0;
  }

  keyOf(ep: Episode): string {
    return `${this.currentRoute}_${ep.index}`;
  }

  toggleSelect(ep: Episode): void {
    const k = this.keyOf(ep);
    if (this.isSelected(ep)) {
      this.selectedKeys = this.selectedKeys.filter((s: string) => s !== k);
    } else {
      const next = this.selectedKeys.slice(0);
      next.push(k);
      this.selectedKeys = next;
    }
  }

  exitSelectMode(): void {
    this.selectMode = false;
    this.selectedKeys = [];
  }

  currentRouteEpisodes(): Episode[] {
    const v = this.video;
    if (v === null || this.currentRoute >= v.routes.length) {
      return [];
    }
    return v.routes[this.currentRoute].episodes;
  }

  downloadedInRoute(): number {
    return this.currentRouteEpisodes().filter((ep: Episode) => this.downloadedIdxs.indexOf(ep.index) >= 0).length;
  }

  playEpisode(episodeIndex: number): void {
    const v = this.video;
    if (v === null) {
      return;
    }
    const route = v.routes[this.currentRoute];
    if (route === undefined) {
      return;
    }
    const localPath = this.downloadedIdxs.indexOf(episodeIndex) >= 0
      ? VideoCache.episodeFile(v.sourceId, v.vodId, episodeIndex) : '';
    const resume = this.history !== null
      && this.history.episodeIndex === episodeIndex
      && !this.history.finished
      ? this.history.positionMs : 0;
    const params: PlayerNavParam = {
      sourceId: v.sourceId,
      vodId: v.vodId,
      title: v.title,
      cover: v.cover,
      routesJson: JSON.stringify(v.routes),
      routeIndex: this.currentRoute,
      episodeIndex: episodeIndex,
      resumePositionMs: resume,
      localPath: localPath
    };
    Nav.stack.pushPathByName('Player', params, (popInfo: PopInfo) => {
      // 返回时刷新续播信息
      WatchHistoryDao.get(v.sourceId, v.vodId).then((row: WatchHistoryRow | null) => {
        this.history = row;
      });
    });
  }

  /** 确认下载:抽样预估体积 + 剩余空间检查 → 入队(仅 Wi-Fi 开着且非 Wi-Fi 时任务会等网) */
  async confirmDownload(): Promise<void> {
    const v = this.video;
    if (v === null) {
      return;
    }
    const picked = this.currentRouteEpisodes().filter((ep: Episode) => this.isSelected(ep));
    if (picked.length === 0) {
      promptAction.showToast({ message: '先勾选要下载的集' });
      return;
    }
    this.estimating = true;
    let approxBytes = 0;
    let sampleOk = false;
    try {
      const est = await HlsDownloader.estimate(picked[0].url);
      approxBytes = est.approxBytes * picked.length;
      sampleOk = est.total > 0;
    } catch (e) {
      Log.warn('estimate failed', `${e}`);
    }
    let freeBytes = 0;
    try {
      freeBytes = await statfs.getFreeSize(getContext(this).filesDir);
    } catch (e) {
      Log.warn('statvfs failed', `${e}`);
    }
    this.estimating = false;
    if (sampleOk && approxBytes > freeBytes) {
      promptAction.showToast({ message: `空间不足:预计 ${gbText(approxBytes)},剩余 ${gbText(freeBytes)}` });
      return;
    }
    const estText = sampleOk ? `预计约 ${gbText(approxBytes)}(${picked.length} 集,按第 1 集抽样)` : '体积预估失败,仍可继续';
    const freeText = freeBytes > 0 ? `,剩余 ${gbText(freeBytes)}` : '';
    promptAction.showDialog({
      title: '确认下载',
      message: `${estText}${freeText}。${Prefs.getWifiOnly() && !NetWatch.get().wifi ? '当前不是 Wi-Fi,任务会等 Wi-Fi。' : ''}`,
      buttons: [
        { text: '下载', color: '#3471D5' },
        { text: '取消', color: '#666666' }
      ]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index !== 0) {
        return;
      }
      const route = v.routes[this.currentRoute];
      const added = VideoDownloadManager.enqueue(v.sourceId, v.vodId, v.title, v.cover,
        this.currentRoute, picked, v.routes);
      this.exitSelectMode();
      promptAction.showToast({
        message: added > 0
          ? `已加入下载队列(${added} 集)${route !== undefined ? ` · 线路「${route.name}」` : ''}`
          : '所选集已在队列或已缓存'
      });
    }).catch((e: Object) => {
      Log.warn('showDialog failed', `${e}`);
    });
  }

  @Builder
  episodeChip(route: PlayRoute, ep: Episode) {
    Column({ space: 2 }) {
      Text(ep.name)
        .fontSize(13)
        .fontColor(this.history !== null && this.history.episodeIndex === ep.index ? Color.White : '#444444')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.episodeBadge(ep))
        .fontSize(10)
        .fontColor(this.episodeBadge(ep) === '失败' ? '#CC3333' : '#5B9E6A')
        .visibility(this.episodeBadge(ep).length > 0 ? Visibility.Visible : Visibility.None)
    }
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 14, right: 14, top: 7, bottom: 7 })
    .borderRadius(8)
    .margin(4)
    .constraintSize({ maxWidth: 160 })
    .backgroundColor(this.history !== null && this.history.episodeIndex === ep.index ? '#3471D5' : '#F0F0F0')
    .border(this.selectMode && this.isSelected(ep)
      ? { width: 2, color: '#3471D5' }
      : { width: 0, color: Color.Transparent })
    .onClick(() => {
      if (this.selectMode) {
        this.toggleSelect(ep);
      } else {
        this.playEpisode(ep.index);
      }
    })
  }

  @Builder
  episodeGrid(route: PlayRoute) {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
      ForEach(route.episodes, (ep: Episode) => {
        this.episodeChip(route, ep)
      }, (ep: Episode) => `${route.index}-${ep.index}-${this.episodeBadge(ep)}-${this.isSelected(ep)}`)
    }
    .width('100%')
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
      } else if (this.video !== null) {
        Column() {
          Scroll() {
            Column({ space: 14 }) {
              if (this.offlineMode) {
                Text('当前离线 · 显示本地缓存的数据,可播放已缓存集')
                  .fontSize(12)
                  .fontColor('#8A5A00')
                  .width('100%')
                  .padding({ top: 8, bottom: 8, left: 14, right: 14 })
                  .backgroundColor('#FFF3D6')
                  .borderRadius(8)
              }
              Row({ space: 14 }) {
                Image(this.video.cover)
                  .width(110)
                  .height(150)
                  .borderRadius(8)
                  .objectFit(ImageFit.Cover)
                  .alt($r('app.media.startIcon'))
                Column({ space: 5 }) {
                  Text(this.video.title)
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                  Text(`${this.video.year} · ${this.video.area} · ${this.video.category}`)
                    .fontSize(12).fontColor('#999999')
                  Text(this.video.remarks)
                    .fontSize(12).fontColor('#E06C00')
                  Text(`导演:${this.video.director}`)
                    .fontSize(12).fontColor('#999999')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`主演:${this.video.actors}`)
                    .fontSize(12).fontColor('#999999')
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.history !== null) {
                    Text(`上次看到:${this.history.episodeName}`)
                      .fontSize(12).fontColor('#3471D5')
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding(16)
              .backgroundColor(Color.White)
              .borderRadius(12)

              if (this.video.description.length > 0) {
                Text(this.video.description)
                  .fontSize(13)
                  .fontColor('#666666')
                  .maxLines(4)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .padding(14)
                  .backgroundColor(Color.White)
                  .borderRadius(12)
              }

              Column() {
                Row() {
                  Text('选集')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                  Blank()
                  Text(`已缓存 ${this.downloadedInRoute()}/${this.currentRouteEpisodes().length} 集`)
                    .fontSize(12)
                    .fontColor('#5B9E6A')
                    .padding({ left: 8, right: 8 })
                  Text(this.selectMode ? '退出选择' : '选择下载')
                    .fontSize(13)
                    .fontColor('#3471D5')
                    .padding(6)
                    .onClick(() => {
                      if (this.selectMode) {
                        this.exitSelectMode();
                      } else {
                        this.selectMode = true;
                        this.selectedKeys = [];
                      }
                    })
                }
                .width('100%')
                .padding({ top: 12, left: 14, right: 8 })
                if (this.video.routes.length > 1) {
                  Scroll() {
                    Row({ space: 8 }) {
                      ForEach(this.video.routes, (route: PlayRoute) => {
                        Text(route.name)
                          .fontSize(13)
                          .fontColor(this.currentRoute === route.index ? Color.White : '#444444')
                          .backgroundColor(this.currentRoute === route.index ? '#3471D5' : '#F0F0F0')
                          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                          .borderRadius(14)
                          .margin({ top: 6 })
                          .onClick(() => {
                            this.currentRoute = route.index;
                            this.selectedKeys = [];
                          })
                      }, (route: PlayRoute) => `${route.index}-${route.name}`)
                    }
                    .padding({ left: 14, right: 14 })
                  }
                  .scrollable(ScrollDirection.Horizontal)
                  .scrollBar(BarState.Off)
                  .width('100%')
                }
                Column() {
                  if (this.currentRoute < this.video.routes.length) {
                    this.episodeGrid(this.video.routes[this.currentRoute])
                  }
                }
                .width('100%')
                .padding(14)
              }
              .width('100%')
              .backgroundColor(Color.White)
              .borderRadius(12)
            }
            .padding(12)
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)

          // 底部操作栏:选择模式 = 取消/全选/下载;普通 = 继续播放
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
                  this.selectedKeys = this.currentRouteEpisodes().map((ep: Episode) => this.keyOf(ep));
                })
              Button(this.estimating ? '预估中…' : `下载(${this.selectedKeys.length})`)
                .fontSize(15)
                .layoutWeight(2)
                .backgroundColor('#3471D5')
                .enabled(!this.estimating)
                .onClick(() => {
                  this.confirmDownload();
                })
            }
            .width('100%')
            .padding(12)
            .backgroundColor('#F1F3F5')
          } else {
            Button(this.history !== null ? `继续播放:${this.history.episodeName}` : '立即播放')
              .fontSize(15)
              .width('94%')
              .margin({ bottom: 14 })
              .backgroundColor('#3471D5')
              .onClick(() => {
                const start = this.history !== null ? this.history.episodeIndex : 0;
                this.playEpisode(start);
              })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#F1F3F5')
      }
    }
    .title(this.video !== null ? this.video.title : (this.param?.title ?? '详情'))
    // NavDestination 灰底:返回键区域/loading 态不露系统白底(与内容区一致)
    .backgroundColor('#F1F3F5')
  }
}

@Builder
export function videoDetailBuilder() {
  VideoDetailPage()
}
