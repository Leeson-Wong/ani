import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { wantAgent, bundleManager, Context } from '@kit.AbilityKit';
import { Log } from './Logger';

/**
 * 后台下载长时任务:下载进行期间申请 MODE_DATA_TRANSFER 连续任务,退后台不被冻结;
 * 队列空闲即释放。申请/保活失败一律静默降级(只影响退后台存活,前台下载不受影响)。
 * DATA_TRANSFER 若 10 分钟无进度更新会被系统取消 → 每 4 分钟 update 一次保活;
 * 我们的下载进度本身持续变化,保活只是兜底。
 */
export class TransferScheduler {
  private static ctx: Context | null = null;
  private static taskId: number = -1;
  private static refs: number = 0;
  private static starting: boolean = false;
  private static keepAlive: number = -1;

  /** EntryAbility 启动时调用一次 */
  static init(context: Context): void {
    TransferScheduler.ctx = context;
  }

  /** 下载开动时引用 +1;首个引用触发申请(幂等,重复 retain 只计数) */
  static retain(): void {
    TransferScheduler.refs++;
    if (TransferScheduler.taskId >= 0 || TransferScheduler.starting) {
      return;
    }
    const ctx = TransferScheduler.ctx;
    if (ctx === null) {
      return; // init 未调用(理论不会发生):降级为仅前台下载
    }
    TransferScheduler.starting = true;
    TransferScheduler.start().then(() => {
    }).catch(() => {
    });
  }

  /** 下载收尾引用 -1;归零即释放连续任务与保活定时器 */
  static release(): void {
    TransferScheduler.refs = Math.max(0, TransferScheduler.refs - 1);
    if (TransferScheduler.refs > 0 || TransferScheduler.taskId < 0) {
      return;
    }
    const id = TransferScheduler.taskId;
    TransferScheduler.taskId = -1;
    if (TransferScheduler.keepAlive >= 0) {
      clearInterval(TransferScheduler.keepAlive);
      TransferScheduler.keepAlive = -1;
    }
    const ctx = TransferScheduler.ctx;
    if (ctx !== null) {
      backgroundTaskManager.stopBackgroundRunning(ctx, id).then(() => {
        Log.info('continuous task stopped', `${id}`);
      }).catch((e: Object) => {
        Log.warn('continuous task stop failed', `${e}`);
      });
    }
  }

  static active(): boolean {
    return TransferScheduler.taskId >= 0;
  }

  private static async start(): Promise<void> {
    const ctx = TransferScheduler.ctx;
    if (ctx === null) {
      return;
    }
    try {
      const pkg = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const info: wantAgent.WantAgentInfo = {
        // 本 SDK 的 BundleInfo 用 name 表示包名(即 app.json5 的 bundleName)
        wants: [{ bundleName: pkg.name, abilityName: 'EntryAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      const req = new backgroundTaskManager.ContinuousTaskRequest();
      req.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
      req.wantAgent = agent;
      const notif = await backgroundTaskManager.startBackgroundRunning(ctx, req);
      TransferScheduler.taskId = notif.continuousTaskId ?? -1;
      Log.info('continuous task started', `${TransferScheduler.taskId}`);
      if (TransferScheduler.keepAlive >= 0) {
        clearInterval(TransferScheduler.keepAlive);
      }
      TransferScheduler.keepAlive = setInterval(() => {
        TransferScheduler.touch();
      }, 240000);
    } finally {
      TransferScheduler.starting = false;
    }
  }

  /** 保活:重新 update 一次任务(失败静默;若系统已回收,下次 retain 会重新申请) */
  private static touch(): void {
    if (TransferScheduler.refs === 0 || TransferScheduler.taskId < 0) {
      return;
    }
    const ctx = TransferScheduler.ctx;
    if (ctx === null) {
      return;
    }
    const req = new backgroundTaskManager.ContinuousTaskRequest();
    req.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
    req.continuousTaskId = TransferScheduler.taskId;
    backgroundTaskManager.updateBackgroundRunning(ctx, req).then(() => {
    }).catch((e: Object) => {
      Log.warn('continuous task update failed', `${e}`);
    });
  }
}
