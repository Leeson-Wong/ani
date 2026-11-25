import { WatchHistoryDao } from '../../db/WatchHistoryDao';
import { WatchHistoryRow } from '../../db/DatabaseHelper';
import { DatabaseHelper } from '../../db/DatabaseHelper';
import { Nav } from '../../common/Nav';
import { VideoDetailNavParam } from '../../common/NavParams';
import { promptAction } from '@kit.ArkUI';

/** 观看历史:续播入口 + 长按删除 */
@ComponentV2
export struct HistoryPage {
  @Local rows: WatchHistoryRow[] = [];
  @Local ready: boolean = false;

  async aboutToAppear(): Promise<void> {
    await DatabaseHelper.init(getContext(this));
    this.rows = await WatchHistoryDao.listRecent();
    this.ready = true;
  }

  refresh(): void {
    WatchHistoryDao.listRecent().then((rows: WatchHistoryRow[]) => {
      this.rows = rows;
    });
  }

  open(row: WatchHistoryRow): void {
    const params: VideoDetailNavParam = {
      sourceId: row.cmsSourceId,
      vodId: row.vodId,
      title: row.title,
      cover: row.cover,
      remarks: ''
    };
    Nav.stack.pushPathByName('VideoDetail', params, (popInfo: PopInfo) => {
      this.refresh();
    });
  }

  @Builder
  historyRow(row: WatchHistoryRow) {
    Row({ space: 12 }) {
      Image(row.cover)
        .width(100)
        .height(66)
        .borderRadius(8)
        .objectFit(ImageFit.Cover)
        .alt($r('app.media.startIcon'))
      Column({ space: 4 }) {
        Text(row.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`看到:${row.episodeName}(${row.routeName})`)
          .fontSize(12)
          .fontColor('#999999')
        if (row.durationMs > 0) {
          Progress({
            value: Math.min(100, Math.floor(row.positionMs / row.durationMs * 100)),
            total: 100
          })
            .width('100%')
            .height(4)
            .color('#3471D5')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Color.White)
    .borderRadius(10)
    .onClick(() => {
      this.open(row);
    })
    .gesture(LongPressGesture()
      .onAction(() => {
        promptAction.showDialog({
          title: '删除记录',
          message: `删除「${row.title}」的观看记录?`,
          buttons: [
            { text: '取消', color: '#666666' },
            { text: '删除', color: '#CC3333' }
          ]
        }).then((result) => {
          if (result.index === 1) {
            WatchHistoryDao.remove(row.cmsSourceId, row.vodId).then(() => {
              this.rows = this.rows.filter((r: WatchHistoryRow) => r.id !== row.id);
            });
          }
        });
      }))
  }

  build() {
    NavDestination() {
      if (this.ready && this.rows.length === 0) {
        Column() {
          Text('暂无观看记录')
            .fontSize(15)
            .fontColor('#999999')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.rows, (row: WatchHistoryRow) => {
            ListItem() {
              this.historyRow(row)
            }
          }, (row: WatchHistoryRow) => `${row.id}-${row.updatedAt}`)
        }
        .width('100%')
        .height('100%')
        .padding(12)
        .scrollBar(BarState.Off)
      }
    }
    .title('观看历史')
    .backgroundColor('#F1F3F5')
  }
}

@Builder
export function historyPageBuilder() {
  HistoryPage()
}
