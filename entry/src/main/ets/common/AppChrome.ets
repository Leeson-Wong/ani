import { window } from '@kit.ArkUI';
import { Context } from '@kit.AbilityKit';

/** 系统栏避让尺寸(沉浸式);折叠屏展开/旋转时自动更新 */
export class AppChrome {
  private static statusBarH: number = 44;
  private static navBarH: number = 28;
  private static listeners: (() => void)[] = [];
  private static fullscreen: boolean = false;
  private static fsListeners: ((v: boolean) => void)[] = [];

  static get status(): number {
    return AppChrome.statusBarH;
  }

  static get nav(): number {
    return AppChrome.navBarH;
  }

  /** 当前是否处于全屏页面(阅读器等):外壳需据此撤掉安全区避让 */
  static get isFullscreen(): boolean {
    return AppChrome.fullscreen;
  }

  static onFullscreenChange(cb: (v: boolean) => void): void {
    AppChrome.fsListeners.push(cb);
  }

  static offFullscreenChange(cb: (v: boolean) => void): void {
    const i = AppChrome.fsListeners.indexOf(cb);
    if (i >= 0) {
      AppChrome.fsListeners.splice(i, 1);
    }
  }

  static setFullscreen(v: boolean): void {
    if (AppChrome.fullscreen === v) {
      return;
    }
    AppChrome.fullscreen = v;
    for (const cb of AppChrome.fsListeners) {
      cb(v);
    }
  }

  static onChange(cb: () => void): void {
    AppChrome.listeners.push(cb);
  }

  static offChange(cb: () => void): void {
    const i = AppChrome.listeners.indexOf(cb);
    if (i >= 0) {
      AppChrome.listeners.splice(i, 1);
    }
  }

  /** 开沉浸式 + 量避让区;在 onWindowStageCreate 里调用 */
  static async init(context: Context): Promise<void> {
    try {
      const win = await window.getLastWindow(context);
      await win.setWindowLayoutFullScreen(true);
      // 窗口底色与核心区背景一致:状态栏隐藏后,上下安全区露出的窗口底色不再与内容割裂
      await win.setWindowBackgroundColor('#F1F3F5');
      // 系统栏透明底 + 深色内容(浅色主页清晰;显示时也不挡内容)
      await win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: '#FF000000',
        navigationBarColor: '#00000000',
        navigationBarContentColor: '#FF000000'
      });
      // 全局隐藏顶部状态栏(时间/电量/信号),底部导航手势条保留;
      // 非全屏页的安全区 padding 由 Index 照旧避让,只是看不到状态栏内容
      await win.setWindowSystemBarEnable(['navigation']);
      AppChrome.measure(win);
      win.on('avoidAreaChange', () => {
        AppChrome.measure(win);
        for (const cb of AppChrome.listeners) {
          cb();
        }
      });
    } catch (e) {
      // 沉浸式失败时退回保守默认值,不影响使用
    }
  }

  private static measure(win: window.Window): void {
    try {
      // 刘海/挖孔在部分机型上记在 TYPE_CUTOUT 而不是 TYPE_SYSTEM,取两者较大值
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cut = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const topPx = Math.max(sys.topRect.height, cut.topRect.height);
      AppChrome.statusBarH = px2vp(topPx) || 44;
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const bottomPx = Math.max(nav.bottomRect.height, sys.bottomRect.height);
      AppChrome.navBarH = px2vp(bottomPx) || 28;
    } catch (e) {
      // keep defaults
    }
  }

  /** 仅隐藏顶部状态栏(时间/电量),保留底部导航/手势条;幂等,供首屏加载完成后调用 */
  static async hideStatusBar(context: Context): Promise<void> {
    try {
      const win = await window.getLastWindow(context);
      await win.setWindowSystemBarEnable(['navigation']);
    } catch (e) {
      // 忽略
    }
  }

  /** 进入全屏媒体页:隐藏状态栏、导航栏与底部手势条。
   *  手势条(navigationIndicator)必须用 setSpecificSystemBarEnabled 单独关,
   *  setWindowSystemBarEnable([]) 管不到它 —— 这正是播放页底部白条的来源。
   */
  static async hideSystemBars(context: Context): Promise<void> {
    try {
      const win = await window.getLastWindow(context);
      await win.setWindowSystemBarEnable([]);
      await win.setSpecificSystemBarEnabled('navigationIndicator', false);
      // 窗口底色同步置黑:隐藏系统栏后,上下安全区露出的底色与黑色播放/阅读区一致
      await win.setWindowBackgroundColor('#000000');
    } catch (e) {
      // 忽略:部分设备不支持
    }
  }

  /** 离开全屏媒体页:恢复手势条,但顶部状态栏保持全局隐藏 */
  static async showSystemBars(context: Context): Promise<void> {
    try {
      const win = await window.getLastWindow(context);
      await win.setWindowSystemBarEnable(['navigation']);
      await win.setSpecificSystemBarEnabled('navigationIndicator', true);
      // 窗口底色恢复浅色:回到普通页面后安全区与核心区 #F1F3F5 一致
      await win.setWindowBackgroundColor('#F1F3F5');
    } catch (e) {
      // 忽略
    }
  }

  /** 横屏(全屏按钮);restore=true 恢复竖屏 */
  static async landscape(context: Context, restore: boolean): Promise<void> {
    try {
      const win = await window.getLastWindow(context);
      await win.setPreferredOrientation(restore
        ? window.Orientation.PORTRAIT
        : window.Orientation.AUTO_ROTATION_LANDSCAPE);
    } catch (e) {
      // 忽略
    }
  }

  /** 播放器手势调亮度(0~1);restore=true 传 -1 恢复跟随系统 */
  static async setBrightness(context: Context, v: number): Promise<void> {
    try {
      const win = await window.getLastWindow(context);
      await win.setWindowBrightness(v);
    } catch (e) {
      // 忽略:部分设备不支持
    }
  }
}
