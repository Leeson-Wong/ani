import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { DatabaseHelper } from '../db/DatabaseHelper';
import { Prefs } from '../db/Prefs';
import { AppChrome } from '../common/AppChrome';
import { NetWatch } from '../common/NetWatch';
import { TransferScheduler } from '../common/TransferScheduler';
import { MangaCache } from '../datasources/manga/MangaCache';
import { DownloadManager } from '../datasources/manga/DownloadManager';
import { VideoCache } from '../datasources/video/VideoCache';
import { VideoDownloadManager } from '../datasources/video/VideoDownloadManager';
import { SourceHealth } from '../datasources/cms/SourceHealth';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 全局网络状态监听 + 后台下载长时任务的上下文
    NetWatch.start(this.context);
    TransferScheduler.init(this.context);
    // 预热:数据库 + 偏好
    DatabaseHelper.init(this.context).catch((e: Object) => {
      hilog.error(DOMAIN, 'AniApp', 'db init failed: %{public}s', `${e}`);
    });
    Prefs.init(this.context).then(() => {
      // 偏好就绪后恢复下载队列:已下的秒过,未完成的续传,暂停的保持暂停
      MangaCache.init(this.context);
      VideoCache.init(this.context);
      DownloadManager.restore();
      VideoDownloadManager.restore();
    }).catch((e: Object) => {
      hilog.error(DOMAIN, 'AniApp', 'prefs init failed: %{public}s', `${e}`);
    });
    // 源健康:每日一次后台探测复活被自动停用的影视源(两个 init 都幂等)
    Promise.all([DatabaseHelper.init(this.context), Prefs.init(this.context)]).then(() => {
      SourceHealth.maybeDailyRevive();
    }).catch((e: Object) => {
      hilog.warn(DOMAIN, 'AniApp', 'source revive bootstrap failed: %{public}s', `${e}`);
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    // 沉浸式 + 全局隐藏状态栏:完成后再加载首屏,避免首帧闪出时间/电量
    // init 内部已吞掉异常并总能 resolve,loadContent 一定会被调用
    AppChrome.init(this.context).then(() => {
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        // 首屏就绪后再隐藏一次:冷启动时 init 阶段的设置会被页面加载覆盖,此时才稳定生效
        AppChrome.hideStatusBar(this.context);
        hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      });
    }).catch((e: Object) => {
      hilog.warn(DOMAIN, 'AniApp', 'immersive init failed: %{public}s', `${e}`);
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        AppChrome.hideStatusBar(this.context);
      });
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
