import { promptAction } from '@kit.ArkUI';
import { DownloadManager, DownloadTaskVM } from '../../datasources/manga/DownloadManager';
import { MangaSources } from '../../datasources/manga/MangaSource';
import { MangaCache } from '../../datasources/manga/MangaCache';
import { VideoCache } from '../../datasources/video/VideoCache';
import { VideoDownloadManager, VideoTaskVM } from '../../datasources/video/VideoDownloadManager';

/** 漫画任务行上的来源短标签(双源队列可读) */
function sourceLabel(sourceId: string): string {
  const s = MangaSources.byId(sourceId);
  return s !== undefined ? s.name : '拷贝漫画';
}

/** 全局下载队列:漫画章节任务 + 影视剧集任务(进度/暂停/继续/重试/清理) */
@ComponentV2
export struct DownloadsPage {
  @Local version: number = 0;
  private cb: (() => void) | null = null;

  aboutToAppear(): void {
    MangaCache.init(getContext(this));
    VideoCache.init(getContext(this));
    DownloadManager.restore(); // 幂等:启动时序竞态时兜底恢复
    VideoDownloadManager.restore();
    this.cb = () => {
      this.version++;
    };
    DownloadManager.onChange(this.cb);
    VideoDownloadManager.onChange(this.cb);
  }

  aboutToDisappear(): void {
    if (this.cb !== null) {
      DownloadManager.offChange(this.cb);
      VideoDownloadManager.offChange(this.cb);
    }
  }

  mangaRows(): DownloadTaskVM[] {
    this.version; // 建立依赖:任务增删时重建列表
    return DownloadManager.tasks;
  }

  videoRows(): VideoTaskVM[] {
    this.version;
    return VideoDownloadManager.tasks;
  }

  videoStatusText(t: VideoTaskVM): string {
    if (t.status === 'done') {
      return '完成';
    }
    if (t.status === 'failed') {
      return '失败 · 点重试';
    }
    if (t.status === 'queued') {
      return '排队中';
    }
    if (t.status === 'wifi-wait') {
      return '等待 Wi-Fi';
    }
    if (t.status === 'paused') {
      return '已暂停';
    }
    return t.total > 0 ? `${t.percent()}%` : '准备中';
  }

  build() {
    NavDestination() {
      if (this.mangaRows().length === 0 && this.videoRows().length === 0) {
        Column({ space: 10 }) {
          Text('暂无下载任务')
            .fontSize(15)
            .fontColor('#999999')
          Text('漫画在详情页「选择下载」,影视在详情页「选择下载」批量缓存')
            .fontSize(12)
            .fontColor('#BBBBBB')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          Row() {
            Text(`进行中:漫画 ${DownloadManager.activeCount()} · 影视 ${VideoDownloadManager.activeCount()}`)
              .fontSize(13)
              .fontColor('#666666')
              .layoutWeight(1)
            Text('清除已完成')
              .fontSize(13)
              .fontColor('#CC3333')
              .padding(6)
              .onClick(() => {
                DownloadManager.clearFinished();
                VideoDownloadManager.clearFinished();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10 })

          List({ space: 8 }) {
            // ===== 漫画章节 =====
            ListItem() {
              Text(`漫画章节(${this.mangaRows().length})`)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .width('100%')
                .padding({ top: 4, bottom: 2, left: 4 })
            }
            if (this.mangaRows().length === 0) {
              ListItem() {
                Text('暂无漫画任务')
                  .fontSize(12)
                  .fontColor('#BBBBBB')
                  .width('100%')
                  .padding({ left: 4, top: 2, bottom: 6 })
              }
            } else {
              ForEach(this.mangaRows(), (t: DownloadTaskVM) => {
                ListItem() {
                  this.mangaRow(t)
                }
              }, (t: DownloadTaskVM) => t.uuid)
            }

            // ===== 影视剧集 =====
            ListItem() {
              Text(`影视剧集(${this.videoRows().length})`)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .width('100%')
                .padding({ top: 10, bottom: 2, left: 4 })
            }
            if (this.videoRows().length === 0) {
              ListItem() {
                Text('暂无影视任务')
                  .fontSize(12)
                  .fontColor('#BBBBBB')
                  .width('100%')
                  .padding({ left: 4, top: 2, bottom: 6 })
              }
            } else {
              ForEach(this.videoRows(), (t: VideoTaskVM) => {
                ListItem() {
                  this.videoRow(t)
                }
              }, (t: VideoTaskVM) => `${t.sourceId}_${t.vodId}_${t.episodeIndex}`)
            }
          }
          .width('100%')
          .layoutWeight(1)
          .padding(12)
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#F1F3F5')
      }
    }
    .title('下载队列')
    .backgroundColor('#F1F3F5')
  }

  @Builder
  mangaRow(t: DownloadTaskVM) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(`${sourceLabel(t.sourceId)}·${t.comicName}`)
          .fontSize(12)
          .fontColor('#999999')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(t.chapterName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (t.status === 'done') {
          Text('完成')
            .fontSize(12)
            .fontColor('#2E8B57')
        } else if (t.status === 'failed') {
          Text('失败 · 点重试')
            .fontSize(12)
            .fontColor('#CC3333')
        } else if (t.status === 'queued') {
          Text('排队中')
            .fontSize(12)
            .fontColor('#999999')
        } else if (t.status === 'paused') {
          Text('已暂停')
            .fontSize(12)
            .fontColor('#CC8A2B')
        } else {
          Text(`${t.done}/${t.total}`)
            .fontSize(12)
            .fontColor('#8A5CF6')
        }
      }
      .width('100%')

      if ((t.status === 'downloading' || t.status === 'paused') && t.total > 0) {
        Progress({ value: t.done, total: t.total })
          .width('100%')
          .height(4)
          .color(t.status === 'paused' ? '#CC8A2B' : '#8A5CF6')
      }

      Row({ space: 10 }) {
        if (t.status === 'queued' || t.status === 'downloading') {
          Text('暂停')
            .fontSize(12)
            .fontColor('#8A5CF6')
            .onClick(() => {
              DownloadManager.pause(t);
              promptAction.showToast({ message: '已暂停,已完成图片会保留' });
            })
        }
        if (t.status === 'paused') {
          Text('继续')
            .fontSize(12)
            .fontColor('#8A5CF6')
            .onClick(() => {
              DownloadManager.resume(t);
            })
        }
        if (t.status === 'failed') {
          Text('重试')
            .fontSize(12)
            .fontColor('#8A5CF6')
            .onClick(() => {
              DownloadManager.retry(t);
              promptAction.showToast({ message: '已重新排队' });
            })
        }
        Blank()
        Text('移除')
          .fontSize(12)
          .fontColor('#CC3333')
          .onClick(() => {
            DownloadManager.remove(t);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Color.White)
    .borderRadius(10)
  }

  @Builder
  videoRow(t: VideoTaskVM) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(t.title)
          .fontSize(12)
          .fontColor('#999999')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(t.episodeName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.videoStatusText(t))
          .fontSize(12)
          .fontColor(t.status === 'failed' ? '#CC3333'
            : t.status === 'wifi-wait' ? '#CC8A2B'
              : t.status === 'done' ? '#2E8B57' : '#3471D5')
      }
      .width('100%')

      if (t.status === 'downloading' || t.status === 'paused') {
        Progress({ value: t.percent(), total: 100 })
          .width('100%')
          .height(4)
          .color(t.status === 'paused' ? '#CC8A2B' : '#3471D5')
      }
      if (t.bytes > 0 && t.status !== 'done') {
        Text(`已写入 ${(t.bytes / 1073741824).toFixed(2)}GB`)
          .fontSize(11)
          .fontColor('#999999')
      }

      Row({ space: 10 }) {
        if (t.status === 'queued' || t.status === 'downloading') {
          Text('暂停')
            .fontSize(12)
            .fontColor('#3471D5')
            .onClick(() => {
              VideoDownloadManager.pause(t);
              promptAction.showToast({ message: '已暂停,断点已保留,续传接着下' });
            })
        }
        if (t.status === 'paused') {
          Text('继续')
            .fontSize(12)
            .fontColor('#3471D5')
            .onClick(() => {
              VideoDownloadManager.resume(t);
            })
        }
        if (t.status === 'failed') {
          Text('重试')
            .fontSize(12)
            .fontColor('#3471D5')
            .onClick(() => {
              VideoDownloadManager.retry(t);
              promptAction.showToast({ message: '已重新排队,失败位置续传' });
            })
        }
        Blank()
        Text('移除')
          .fontSize(12)
          .fontColor('#CC3333')
          .onClick(() => {
            VideoDownloadManager.remove(t);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Color.White)
    .borderRadius(10)
  }
}

@Builder
export function downloadsPageBuilder() {
  DownloadsPage()
}
