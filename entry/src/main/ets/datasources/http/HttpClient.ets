import { http } from '@kit.NetworkKit';
import { AppError } from '../../common/AppError';
import { Log } from '../../common/Logger';

const CHROME_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/**
 * 统一 HTTP 客户端:CMS 采集站、AnimeGarden、番茄 loopback 共用。
 * 基于 @ohos.net.http,每请求一个 http 实例(用完销毁),支持覆盖默认 UA。
 */
export class HttpClient {
  static async getText(url: string, headers?: Record<string, string>): Promise<string> {
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
        connectTimeout: 8000,
        readTimeout: 15000,
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
      Log.warn('http get failed', url, err.message);
      throw err;
    } finally {
      request.destroy();
    }
  }

  static async getJson<T>(url: string, headers?: Record<string, string>): Promise<T> {
    const text = await HttpClient.getText(url, headers);
    try {
      return JSON.parse(text) as T;
    } catch (e) {
      throw new AppError(`invalid JSON response: ${text.substring(0, 120)}`);
    }
  }
}
