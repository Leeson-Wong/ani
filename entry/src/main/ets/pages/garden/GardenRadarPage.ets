import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { GardenClient } from '../../datasources/garden/GardenClient';
import { DatabaseHelper } from '../../db/DatabaseHelper';
import { Prefs } from '../../db/Prefs';
import { GardenResource } from '../../models/garden/GardenModels';

function formatSize(bytes: number): string {
  if (bytes <= 0) {
    return '';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

/** 动漫雷达:AnimeGarden 资源搜索,复制磁力给外部下载器 */
@ComponentV2
export struct GardenRadarPage {
  @Local keyword: string = '';
  @Local loading: boolean = false;
  @Local items: GardenResource[] = [];
  @Local page: number = 1;
  @Local searched: boolean = false;
  @Local error: string = '';

  async aboutToAppear(): Promise<void> {
    await DatabaseHelper.init(getContext(this));
    // 默认拉最新资源
    this.load('', 1);
  }

  async load(keyword: string, page: number): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.error = '';
    try {
      const fresh = await GardenClient.resources(keyword, page, 25);
      if (page === 1) {
        this.items = fresh;
      } else {
        this.items = this.items.concat(fresh);
      }
      this.page = page;
      this.searched = keyword.trim().length > 0;
      if (keyword.trim().length > 0) {
        Prefs.pushSearchHistory(keyword.trim());
      }
    } catch (e) {
      this.error = `${e}`;
    } finally {
      this.loading = false;
    }
  }

  copyMagnet(magnet: string): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, magnet);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: '磁力已复制,可粘贴到下载器(如 qBittorrent)' });
    }).catch(() => {
      promptAction.showToast({ message: '复制失败' });
    });
  }

  @Builder
  resourceRow(item: GardenResource) {
    Column({ space: 6 }) {
      Text(item.title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Row({ space: 8 }) {
        if (item.fansub.length > 0) {
          Text(item.fansub)
            .fontSize(11)
            .fontColor('#3471D5')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('#EAF1FB')
            .borderRadius(4)
        }
        Text(item.type)
          .fontSize(11)
          .fontColor('#666666')
        if (item.size > 0) {
          Text(formatSize(item.size))
            .fontSize(11)
            .fontColor('#999999')
        }
        Blank()
        Text(item.createdAt.substring(0, 10))
          .fontSize(11)
          .fontColor('#999999')
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Color.White)
    .borderRadius(10)
    .onClick(() => {
      this.copyMagnet(item.magnet);
    })
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        TextInput({ placeholder: '搜索动漫资源,如:芙莉莲 简体内嵌', text: this.keyword })
          .onChange((v: string) => {
            this.keyword = v;
          })
          .onSubmit(() => {
            this.load(this.keyword, 1);
          })
          .layoutWeight(1)
          .backgroundColor(Color.White)
          .borderRadius(20)
        Button(this.loading ? '搜索中' : '搜索')
          .enabled(!this.loading)
          .borderRadius(20)
          .onClick(() => {
            this.load(this.keyword, 1);
          })
      }
      .width('100%')
      .padding(12)

      Text(this.searched ? '点击条目复制磁力链接' : '最新资源 · 点击条目复制磁力链接')
        .fontSize(12)
        .fontColor('#999999')
        .width('100%')
        .padding({ left: 16, bottom: 4 })

      if (this.error.length > 0 && this.items.length === 0) {
        Column({ space: 10 }) {
          Text(this.error)
            .fontSize(13)
            .fontColor('#CC3333')
          Button('重试')
            .onClick(() => {
              this.load(this.keyword, 1);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.items, (item: GardenResource) => {
            ListItem() {
              this.resourceRow(item)
            }
          }, (item: GardenResource) => `${item.provider}-${item.id}`)
          if (this.items.length > 0 && !this.loading) {
            ListItem() {
              Button('加载更多')
                .fontSize(14)
                .backgroundColor('#F0F0F0')
                .fontColor('#333333')
                .width('100%')
                .margin({ top: 4, bottom: 8 })
                .onClick(() => {
                  this.load(this.keyword, this.page + 1);
                })
            }
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12, bottom: 12 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
  }
}
