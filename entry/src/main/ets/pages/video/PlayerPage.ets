import { PlayerController, PlayerState } from '../../datasources/player/PlayerController';
import { Episode, PlayRoute } from '../../models/cms/MaccmsModels';
import { DatabaseHelper } from '../../db/DatabaseHelper';
import { WatchHistoryDao, WatchSnapshot } from '../../db/WatchHistoryDao';
import { VideoCache } from '../../datasources/video/VideoCache';
import { Nav } from '../../common/Nav';
import { PlayerNavParam } from '../../common/NavParams';
import { AppChrome } from '../../common/AppChrome';
import { promptAction } from '@kit.ArkUI';

const SPEED_OPTIONS: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

/** 全屏播放器:XComponent + AVPlayer;换线路同集续播、倍速、选集、历史 */
@ComponentV2
export struct PlayerPage {
  xController: XComponentController = new XComponentController();
  private player: PlayerController = new PlayerController();
  private routes: PlayRoute[] = [];
  private param: PlayerNavParam | null = null;
  private lastSaveMs: number = 0;
  private failedRoutes: Set<number> = new Set(); // 死链线路(5411007 等),自动重试时跳过
  @Local surfaceReady: boolean = false;
  @Local playing: boolean = false;
  @Local currentMs: number = 0;
  @Local durationMs: number = 0;
  @Local speed: number = 1.0;
  @Local routeIndex: number = 0;
  @Local episodeIndex: number = 0;
  @Local title: string = '';
  @Local error: string = '';
  @Local showEpisodes: boolean = false;
  @Local showRoutes: boolean = false;
  @Local showControls: boolean = true;
  @Local videoRatio: number = 0; // 宽/高;0 = 未知按 16:9
  @Local areaW: number = 0;
  @Local areaH: number = 0;
  @Local navBarH: number = 28;
  @Local isFull: boolean = false; // 横屏全屏
  @Local boosting: boolean = false; // 长按 3x 快进中
  private savedSpeed: number = 1.0;
  private controlsTimer: number = -1; // 控制条自动收起定时器
  @Local gestureHint: string = ''; // 手势操作中漂浮提示(进度/亮度/音量)
  @Local brightnessVal: number = -1; // -1 = 未调过;退出时据此决定是否恢复系统亮度
  @Local volumeVal: number = 1.0; // App 内音量(AVPlayer.setVolume)
  private seekBaseMs: number = 0;
  private seekTargetMs: number = 0;
  private brightBase: number = 0.5;
  private volBase: number = 1.0;
  private hintTimer: number = -1;

  async aboutToAppear(): Promise<void> {
    // 全屏媒体态:外壳背景切黑、撤掉安全区避让,上下露出的就是与播放区一致的纯黑
    AppChrome.setFullscreen(true);
    const params = Nav.stack.getParamByName('Player') as PlayerNavParam[];
    const p = params !== undefined && params.length > 0 ? params[params.length - 1] : undefined;
    if (p === undefined) {
      return;
    }
    this.param = p;
    await DatabaseHelper.init(getContext(this));
    try {
      this.routes = JSON.parse(p.routesJson) as PlayRoute[];
    } catch (e) {
      this.routes = [];
    }
    this.routeIndex = p.routeIndex;
    this.episodeIndex = p.episodeIndex;
    this.title = p.title;
    this.navBarH = AppChrome.nav;
    AppChrome.onChange(() => {
      this.navBarH = AppChrome.nav;
    });
    // 全屏沉浸:隐藏系统栏
    AppChrome.hideSystemBars(getContext(this));
    this.player.onVideoSize = (vw: number, vh: number) => {
      if (vw > 0 && vh > 0) {
        this.videoRatio = vw / vh;
      }
    };

    this.player.onState = (s: PlayerState) => {
      this.playing = s === 'playing';
      if (s === 'playing') {
        this.scheduleHideControls();
      } else {
        this.cancelHideControls();
        this.showControls = true; // 暂停/出错时控制条常驻
      }
      if (s === 'error') {
        this.error = '播放失败,试试切换线路';
      } else if (s === 'prepared') {
        this.error = '';
        if (p.resumePositionMs > 0) {
          this.player.seek(Math.max(0, p.resumePositionMs - 2000));
        }
      }
    };
    this.player.onTime = (currentMs: number, durationMs: number) => {
      this.currentMs = currentMs;
      this.durationMs = durationMs;
      // 每 5 秒保存一次观看进度
      if (currentMs - this.lastSaveMs > 5000) {
        this.lastSaveMs = currentMs;
        this.saveHistory(currentMs, durationMs, false);
      }
    };
    this.player.onError = (msg: string) => {
      // 5411007 = AVERR_IO_RESOURCE_NOT_FOUND(死链/防盗链):自动换线路重试
      const deadLink = msg.indexOf('5411007') >= 0 || msg.indexOf('resource not found') >= 0;
      if (deadLink) {
        this.failedRoutes.add(this.routeIndex);
        const next = this.nextLiveRoute();
        if (next >= 0) {
          promptAction.showToast({ message: `该线路资源失效,切换到「${this.routes[next].name}」` });
          this.switchTo(next, this.episodeIndex, 0);
          return;
        }
        this.error = '所有线路的资源都失效了(源可能挂了),请换一个源或稍后再试';
      } else {
        this.error = `${msg}(可尝试切换线路)`;
      }
    };
    // 定时收起控制条
  }

  currentEpisode(): Episode | null {
    const route = this.routes[this.routeIndex];
    if (route === undefined) {
      return null;
    }
    return route.episodes[this.episodeIndex] ?? null;
  }

  /** 播放中 3 秒无操作自动收起控制条 */
  scheduleHideControls(): void {
    this.cancelHideControls();
    if (!this.playing) {
      return;
    }
    this.controlsTimer = setTimeout(() => {
      this.controlsTimer = -1;
      this.showControls = false;
    }, 3000);
  }

  cancelHideControls(): void {
    if (this.controlsTimer >= 0) {
      clearTimeout(this.controlsTimer);
      this.controlsTimer = -1;
    }
  }

  /** 单击手势:隐藏→呼出并计时;显示→立即收起 */
  toggleControls(): void {
    if (this.showControls) {
      this.cancelHideControls();
      this.showControls = false;
    } else {
      this.showControls = true;
      this.scheduleHideControls();
    }
  }

  private showHint(text: string): void {
    this.gestureHint = text;
    if (this.hintTimer >= 0) {
      clearTimeout(this.hintTimer);
    }
    this.hintTimer = setTimeout(() => {
      this.hintTimer = -1;
      this.gestureHint = '';
    }, 500);
  }

  /** 横滑:整屏 = ±120s,拖动中只改预览,松手才 seek */
  onSeekPanStart(): void {
    this.cancelHideControls();
    this.seekBaseMs = this.currentMs;
    this.seekTargetMs = this.currentMs;
    this.gestureHint = this.formatMs(this.currentMs);
  }

  onSeekPanUpdate(offsetX: number): void {
    if (this.areaW <= 0 || this.durationMs <= 0) {
      return;
    }
    const deltaMs = offsetX / this.areaW * 120000;
    const target = Math.min(Math.max(this.seekBaseMs + deltaMs, 0), this.durationMs);
    this.seekTargetMs = target;
    const sign = target >= this.seekBaseMs ? '+' : '-';
    this.gestureHint = sign + Math.abs(Math.round((target - this.seekBaseMs) / 1000)) + 's → ' + this.formatMs(target);
  }

  onSeekPanEnd(): void {
    if (this.durationMs > 0) {
      this.player.seek(Math.floor(this.seekTargetMs));
    }
    this.showHint(this.formatMs(this.seekTargetMs));
    this.scheduleHideControls();
  }

  /** 左侧纵滑:亮度(0.05~1.0),立即生效 */
  onBrightPanStart(): void {
    this.cancelHideControls();
    this.brightBase = this.brightnessVal >= 0 ? this.brightnessVal : 0.5;
  }

  onBrightPanUpdate(offsetY: number): void {
    const span = this.areaH > 0 ? this.areaH * 0.7 : 500;
    const v = Math.min(Math.max(this.brightBase - offsetY / span, 0.05), 1.0);
    this.brightnessVal = v;
    AppChrome.setBrightness(getContext(this), v);
    this.gestureHint = '亮度 ' + Math.round(v * 100) + '%';
  }

  onBrightPanEnd(): void {
    this.showHint('亮度 ' + Math.round((this.brightnessVal >= 0 ? this.brightnessVal : 0.5) * 100) + '%');
    this.scheduleHideControls();
  }

  /** 右侧纵滑:App 内音量(0~1) */
  onVolPanStart(): void {
    this.cancelHideControls();
    this.volBase = this.volumeVal;
  }

  onVolPanUpdate(offsetY: number): void {
    const span = this.areaH > 0 ? this.areaH * 0.7 : 500;
    const v = Math.min(Math.max(this.volBase - offsetY / span, 0), 1);
    this.volumeVal = v;
    this.player.setVolume(v);
    this.gestureHint = '音量 ' + Math.round(v * 100) + '%';
  }

  onVolPanEnd(): void {
    this.showHint('音量 ' + Math.round(this.volumeVal * 100) + '%');
    this.scheduleHideControls();
  }

  startPlay(): void {
    const p = this.param;
    // 本地离线播放:经 LocalProxy 伪装 HLS(有时长/可拖/可倍速);换到已下载集继续本地
    if (p !== null && p.localPath.length > 0) {
      const surfaceId = this.xController.getXComponentSurfaceId();
      const key = `${p.sourceId}_${p.vodId}_e${p.episodeIndex}`;
      const durMs = VideoCache.estimateDurationMs(p.sourceId, p.vodId, p.episodeIndex);
      this.player.prepareLocal(key, p.localPath, durMs, surfaceId).catch((e: Object) => {
        this.error = `本地播放失败:${e}`;
      });
      return;
    }
    const ep = this.currentEpisode();
    if (ep === null) {
      this.error = '没有可播放的集数';
      return;
    }
    const surfaceId = this.xController.getXComponentSurfaceId();
    this.player.prepare(ep.url, surfaceId).catch((e: Object) => {
      this.error = `${e}`;
    });
  }

  /** 换线路/换集:换到已下载的集继续本地播,没下载的回在线 */
  switchTo(routeIndex: number, episodeIndex: number, resumeMs: number = 0): void {
    this.routeIndex = routeIndex;
    this.episodeIndex = episodeIndex;
    this.currentMs = 0;
    this.lastSaveMs = 0;
    this.error = '';
    if (this.param !== null) {
      const downloaded = VideoCache.isEpisodeDownloaded(this.param.sourceId, this.param.vodId, episodeIndex);
      this.param.localPath = downloaded
        ? VideoCache.episodeFile(this.param.sourceId, this.param.vodId, episodeIndex)
        : '';
    }
    this.startPlay();
  }

  /** 找下一条未失败的线路(有当前集) */
  nextLiveRoute(): number {
    for (let i = 0; i < this.routes.length; i++) {
      const idx = (this.routeIndex + 1 + i) % this.routes.length;
      if (this.failedRoutes.has(idx)) {
        continue;
      }
      const route = this.routes[idx];
      if (route !== undefined && this.episodeIndex < route.episodes.length) {
        return idx;
      }
    }
    return -1;
  }

  saveHistory(positionMs: number, durationMs: number, finished: boolean): void {
    const p = this.param;
    const ep = this.currentEpisode();
    const route = this.routes[this.routeIndex];
    if (p === null || ep === null || route === undefined) {
      return;
    }
    const snap: WatchSnapshot = {
      cmsSourceId: p.sourceId,
      vodId: p.vodId,
      title: p.title,
      cover: p.cover,
      routeIndex: routeIndexSafe(this.routeIndex),
      routeName: route.name,
      episodeIndex: this.episodeIndex,
      episodeName: ep.name,
      positionMs: positionMs,
      durationMs: durationMs,
      finished: finished
    };
    WatchHistoryDao.save(snap).catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.cancelHideControls();
    if (this.hintTimer >= 0) {
      clearTimeout(this.hintTimer);
    }
    if (this.brightnessVal >= 0) {
      AppChrome.setBrightness(getContext(this), -1); // 恢复跟随系统
    }
    this.saveHistory(this.currentMs, this.durationMs, false);
    this.player.release();
    // 退出全屏媒体态,外壳恢复灰底与安全区避让
    AppChrome.setFullscreen(false);
    // 恢复系统栏与竖屏
    AppChrome.showSystemBars(getContext(this));
    if (this.isFull) {
      AppChrome.landscape(getContext(this), true);
    }
  }

  toggleFull(): void {
    this.isFull = !this.isFull;
    AppChrome.landscape(getContext(this), !this.isFull);
  }

  seekDelta(sec: number): void {
    if (this.durationMs <= 0) {
      return;
    }
    const target = Math.min(Math.max(this.currentMs + sec * 1000, 0), this.durationMs);
    this.player.seek(target);
    promptAction.showToast({ message: sec > 0 ? `快进 ${sec}s` : `快退 ${Math.abs(sec)}s` });
  }

  startBoost(): void {
    if (this.boosting || this.playing === false) {
      return;
    }
    this.boosting = true;
    this.savedSpeed = this.speed;
    this.player.setSpeed(3.0);
    promptAction.showToast({ message: '3x 快进中,松开恢复' });
  }

  endBoost(): void {
    if (!this.boosting) {
      return;
    }
    this.boosting = false;
    this.player.setSpeed(this.savedSpeed);
  }

  @Builder
  controls() {
    Column({ space: 10 }) {
      Blank()
      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(13)
          .fontColor('#FF6B6B')
          .padding(8)
      }
      Row() {
        Text(this.formatMs(this.currentMs))
          .fontSize(12)
          .fontColor(Color.White)
        Slider({
          value: this.durationMs > 0 ? this.currentMs / this.durationMs * 100 : 0,
          min: 0,
          max: 100,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End && this.durationMs > 0) {
              this.player.seek(Math.floor(value / 100 * this.durationMs));
            }
          })
        Text(this.formatMs(this.durationMs))
          .fontSize(12)
          .fontColor(Color.White)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Row() {
        Button(this.playing ? '暂停' : '播放')
          .fontSize(14)
          .backgroundColor('#66000000')
          .onClick(() => {
            if (this.playing) {
              this.cancelHideControls();
              this.player.pause();
            } else {
              this.player.play();
              this.scheduleHideControls();
            }
          })
        Text(`倍速 ${this.speed}x`)
          .fontSize(13)
          .fontColor(Color.White)
          .padding(8)
          .onClick(() => {
            const idx = SPEED_OPTIONS.indexOf(this.speed);
            const next = SPEED_OPTIONS[(idx + 1) % SPEED_OPTIONS.length];
            this.speed = next;
            this.player.setSpeed(next);
          })
        Text('选集')
          .fontSize(13)
          .fontColor(Color.White)
          .padding(8)
          .onClick(() => {
            this.showEpisodes = true;
          })
        if (this.routes.length > 1) {
          Text(`线路:${this.routes[this.routeIndex]?.name ?? ''}`)
            .fontSize(13)
            .fontColor(Color.White)
            .padding(8)
            .maxLines(1)
            .constraintSize({ maxWidth: 140 })
            .onClick(() => {
              this.showRoutes = true;
            })
        }
        if (this.episodeIndex > 0) {
          Text('上一集')
            .fontSize(13)
            .fontColor(Color.White)
            .padding(8)
            .onClick(() => {
              this.saveHistory(0, 0, true);
              this.switchTo(this.routeIndex, this.episodeIndex - 1, 0);
            })
        }
        if (this.routes[this.routeIndex] !== undefined
          && this.episodeIndex < this.routes[this.routeIndex].episodes.length - 1) {
          Text('下一集')
            .fontSize(13)
            .fontColor(Color.White)
            .padding(8)
            .onClick(() => {
              this.saveHistory(0, 0, true);
              this.switchTo(this.routeIndex, this.episodeIndex + 1, 0);
            })
        }
        Text(this.isFull ? '退出全屏' : '全屏')
          .fontSize(13)
          .fontColor(Color.White)
          .padding(8)
          .onClick(() => {
            this.toggleFull();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
      .padding({ bottom: 10 + this.navBarH })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
    .onClick(() => {
      this.cancelHideControls();
      this.showControls = false;
    })
  }

  formatMs(ms: number): string {
    const total = Math.floor(ms / 1000);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const mm = h > 0 ? `${m}`.padStart(2, '0') : `${m}`;
    const ss = `${s}`.padStart(2, '0');
    return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
  }

  @Builder
  episodeSheetBody() {
    Column() {
      Text(`${this.title} · 选集`)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .padding(12)
      Scroll() {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.routes[this.routeIndex]?.episodes ?? [], (ep: Episode) => {
            Text(ep.name)
              .fontSize(13)
              .fontColor(ep.index === this.episodeIndex ? Color.White : '#444444')
              .backgroundColor(ep.index === this.episodeIndex ? '#3471D5' : '#F0F0F0')
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .borderRadius(8)
              .margin(4)
              .maxLines(1)
              .constraintSize({ maxWidth: 160 })
              .onClick(() => {
                this.showEpisodes = false;
                this.switchTo(this.routeIndex, ep.index, 0);
              })
          }, (ep: Episode) => `${ep.index}-${ep.name}`)
        }
        .padding(12)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White)
  }

  @Builder
  routeSheetBody() {
    Column() {
      Text('切换线路(保持当前集数)')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .padding(12)
      List() {
        ForEach(this.routes, (route: PlayRoute) => {
          ListItem() {
            Text(route.name)
              .fontSize(15)
              .fontColor(route.index === this.routeIndex ? '#3471D5' : '#444444')
              .padding(14)
              .width('100%')
              .onClick(() => {
                this.showRoutes = false;
                if (route.index !== this.routeIndex) {
                  this.switchTo(route.index, this.episodeIndex, 0);
                }
              })
          }
        }, (route: PlayRoute) => `${route.index}-${route.name}`)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White)
  }

  /** contain:视频按原始比例在容器内最大化(折叠屏近方屏不拉伸) */
  displayW(): number {
    const ratio = this.videoRatio > 0 ? this.videoRatio : 0;
    if (this.areaW <= 0 || this.areaH <= 0) {
      return 0;
    }
    if (ratio <= 0) {
      return this.areaW; // 未知比例暂按铺满宽
    }
    let w = this.areaW;
    let h = w / ratio;
    if (h > this.areaH) {
      h = this.areaH;
      w = h * ratio;
    }
    return w;
  }

  displayH(): number {
    const w = this.displayW();
    const ratio = this.videoRatio > 0 ? this.videoRatio : 16 / 9;
    return w > 0 ? w / ratio : 0;
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Center }) {
        XComponent({ type: XComponentType.SURFACE, controller: this.xController })
          .onLoad(() => {
            this.surfaceReady = true;
            this.startPlay();
          })
          .id('videoSurface')
          .width(this.displayW() > 0 ? this.displayW() : '100%')
          .height(this.displayH() > 0 ? this.displayH() : '100%')

        // 手势层:左 1/3 双击快退 / 中单击切控制条 / 右 1/3 双击快进;长按任意处 3x
        Row() {
          Column()
            .width('33%')
            .height('100%')
            .gesture(GestureGroup(GestureMode.Exclusive,
              TapGesture({ count: 2 }).onAction(() => {
                this.seekDelta(-10);
              }),
              TapGesture({ count: 1 }).onAction(() => {
                this.toggleControls();
              }),
              PanGesture({ direction: PanDirection.Horizontal, fingers: 1, distance: 12 })
                .onActionStart(() => {
                  this.onSeekPanStart();
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.onSeekPanUpdate(event.offsetX);
                })
                .onActionEnd(() => {
                  this.onSeekPanEnd();
                })
                .onActionCancel(() => {
                  this.onSeekPanEnd();
                }),
              PanGesture({ direction: PanDirection.Vertical, fingers: 1, distance: 12 })
                .onActionStart(() => {
                  this.onBrightPanStart();
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.onBrightPanUpdate(event.offsetY);
                })
                .onActionEnd(() => {
                  this.onBrightPanEnd();
                })
                .onActionCancel(() => {
                  this.onBrightPanEnd();
                })
            ))
          Column()
            .width('34%')
            .height('100%')
            .gesture(GestureGroup(GestureMode.Exclusive,
              TapGesture({ count: 1 }).onAction(() => {
                this.toggleControls();
              }),
              PanGesture({ direction: PanDirection.Horizontal, fingers: 1, distance: 12 })
                .onActionStart(() => {
                  this.onSeekPanStart();
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.onSeekPanUpdate(event.offsetX);
                })
                .onActionEnd(() => {
                  this.onSeekPanEnd();
                })
                .onActionCancel(() => {
                  this.onSeekPanEnd();
                })
            ))
          Column()
            .width('33%')
            .height('100%')
            .gesture(GestureGroup(GestureMode.Exclusive,
              TapGesture({ count: 2 }).onAction(() => {
                this.seekDelta(10);
              }),
              TapGesture({ count: 1 }).onAction(() => {
                this.toggleControls();
              }),
              PanGesture({ direction: PanDirection.Horizontal, fingers: 1, distance: 12 })
                .onActionStart(() => {
                  this.onSeekPanStart();
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.onSeekPanUpdate(event.offsetX);
                })
                .onActionEnd(() => {
                  this.onSeekPanEnd();
                })
                .onActionCancel(() => {
                  this.onSeekPanEnd();
                }),
              PanGesture({ direction: PanDirection.Vertical, fingers: 1, distance: 12 })
                .onActionStart(() => {
                  this.onVolPanStart();
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.onVolPanUpdate(event.offsetY);
                })
                .onActionEnd(() => {
                  this.onVolPanEnd();
                })
                .onActionCancel(() => {
                  this.onVolPanEnd();
                })
            ))
        }
        .width('100%')
        .height('100%')
        .gesture(LongPressGesture({ repeat: false })
          .onAction(() => {
            this.startBoost();
          })
          .onActionEnd(() => {
            this.endBoost();
          }))

        if (this.boosting) {
          Text('3x 快进中…')
            .fontSize(13)
            .fontColor('#FFD700')
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor('#88000000')
            .borderRadius(8)
        }

        if (this.gestureHint.length > 0) {
          Text(this.gestureHint)
            .fontSize(14)
            .fontColor(Color.White)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .backgroundColor('#AA000000')
            .borderRadius(18)
        }

        if (this.showControls) {
          this.controls()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      .onAreaChange((_o: Area, n: Area) => {
        this.areaW = Number(n.width);
        this.areaH = Number(n.height);
      })
      .bindSheet($$this.showEpisodes, this.episodeSheetBody(), {
        height: SheetSize.MEDIUM, showClose: true
      })
      .bindSheet($$this.showRoutes, this.routeSheetBody(), {
        height: SheetSize.MEDIUM, showClose: true
      })
    }
    .hideTitleBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onBackPressed(() => {
      return false;
    })
  }
}

function routeIndexSafe(i: number): number {
  return Math.max(0, i);
}

@Builder
export function playerPageBuilder() {
  PlayerPage()
}
