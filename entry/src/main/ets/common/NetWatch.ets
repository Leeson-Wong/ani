import { connection } from '@kit.NetworkKit';

/** 全局网络状态单例:页面/服务读 NetWatch.get().online 建立依赖,断网即时感知 */
@ObservedV2
export class NetWatch {
  private static inst: NetWatch | null = null;

  /** 默认按在线处理;register 完成后以真实状态刷新 */
  @Trace online: boolean = true;
  /** 当前默认网络是否为非蜂窝(Wi-Fi/以太网);「仅 Wi-Fi 下载」用它判断 */
  @Trace wifi: boolean = true;
  private started: boolean = false;
  private listeners: (() => void)[] = [];

  static get(): NetWatch {
    if (NetWatch.inst === null) {
      NetWatch.inst = new NetWatch();
    }
    return NetWatch.inst;
  }

  /** EntryAbility 启动时调用一次;重复调用幂等 */
  static start(context: Context): void {
    const w = NetWatch.get();
    if (w.started) {
      return;
    }
    w.started = true;
    const cm = connection.createNetConnection();
    // 查询默认网络是否存在 + 是否 Wi-Fi(netLost 在 Wi-Fi/蜂窝切换时也会对旧网络触发,不能只信它)
    const probe = (): void => {
      connection.hasDefaultNet().then((has: boolean) => {
        w.online = has;
        w.refreshWifi();
        w.fire();
      }).catch((_e: Object) => {
        w.online = false;
        w.fire();
      });
    };
    cm.on('netAvailable', () => {
      w.online = true;
      w.refreshWifi();
      w.fire();
    });
    cm.on('netLost', probe);
    cm.register(probe);
  }

  /** 默认网络的承载类型里有没有 Wi-Fi(没有即视为蜂窝/未知,按非 Wi-Fi 处理) */
  private refreshWifi(): void {
    connection.getDefaultNet().then((net: connection.NetHandle) => {
      return connection.getNetCapabilities(net);
    }).then((cap: connection.NetCapabilities) => {
      this.wifi = cap.bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) >= 0
        || cap.bearerTypes.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0;
    }).catch((_e: Object) => {
      this.wifi = false;
    });
  }

  /** 网络状态变化回调(下载队列据此恢复「等待网络」的任务) */
  static onChange(cb: () => void): void {
    NetWatch.get().listeners.push(cb);
  }

  static offChange(cb: () => void): void {
    const w = NetWatch.get();
    const i = w.listeners.indexOf(cb);
    if (i >= 0) {
      w.listeners.splice(i, 1);
    }
  }

  private fire(): void {
    for (const cb of this.listeners) {
      cb();
    }
  }
}
