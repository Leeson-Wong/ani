import { Nav } from '../common/Nav';
import { AppChrome } from '../common/AppChrome';
import { MangaTabPage } from './manga/MangaTabPage';
import { VideoTabPage } from './video/VideoTabPage';
import { LiveTabPage } from './live/LiveTabPage';
import { GardenRadarPage } from './garden/GardenRadarPage';
import { SettingsPage } from './settings/SettingsPage';

@Entry
@ComponentV2
struct Index {
  @Local currentTab: number = 0;
  @Local statusBarH: number = 44;
  @Local navBarH: number = 28;
  @Local fullscreen: boolean = false;
  private fsCb: (v: boolean) => void = () => {};
  private chromeCb: (() => void) | null = null;

  async aboutToAppear(): Promise<void> {
    // 首屏真正出现时再隐藏一次状态栏(冷启动时 init/loadContent 阶段的设置可能被覆盖)
    await AppChrome.hideStatusBar(getContext(this));
    this.statusBarH = AppChrome.status;
    this.navBarH = AppChrome.nav;
    this.fsCb = (v: boolean) => {
      this.fullscreen = v;
    };
    this.fullscreen = AppChrome.isFullscreen;
    // 折叠屏展开/旋转时重算避让
    this.chromeCb = () => {
      this.statusBarH = AppChrome.status;
      this.navBarH = AppChrome.nav;
    };
    AppChrome.onChange(this.chromeCb);
    // 全屏页(阅读器)进入时撤掉外壳避让,退出后恢复
    AppChrome.onFullscreenChange(this.fsCb);
  }

  aboutToDisappear(): void {
    if (this.chromeCb !== null) {
      AppChrome.offChange(this.chromeCb);
    }
    AppChrome.offFullscreenChange(this.fsCb);
  }

  build() {
    Column() {
      Navigation(Nav.stack) {
        Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
          TabContent() {
            MangaTabPage()
          }
          .tabBar('漫画')

          TabContent() {
            VideoTabPage()
          }
          .tabBar('影视')

          TabContent() {
            LiveTabPage()
          }
          .tabBar('直播')

          TabContent() {
            GardenRadarPage()
          }
          .tabBar('雷达')

          TabContent() {
            SettingsPage()
          }
          .tabBar('我的')
        }
        .scrollable(false)
        .barMode(BarMode.Fixed)
        .onChange((index: number) => {
          this.currentTab = index;
        })
      }
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    // 全屏媒体页(阅读器/播放器/直播)外壳纯黑,与内容区一致;普通页灰底
    .backgroundColor(this.fullscreen ? '#000000' : '#F1F3F5')
    // 沉浸式:背景延伸进状态栏/导航条,内容区用避让内边距;全屏页撤掉避让
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .padding({
      top: this.fullscreen ? 0 : this.statusBarH,
      bottom: this.fullscreen ? 0 : this.navBarH
    })
  }
}
