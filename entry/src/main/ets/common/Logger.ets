import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0A01;
const TAG = 'AniApp';

export class Log {
  static debug(msg: string, ...args: string[]): void {
    hilog.debug(DOMAIN, TAG, '%{public}s', args.length > 0 ? `${msg} ${args.join(' ')}` : msg);
  }

  static info(msg: string, ...args: string[]): void {
    hilog.info(DOMAIN, TAG, '%{public}s', args.length > 0 ? `${msg} ${args.join(' ')}` : msg);
  }

  static warn(msg: string, ...args: string[]): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', args.length > 0 ? `${msg} ${args.join(' ')}` : msg);
  }

  static error(msg: string, ...args: string[]): void {
    hilog.error(DOMAIN, TAG, '%{public}s', args.length > 0 ? `${msg} ${args.join(' ')}` : msg);
  }
}
