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

/** 任务排序权重:进行中最上,其次暂停/失败,已完成垫底 */
function taskRank(status: string): number {
  if (status === 'downloading') {
    return 0;
  }
  if (status === 'queued' || status === 'wifi-wait') {
    return 1;
  }
  if (status === 'paused') {
    return 2;
  }
  if (status === 'failed') {
    return 3;
  }
  return 4; // done
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
    const list = DownloadManager.tasks.slice(0);
    list.sort((a: DownloadTaskVM, b: DownloadTaskVM) => taskRank(a.status) - taskRank(b.status));
    return list;
  }

  videoRows(): VideoTaskVM[] {
    this.version;
    const list = VideoDownloadManager.tasks.slice(0);
    list.sort((a: VideoTaskVM, b: VideoTaskVM) => taskRank(a.status) - taskRank(b.status));
    return list;
  }

  pausedCount(): number {
    this.version;
    return DownloadManager.tasks.filter((t: DownloadTaskVM) => t.status === 'paused').length
      + VideoDownloadManager.tasks.filter((t: VideoTaskVM) => t.status === 'paused').length;
  }

  /** 一键停止:漫画与影视所有进行中任务全部暂停(断点/已下内容都保留) */
  pauseAll(): void {
    let n = 0;
    for (const t of DownloadManager.tasks) {
      if (t.status === 'queued' || t.status === 'downloading') {
        DownloadManager.pause(t);
        n++;
      }
    }
    for (const t of VideoDownloadManager.tasks) {
      if (t.status === 'queued' || t.status === 'downloading' || t.status === 'wifi-wait') {
        VideoDownloadManager.pause(t);
        n++;
      }
    }
    promptAction.showToast({ message: n > 0 ? `已暂停 ${n} 个任务` : '没有进行中的任务' });
  }

  /** 一键继续所有已暂停任务 */
  resumeAll(): void {
    for (const t of DownloadManager.tasks) {
      if (t.status === 'paused') {
        DownloadManager.resume(t);
      }
    }
    for (const t of VideoDownloadManager.tasks) {
      if (t.status === 'paused') {
        VideoDownloadManager.resume(t);
      }
    }
    promptAction.showToast({ message: '已全部继续' });
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
          // 工具栏:进行中计数 + 全部停止/继续 + 清理
          Row({ space: 6 }) {
            Text(`进行中:漫画 ${DownloadManager.activeCount()} · 影视 ${VideoDownloadManager.activeCount()}`)
              .fontSize(13)
              .fontColor('#666666')
              .layoutWeight(1)
            if (this.pausedCount() > 0) {
              Text('全部继续')
                .fontSize(13)
                .fontColor('#3471D5')
                .padding(6)
                .onClick(() => {
                  this.resumeAll();
                })
            }
            if (DownloadManager.activeCount() + VideoDownloadManager.activeCount() > 0) {
              Text('全部停止')
                .fontSize(13)
                .fontColor('#CC8A2B')
                .padding(6)
                .onClick(() => {
                  this.pauseAll();
                })
            }
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
          .padding({ left: 16, right: 10, top: 10, bottom: 2 })

          // 漫画/影视 Tab 切换,不用来回滑
          Tabs({ barPosition: BarPosition.Start }) {
            TabContent() {
              if (this.mangaRows().length === 0) {
                Column({ space: 8 }) {
                  Text('暂无漫画任务')
                    .fontSize(14)
                    .fontColor('#999999')
                  Text('在漫画详情页「选择下载」批量缓存章节')
                    .fontSize(12)
                    .fontColor('#BBBBBB')
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
              } else {
                List({ space: 8 }) {
                  ForEach(this.mangaRows(), (t: DownloadTaskVM) => {
                    ListItem() {
                      this.mangaRow(t)
                    }
                  }, (t: DownloadTaskVM) => t.uuid)
                }
                .width('100%')
                .height('100%')
                .padding(12)
                .scrollBar(BarState.Off)
              }
            }
            .tabBar(`漫画(${this.mangaRows().length})`)

            TabContent() {
              if (this.videoRows().length === 0) {
                Column({ space: 8 }) {
                  Text('暂无影视任务')
                    .fontSize(14)
                    .fontColor('#999999')
                  Text('在影视详情页「选择下载」批量缓存剧集')
                    .fontSize(12)
                    .fontColor('#BBBBBB')
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
              } else {
                List({ space: 8 }) {
                  ForEach(this.videoRows(), (t: VideoTaskVM) => {
                    ListItem() {
                      this.videoRow(t)
                    }
                  }, (t: VideoTaskVM) => `${t.sourceId}_${t.vodId}_${t.episodeIndex}`)
                }
                .width('100%')
                .height('100%')
                .padding(12)
                .scrollBar(BarState.Off)
              }
            }
            .tabBar(`影视(${this.videoRows().length})`)
          }
          .barMode(BarMode.Fixed)
          .width('100%')
          .layoutWeight(1)
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
