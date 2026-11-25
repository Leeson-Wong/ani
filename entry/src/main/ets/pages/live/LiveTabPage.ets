import { promptAction } from '@kit.ArkUI';
import { LiveClient } from '../../datasources/live/LiveClient';
import { DatabaseHelper } from '../../db/DatabaseHelper';
import { Nav } from '../../common/Nav';
import { LiveChannel, LivePlaylist } from '../../models/live/LiveModels';
import { LiveStore } from './LiveStore';
import { LivePlayNavParam } from '../../common/NavParams';

/** 直播 tab:分组 chips + 频道列表(iptv-org 高清优先聚合) */
@ComponentV2
export struct LiveTabPage {
  @Local playlist: LivePlaylist | null = null;
  @Local loading: boolean = true;
  @Local error: string = '';
  @Local groupIndex: number = 0;
  @Local keyword: string = '';

  async aboutToAppear(): Promise<void> {
    await DatabaseHelper.init(getContext(this));
    if (LiveStore.playlist !== null) {
      this.playlist = LiveStore.playlist;
      this.loading = false;
      return;
    }
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.error = '';
    try {
      const pl = await LiveClient.playlist();
      LiveStore.playlist = pl;
      this.playlist = pl;
    } catch (e) {
      this.error = `${e}`;
    } finally {
      this.loading = false;
    }
  }

  filteredChannels(): LiveChannel[] {
    const pl = this.playlist;
    if (pl === null) {
      return [];
    }
    const group = pl.groups[this.groupIndex] ?? '全部';
    const kw = this.keyword.trim().toUpperCase();
    const out: LiveChannel[] = [];
    for (const ch of pl.channels) {
      if (this.groupIndex > 0 && ch.group !== group) {
        continue;
      }
      if (kw.length > 0 && ch.name.toUpperCase().indexOf(kw) < 0) {
        continue;
      }
      out.push(ch);
    }
    return out;
  }

  playChannel(index: number): void {
    const channels = this.filteredChannels();
    const ch = channels[index];
    if (ch === undefined) {
      return;
    }
    const params: LivePlayNavParam = {
      channelsJson: JSON.stringify(channels),
      startIndex: index
    };
    Nav.stack.pushPathByName('LivePlay', params);
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        TextInput({ placeholder: '搜频道,如 CCTV / 卫视', text: this.keyword })
          .onChange((v: string) => {
            this.keyword = v;
          })
          .layoutWeight(1)
          .backgroundColor(Color.White)
          .borderRadius(20)
        if (this.playlist !== null) {
          Text(`${this.playlist.channels.length} 台`)
            .fontSize(12)
            .fontColor('#999999')
            .padding({ right: 12 })
        }
      }
      .width('100%')
      .padding(12)

      if (this.loading) {
        Column({ space: 8 }) {
          LoadingProgress().width(36).height(36)
          Text('加载直播源中…')
            .fontSize(13)
            .fontColor('#999999')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column({ space: 10 }) {
          Text(this.error)
            .fontSize(13)
            .fontColor('#CC3333')
            .padding(16)
          Button('重试')
            .onClick(() => {
              this.load();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.playlist !== null) {
        // 分组 chips
        Scroll() {
          Row({ space: 8 }) {
            Text('全部')
              .fontSize(13)
              .fontColor(this.groupIndex === 0 ? Color.White : '#444444')
              .backgroundColor(this.groupIndex === 0 ? '#E8503A' : Color.White)
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .borderRadius(14)
              .onClick(() => {
                this.groupIndex = 0;
              })
            ForEach(this.playlist.groups, (g: string, index: number) => {
              Text(g)
                .fontSize(13)
                .fontColor(this.groupIndex === index + 1 ? Color.White : '#444444')
                .backgroundColor(this.groupIndex === index + 1 ? '#E8503A' : Color.White)
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .borderRadius(14)
                .onClick(() => {
                  this.groupIndex = index + 1;
                })
            }, (g: string) => g)
          }
          .padding({ left: 12, right: 12 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .padding({ bottom: 8 })
        .backgroundColor('#F1F3F5')

        List({ space: 0 }) {
          ForEach(this.filteredChannels(), (ch: LiveChannel, index: number) => {
            ListItem() {
              Row({ space: 10 }) {
                Column({ space: 2 }) {
                  Text(ch.name)
                    .fontSize(15)
                  Text(`${ch.group} · ${ch.urls.length} 条线路`)
                    .fontSize(11)
                    .fontColor('#999999')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text('播')
                  .fontSize(13)
                  .fontColor(Color.White)
                  .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                  .backgroundColor('#E8503A')
                  .borderRadius(12)
              }
              .width('100%')
              .padding(12)
              .backgroundColor(Color.White)
              .onClick(() => {
                this.playChannel(index);
              })
            }
          }, (ch: LiveChannel) => `${ch.name}-${this.groupIndex}-${this.keyword}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.5, color: '#11000000' })
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
  }
}
