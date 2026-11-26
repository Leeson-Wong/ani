import { http } from '@kit.NetworkKit';
import { AppError } from '../../common/AppError';
import { Log } from '../../common/Logger';

const CHROME_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/** 单次请求的可调参数(全部可省) */
export interface HttpOpts {
  connectMs?: number; // 连接超时,默认 6000
  readMs?: number; // 读超时,文本默认 12000 / 二进制默认 30000
  retries?: number; // 失败后同 URL 重试次数,默认 0;4xx 不重试
  quiet?: boolean; // true 时不打失败日志(图片/HLS 段这类高频路径用)
}

/**
 * 统一 HTTP 客户端:CMS 采集站、AnimeGarden、漫画、HLS 分段共用。
 * 基于 @ohos.net.http,每请求一个 http 实例(用完销毁)。
 * 支持分级超时、失败重试(4xx 除外)、二进制下载。
 */
export class HttpClient {
  static async getText(url: string, headers?: Record<string, string>, opts?: HttpOpts): Promise<string> {
    const connectMs: number = opts !== undefined && opts.connectMs !== undefined ? opts.connectMs : 6000;
    const readMs: number = opts !== undefined && opts.readMs !== undefined ? opts.readMs : 12000;
    const retries: number = opts !== undefined && opts.retries !== undefined ? opts.retries : 0;
    const quiet: boolean = opts !== undefined && opts.quiet === true;
    let lastErr: AppError = new AppError('请求失败');
    for (let attempt = 0; attempt <= retries; attempt++) {
      const request = http.createHttp();
      try {
        const merged: Record<string, string> = { 'user-agent': CHROME_UA };
        if (headers !== undefined) {
          const keys = Object.keys(headers);
          for (let i = 0; i < keys.length; i++) {
            merged[keys[i]] = headers[keys[i]];
          }
        }
        const response = await request.request(url, {
          method: http.RequestMethod.GET,
          header: merged,
          connectTimeout: connectMs,
          readTimeout: readMs,
          expectDataType: http.HttpDataType.STRING
        });
        if (response.responseCode < 200 || response.responseCode >= 300) {
          throw new AppError(`HTTP ${response.responseCode}`, response.responseCode);
        }
        const body = response.result;
        if (typeof body !== 'string') {
          throw new AppError('empty response body');
        }
        return body;
      } catch (e) {
        const err = AppError.from(e as Object);
        lastErr = err;
        if (!quiet) {
          Log.warn('http get failed', url, err.message);
        }
        if (err.code >= 400 && err.code < 500) {
          throw err; // 服务端已明确拒绝,重试无意义
        }
      } finally {
        request.destroy();
      }
    }
    throw lastErr;
  }

  static async getJson<T>(url: string, headers?: Record<string, string>, opts?: HttpOpts): Promise<T> {
    const text = await HttpClient.getText(url, headers, opts);
    try {
      return JSON.parse(text) as T;
    } catch (e) {
      throw new AppError(`invalid JSON response: ${text.substring(0, 120)}`);
    }
  }

  /** 二进制下载(图片/HLS 段/密钥);返回的 Uint8Array 覆盖整个底层 buffer,可直接 writeSync */
  static async getBinary(url: string, headers?: Record<string, string>, opts?: HttpOpts): Promise<Uint8Array> {
    const connectMs: number = opts !== undefined && opts.connectMs !== undefined ? opts.connectMs : 6000;
    const readMs: number = opts !== undefined && opts.readMs !== undefined ? opts.readMs : 30000;
    const retries: number = opts !== undefined && opts.retries !== undefined ? opts.retries : 0;
    const quiet: boolean = opts !== undefined && opts.quiet === true;
    let lastErr: AppError = new AppError('请求失败');
    for (let attempt = 0; attempt <= retries; attempt++) {
      const request = http.createHttp();
      try {
        const merged: Record<string, string> = { 'user-agent': CHROME_UA };
        if (headers !== undefined) {
          const keys = Object.keys(headers);
          for (let i = 0; i < keys.length; i++) {
            merged[keys[i]] = headers[keys[i]];
          }
        }
        const response = await request.request(url, {
          method: http.RequestMethod.GET,
          header: merged,
          connectTimeout: connectMs,
          readTimeout: readMs,
          expectDataType: http.HttpDataType.ARRAY_BUFFER
        });
        if (response.responseCode < 200 || response.responseCode >= 300) {
          throw new AppError(`HTTP ${response.responseCode}`, response.responseCode);
        }
        const body = response.result;
        if (body instanceof ArrayBuffer) {
          return new Uint8Array(body);
        }
        throw new AppError('binary response expected');
      } catch (e) {
        const err = AppError.from(e as Object);
        lastErr = err;
        if (!quiet) {
          Log.warn('http binary failed', url, err.message);
        }
        if (err.code >= 400 && err.code < 500) {
          throw err;
        }
      } finally {
        request.destroy();
      }
    }
    throw lastErr;
  }
}
