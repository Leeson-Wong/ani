import { PlayerController, PlayerState } from '../../datasources/player/PlayerController';
import { LiveChannel } from '../../models/live/LiveModels';
import { Nav } from '../../common/Nav';
import { LivePlayNavParam } from '../../common/NavParams';
import { AppChrome } from '../../common/AppChrome';
import { LiveSpeedTest } from '../../datasources/live/LiveSpeedTest';
import { promptAction } from '@kit.ArkUI';
import { Log } from '../../common/Logger';

interface DisplaySize {
  w: number;
  h: number;
}

/** 直播播放:视频按原始比例 contain 显示(折叠屏近方屏不拉伸),失败自动换线/换台 */
@ComponentV2
export struct LivePlayPage {
  xController: XComponentController = new XComponentController();
  private player: PlayerController = new PlayerController();
  private channels: LiveChannel[] = [];
  @Local index: number = 0;
  @Local urlIndex: number = 0;
  @Local playing: boolean = false;
  @Local error: string = '';
  @Local loading: boolean = true;
  @Local showChannelSheet: boolean = false;
  @Local showControls: boolean = true;
  @Local videoRatio: number = 0; // 宽/高;0 = 未知按 16:9
  @Local area: DisplaySize = { w: 0, h: 0 };
  @Local statusBarH: number = 44;
  @Local navBarH: number = 28;
  @Local isFull: boolean = false;
  @Local boosting: boolean = false;
  @Local speedTesting: boolean = false;

  aboutToAppear(): void {
    // 全屏媒体态:外壳背景切黑、撤掉安全区避让
    AppChrome.setFullscreen(true);
    this.statusBarH = AppChrome.status;
    this.navBarH = AppChrome.nav;
    AppChrome.onChange(() => {
      this.statusBarH = AppChrome.status;
      this.navBarH = AppChrome.nav;
    });
    AppChrome.hideSystemBars(getContext(this));
    const params = Nav.stack.getParamByName('LivePlay') as LivePlayNavParam[];
    const p = params !== undefined && params.length > 0 ? params[params.length - 1] : undefined;
    if (p === undefined) {
      return;
    }
    try {
      this.channels = JSON.parse(p.channelsJson) as LiveChannel[];
    } catch (e) {
      this.channels = [];
    }
    this.index = p.startIndex;
    this.player.onState = (s: PlayerState) => {
      this.playing = s === 'playing';
      this.loading = s === 'init' || s === 'prepared';
      if (s === 'playing') {
        this.error = '';
      } else if (s === 'error') {
        this.fallback();
      }
    };
    this.player.onVideoSize = (vw: number, vh: number) => {
      if (vw > 0 && vh > 0) {
        this.videoRatio = vw / vh;
      }
    };
    this.player.onError = (msg: string) => {
      Log.warn('live play error', msg);
      this.fallback();
    };
  }

  /** contain 计算:视频在容器内按比例最大化 */
  displaySize(): DisplaySize {
    const ratio = this.videoRatio > 0 ? this.videoRatio : 16 / 9;
    const aw = this.area.w;
    const ah = this.area.h;
    if (aw <= 0 || ah <= 0) {
      const d: DisplaySize = { w: 0, h: 0 };
      return d;
    }
    let w = aw;
    let h = w / ratio;
    if (h > ah) {
      h = ah;
      w = h * ratio;
    }
    const d: DisplaySize = { w: w, h: h };
    return d;
  }

  currentChannel(): LiveChannel | null {
    return this.channels[this.index] ?? null;
  }

  async startPlay(): Promise<void> {
    const ch = this.currentChannel();
    if (ch === null) {
      return;
    }
    // 多线路时先实测选速(进程内缓存,同台只测一次);死流(0 速率)不会入选
    if (ch.urls.length > 1) {
      this.speedTesting = true;
      const best = await LiveSpeedTest.pickFastest(ch.name, ch.urls);
      this.speedTesting = false;
      if (best >= 0 && best !== this.urlIndex) {
        Log.info('live pick line', ch.name, `#${best}`);
        this.urlIndex = best;
      }
    }
    const url = ch.urls[this.urlIndex];
    if (url === undefined) {
      return;
    }
    this.videoRatio = 0;
    this.loading = true;
    this.error = '';
    this.player.prepare(url, this.xController.getXComponentSurfaceId()).catch((e: Object) => {
      this.error = `${e}`;
    });
  }

  /** 播放失败:先换本频道的下一条线路,线路用完换下一个台 */
  fallbackCount: number = 0;

  fallback(): void {
    const ch = this.currentChannel();
    if (ch === null) {
      return;
    }
    this.fallbackCount++;
    if (this.fallbackCount > 6) {
      this.error = '连续失败,该台暂时不可播';
      this.fallbackCount = 0;
      return;
    }
    if (this.urlIndex < ch.urls.length - 1) {
      this.urlIndex++;
      promptAction.showToast({ message: '换线路重试' });
      this.startPlay();
    } else if (this.index < this.channels.length - 1) {
      this.urlIndex = 0;
      this.index++;
      promptAction.showToast({ message: `跳到:${this.currentChannel()?.name ?? ''}` });
      this.startPlay();
    } else {
      this.error = '没有可用的频道了';
    }
  }

  switchChannel(delta: number): void {
    const next = this.index + delta;
    if (next < 0 || next >= this.channels.length) {
      return;
    }
    this.index = next;
    this.urlIndex = 0;
    this.fallbackCount = 0;
    this.startPlay();
  }

  aboutToDisappear(): void {
    this.player.release();
    AppChrome.setFullscreen(false);
    AppChrome.showSystemBars(getContext(this));
    if (this.isFull) {
      AppChrome.landscape(getContext(this), true);
    }
  }

  toggleFull(): void {
    this.isFull = !this.isFull;
    AppChrome.landscape(getContext(this), !this.isFull);
  }

  @Builder
  controls() {
    Column() {
      Blank()
      Text(this.currentChannel()?.name ?? '')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .padding(8)
      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(13)
          .fontColor('#FF9A9A')
          .padding(6)
      }
      Row() {
        Button('上一台')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor('#66000000')
          .fontColor(Color.White)
          .enabled(this.index > 0)
          .onClick(() => {
            this.switchChannel(-1);
          })
        Button(this.playing ? '暂停' : this.loading ? '加载中' : '播放')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor('#66000000')
          .fontColor(Color.White)
          .onClick(() => {
            if (this.playing) {
              this.player.pause();
            } else {
              this.player.play();
            }
          })
        Button('换线路')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor('#66000000')
          .fontColor(Color.White)
          .onClick(() => {
            const ch = this.currentChannel();
            if (ch !== null && ch.urls.length > 1) {
              this.urlIndex = (this.urlIndex + 1) % ch.urls.length;
              this.startPlay();
            } else {
              promptAction.showToast({ message: '该台只有一条线路' });
            }
          })
        Button('频道')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor('#66000000')
          .fontColor(Color.White)
          .onClick(() => {
            this.showChannelSheet = true;
          })
        Button('下一台')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor('#66000000')
          .fontColor(Color.White)
          .enabled(this.index < this.channels.length - 1)
          .onClick(() => {
            this.switchChannel(1);
          })
        Button(this.isFull ? '退出' : '全屏')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor('#66000000')
          .fontColor(Color.White)
          .onClick(() => {
            this.toggleFull();
          })
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 + this.navBarH })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
    .onClick(() => {
      this.showControls = false;
    })
  }

  @Builder
  channelSheet() {
    List() {
      ForEach(this.channels, (ch: LiveChannel, i: number) => {
        ListItem() {
          Text(ch.name)
            .fontSize(14)
            .fontColor(i === this.index ? '#E8503A' : '#444444')
            .padding({ top: 10, bottom: 10 })
            .width('100%')
            .onClick(() => {
              this.showChannelSheet = false;
              this.index = i;
              this.urlIndex = 0;
              this.fallbackCount = 0;
              this.startPlay();
            })
        }
      }, (ch: LiveChannel) => ch.name)
    }
    .width('100%')
    .height('100%')
    .divider({ strokeWidth: 0.5, color: '#11000000' })
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Center }) {
        // 视频面:按原始比例 contain 居中(X7 内屏等近方屏不拉伸变形)
        XComponent({ type: XComponentType.SURFACE, controller: this.xController })
          .onLoad(() => {
            this.startPlay();
          })
          .id('liveSurface')
          .width(this.displaySize().w > 0 ? this.displaySize().w : '100%')
          .height(this.displaySize().h > 0 ? this.displaySize().h : '100%')

        Column()
          .width('100%')
          .height('100%')
          .onClick(() => {
            this.showControls = !this.showControls;
          })
          .gesture(LongPressGesture({ repeat: false })
            .onAction(() => {
              // 直播流变速部分源支持,不支持则无效果
              if (!this.boosting && this.playing) {
                this.boosting = true;
                this.player.setSpeed(3.0);
                promptAction.showToast({ message: '3x 播放中(若源不支持则无效),松开恢复' });
              }
            })
            .onActionEnd(() => {
              if (this.boosting) {
                this.boosting = false;
                this.player.setSpeed(1.0);
              }
            }))

        if (this.loading || this.speedTesting) {
          Column({ space: 8 }) {
            LoadingProgress().width(32).height(32)
            Text(this.speedTesting ? '线路测速中…' : '直播加载中…')
              .fontSize(13)
              .fontColor('#FFFFFF')
          }
          .padding(14)
          .backgroundColor('#88000000')
          .borderRadius(10)
        }

        if (this.showControls) {
          this.controls()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      .onAreaChange((_o: Area, n: Area) => {
        this.area = { w: Number(n.width), h: Number(n.height) };
      })
      .bindSheet($$this.showChannelSheet, this.channelSheet(), {
        height: SheetSize.MEDIUM,
        showClose: true,
        title: { title: '频道列表' }
      })
    }
    .hideTitleBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

@Builder
export function livePlayBuilder() {
  LivePlayPage()
}
