import { promptAction } from '@kit.ArkUI';
import { MangaCache } from '../../datasources/manga/MangaCache';
import { DownloadManager } from '../../datasources/manga/DownloadManager';
import { VideoCache } from '../../datasources/video/VideoCache';
import { VideoDownloadManager, VideoTaskVM } from '../../datasources/video/VideoDownloadManager';
import { Prefs } from '../../db/Prefs';
import { Nav } from '../../common/Nav';
import { MangaDetailNavParam, VideoDetailNavParam } from '../../common/NavParams';
import { Log } from '../../common/Logger';

/** 离线库一行(漫画):本地快照 + 缓存进度(可整部删除) */
interface OfflineComicRow {
  pathWord: string;
  name: string;
  cover: string;
  sourceId: string; // 所属漫画源(打开详情按它路由;旧快照缺省 copymanga)
  cachedCount: number;
  totalCount: number;
  savedAt: number;
}

/** 离线库一行(影视):已下载集数 + 占用空间(可整部删除) */
interface OfflineVideoRow {
  key: string;
  sourceId: number;
  vodId: number;
  title: string;
  cover: string;
  cachedCount: number;
  totalCount: number;
  bytes: number;
  savedAt: number;
}

/** 离线与下载:已缓存漫画/影视列表(离线可进详情播放)+ 下载队列入口 */
@ComponentV2
export struct OfflineLibraryPage {
  @Local rows: OfflineComicRow[] = [];
  @Local videoRows: OfflineVideoRow[] = [];
  @Local version: number = 0;
  @Local loaded: boolean = false;

  aboutToAppear(): void {
    MangaCache.init(getContext(this));
    VideoCache.init(getContext(this));
    DownloadManager.restore(); // 幂等
    VideoDownloadManager.restore();
    this.refresh();
  }

  /** 重扫快照目录;行数据 = 快照 + 已缓存标记(读 version 建立依赖刷新) */
  refresh(): void {
    this.version;
    const out: OfflineComicRow[] = [];
    for (const pw of MangaCache.allSnapshotComics()) {
      const snap = MangaCache.loadComicSnapshot(pw);
      if (snap === null) {
        continue;
      }
      const marks = Prefs.getDownloadedChapters(pw);
      const row: OfflineComicRow = {
        pathWord: pw,
        name: snap.detail.name,
        cover: snap.detail.cover,
        sourceId: snap.sourceId !== undefined && snap.sourceId.length > 0 ? snap.sourceId : 'copymanga',
        cachedCount: Math.min(marks.length, snap.chapters.length),
        totalCount: snap.chapters.length,
        savedAt: snap.savedAt
      };
      out.push(row);
    }
    out.sort((a: OfflineComicRow, b: OfflineComicRow) => b.savedAt - a.savedAt);
    this.rows = out;

    const vout: OfflineVideoRow[] = [];
    for (const key of VideoCache.allSnapshots()) {
      const sep = key.indexOf('_');
      if (sep <= 0) {
        continue;
      }
      const sourceId = Number(key.substring(0, sep));
      const vodId = Number(key.substring(sep + 1));
      const snap = VideoCache.loadVideo(sourceId, vodId);
      if (snap === null) {
        continue;
      }
      const marks = Prefs.getDownloadedEpisodes(sourceId, vodId);
      let bytes = 0;
      for (const idx of marks) {
        bytes += VideoCache.episodeSize(sourceId, vodId, idx);
      }
      const idxSet: number[] = [];
      for (const route of snap.video.routes) {
        for (const ep of route.episodes) {
          if (idxSet.indexOf(ep.index) < 0) {
            idxSet.push(ep.index);
          }
        }
      }
      const row: OfflineVideoRow = {
        key: key,
        sourceId: sourceId,
        vodId: vodId,
        title: snap.video.title,
        cover: snap.video.cover,
        cachedCount: marks.length,
        totalCount: idxSet.length,
        bytes: bytes,
        savedAt: snap.savedAt
      };
      vout.push(row);
    }
    vout.sort((a: OfflineVideoRow, b: OfflineVideoRow) => b.savedAt - a.savedAt);
    this.videoRows = vout;
    this.loaded = true;
  }

  openComic(row: OfflineComicRow): void {
    const params: MangaDetailNavParam = {
      pathWord: row.pathWord,
      name: row.name,
      cover: row.cover,
      sourceId: row.sourceId
    };
    Nav.stack.pushPathByName('MangaDetail', params);
  }

  openVideo(row: OfflineVideoRow): void {
    const params: VideoDetailNavParam = {
      sourceId: row.sourceId,
      vodId: row.vodId,
      title: row.title,
      cover: row.cover,
      remarks: ''
    };
    Nav.stack.pushPathByName('VideoDetail', params);
  }

  /** 长按整部删除(漫画):本地快照/清单/图片/封面 + dl_ 标记一并清掉 */
  confirmDeleteComic(row: OfflineComicRow): void {
    promptAction.showDialog({
      title: '删除离线数据',
      message: `删除《${row.name}》的快照与已缓存 ${row.cachedCount} 话?图片文件会一并删除。`,
      buttons: [
        { text: '删除', color: '#CC3333' },
        { text: '取消', color: '#666666' }
      ]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index !== 0) {
        return;
      }
      MangaCache.deleteComic(row.pathWord);
      Prefs.setDownloadedChapters(row.pathWord, []);
      this.refresh();
      promptAction.showToast({ message: '已删除' });
    }).catch((e: Object) => {
      Log.warn('showDialog failed', `${e}`);
    });
  }

  /** 长按整部删除(影视):成片/断点/快照/标记;有进行中任务先拒绝 */
  confirmDeleteVideo(row: OfflineVideoRow): void {
    const active = VideoDownloadManager.tasks.find((t: VideoTaskVM) =>
      t.sourceId === row.sourceId && t.vodId === row.vodId
      && (t.status === 'queued' || t.status === 'downloading' || t.status === 'wifi-wait'));
    if (active !== undefined) {
      promptAction.showToast({ message: '这部剧有下载中的任务,先暂停或等完成再删' });
      return;
    }
    const sizeText = row.bytes > 0 ? `共 ${(row.bytes / 1073741824).toFixed(2)}GB` : '暂无成片';
    promptAction.showDialog({
      title: '删除离线数据',
      message: `删除《${row.title}》的快照与已缓存 ${row.cachedCount} 集?${sizeText}。`,
      buttons: [
        { text: '删除', color: '#CC3333' },
        { text: '取消', color: '#666666' }
      ]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index !== 0) {
        return;
      }
      VideoCache.deleteVideo(row.sourceId, row.vodId);
      this.refresh();
      promptAction.showToast({ message: '已删除' });
    }).catch((e: Object) => {
      Log.warn('showDialog failed', `${e}`);
    });
  }

  @Builder
  comicRow(row: OfflineComicRow) {
    Row({ space: 12 }) {
      Image(MangaCache.srcFor(row.cover))
        .width(66)
        .height(88)
        .borderRadius(6)
        .objectFit(ImageFit.Cover)
        .alt($r('app.media.startIcon'))
      Column({ space: 4 }) {
        Text(row.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(row.cachedCount >= row.totalCount
          ? `已缓存全部 ${row.totalCount} 话` : `已缓存 ${row.cachedCount}/${row.totalCount} 话`)
          .fontSize(12)
          .fontColor(row.cachedCount > 0 ? '#2E8B57' : '#999999')
        Text('点按打开 · 长按删除')
          .fontSize(11)
          .fontColor('#BBBBBB')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›')
        .fontSize(20)
        .fontColor('#BBBBBB')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Color.White)
    .borderRadius(10)
    .onClick(() => {
      this.openComic(row);
    })
    .gesture(LongPressGesture({ repeat: false })
      .onAction(() => {
        this.confirmDeleteComic(row);
      }))
  }

  @Builder
  videoRow(row: OfflineVideoRow) {
    Row({ space: 12 }) {
      Image(row.cover)
        .width(66)
        .height(88)
        .borderRadius(6)
        .objectFit(ImageFit.Cover)
        .alt($r('app.media.startIcon'))
      Column({ space: 4 }) {
        Text(row.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(row.cachedCount > 0
          ? `已缓存 ${row.cachedCount} 集 · ${(row.bytes / 1073741824).toFixed(2)}GB`
          : '快照已存 · 未下载成片')
          .fontSize(12)
          .fontColor(row.cachedCount > 0 ? '#2E8B57' : '#999999')
        Text('点按打开 · 长按删除')
          .fontSize(11)
          .fontColor('#BBBBBB')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›')
        .fontSize(20)
        .fontColor('#BBBBBB')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Color.White)
    .borderRadius(10)
    .onClick(() => {
      this.openVideo(row);
    })
    .gesture(LongPressGesture({ repeat: false })
      .onAction(() => {
        this.confirmDeleteVideo(row);
      }))
  }

  build() {
    NavDestination() {
      Column() {
        List({ space: 10 }) {
          // 下载队列入口(漫画章节 + 视频任务的进度/暂停/重试都在各自队列页/详情页)
          ListItem() {
            Row({ space: 12 }) {
              Text('⇣')
                .fontSize(18)
                .fontColor('#8A5CF6')
              Column({ space: 2 }) {
                Text('下载队列')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                Text(`漫画任务 ${DownloadManager.activeCount()} 个 · 影视任务 ${VideoDownloadManager.activeCount()} 个进行中`)
                  .fontSize(12)
                  .fontColor('#999999')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('›')
                .fontSize(20)
                .fontColor('#BBBBBB')
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Color.White)
            .borderRadius(10)
            .onClick(() => {
              Nav.stack.pushPathByName('Downloads', null);
            })
          }

          ListItem() {
            Text(`已缓存漫画(${this.rows.length})`)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .padding({ top: 6, bottom: 2, left: 4, right: 4 })
          }

          if (this.loaded && this.rows.length === 0) {
            ListItem() {
              Column({ space: 8 }) {
                Text('还没有离线漫画')
                  .fontSize(14)
                  .fontColor('#999999')
                Text('在漫画详情页「选择下载」批量缓存章节')
                  .fontSize(12)
                  .fontColor('#BBBBBB')
              }
              .width('100%')
              .padding(30)
            }
          } else {
            ForEach(this.rows, (row: OfflineComicRow) => {
              ListItem() {
                this.comicRow(row)
              }
            }, (row: OfflineComicRow) => `${row.pathWord}-${row.cachedCount}-${this.version}`)
          }

          ListItem() {
            Text(`已缓存影视(${this.videoRows.length})`)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .padding({ top: 10, bottom: 2, left: 4, right: 4 })
          }

          if (this.loaded && this.videoRows.length === 0) {
            ListItem() {
              Column({ space: 8 }) {
                Text('还没有离线影视')
                  .fontSize(14)
                  .fontColor('#999999')
                Text('在影视详情页「选择下载」批量缓存剧集')
                  .fontSize(12)
                  .fontColor('#BBBBBB')
              }
              .width('100%')
              .padding(30)
            }
          } else {
            ForEach(this.videoRows, (row: OfflineVideoRow) => {
              ListItem() {
                this.videoRow(row)
              }
            }, (row: OfflineVideoRow) => `${row.key}-${row.cachedCount}-${this.version}`)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding(12)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F1F3F5')
    }
    .title('离线与下载')
    .backgroundColor('#F1F3F5')
    .onShown(() => {
      // 从详情页返回时刷新缓存数(可能有新下载完成)
      this.version++;
      this.refresh();
    })
  }
}

@Builder
export function offlineLibraryBuilder() {
  OfflineLibraryPage()
}
