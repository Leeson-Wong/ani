/** 业务错误:归一化三层(番茄 loopback / CMS 采集站 / 网络)的失败形态 */
export class AppError extends Error {
  readonly code: number;

  constructor(message: string, code: number = 0) {
    super(message);
    this.name = 'AppError';
    this.code = code;
  }

  static from(e: Object): AppError {
    if (e instanceof AppError) {
      return e;
    }
    if (e instanceof Error) {
      return new AppError(e.message);
    }
    return new AppError(`${e}`);
  }
}
