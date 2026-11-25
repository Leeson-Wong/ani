import { http } from '@kit.NetworkKit';
import { resolveUrl } from '../../utils/UrlUtil';
import { Log } from '../../common/Logger';

/**
 * 直播线路实测选速:拉流探速必须测真正的 .ts 媒体段
 * (m3u8 索引只有几 KB,下载瞬间完成,测不出带宽)。
 * 流程:m3u8 → (master 则取子表) → 第一个 .ts 段 → 持续拉 N 秒统计吞吐。
 */
export class LiveSpeedTest {
  private static cache: Map<string, number> = new Map();
  private static probing: Map<string, Promise<number>> = new Map();

  /** 返回最快线路下标;全部失败返回 -1。进程内缓存,同频道只测一次 */
  static async pickFastest(name: string, urls: string[], probeMs: number = 2500): Promise<number> {
    const key = LiveSpeedTest.key(name, urls);
    const cached = LiveSpeedTest.cache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const inflight = LiveSpeedTest.probing.get(key);
    if (inflight !== undefined) {
      return await inflight;
    }
    const task = LiveSpeedTest.doPick(urls, probeMs).then((best: number) => {
      if (best >= 0) {
        LiveSpeedTest.cache.set(key, best);
      }
      LiveSpeedTest.probing.delete(key);
      return best;
    }).catch(() => {
      LiveSpeedTest.probing.delete(key);
      return -1;
    });
    LiveSpeedTest.probing.set(key, task);
    return await task;
  }

  private static async doPick(urls: string[], probeMs: number): Promise<number> {
    const tasks: Promise<number>[] = urls.map((u: string) => LiveSpeedTest.probeUrl(u, probeMs));
    const speeds = await Promise.all(tasks);
    let best = -1;
    let bestKbps = 0;
    for (let i = 0; i < speeds.length; i++) {
      Log.info('live speed', `${i}`, `${Math.round(speeds[i])} kbps`);
      if (speeds[i] > bestKbps) {
        bestKbps = speeds[i];
        best = i;
      }
    }
    return best;
  }

  /** 单线路测速:m3u8 → ts 段 → 拉流统计;失败返回 0 */
  static async probeUrl(url: string, probeMs: number): Promise<number> {
    try {
      const tsUrl = await LiveSpeedTest.firstSegment(url);
      if (tsUrl.length === 0) {
        return 0;
      }
      return await LiveSpeedTest.pullFor(tsUrl, probeMs);
    } catch (e) {
      return 0;
    }
  }

  /** 解析 m3u8(master 递归一层)得到第一个媒体段地址 */
  private static async firstSegment(m3u8Url: string): Promise<string> {
    const text = await LiveSpeedTest.fetchText(m3u8Url);
    const lines = text.split('\n');
    let pendingInf = false;
    for (const raw of lines) {
      const line = raw.trim();
      if (line.length === 0) {
        continue;
      }
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        pendingInf = false; // master 表:子表地址在下一行
        continue;
      }
      if (line.startsWith('#EXTINF')) {
        pendingInf = true;
        continue;
      }
      if (line.startsWith('#')) {
        continue;
      }
      // 非#行:地址
      const resolved = resolveUrl(m3u8Url, line);
      if (pendingInf || line.indexOf('.ts') >= 0 || line.indexOf('.m4s') >= 0) {
        return resolved; // 媒体段
      }
      // master 的子表(可能是 m3u8)
      if (line.indexOf('.m3u8') >= 0 || line === resolved) {
        const sub = await LiveSpeedTest.fetchText(resolved);
        const subSeg = LiveSpeedTest.parseSegmentFromText(sub);
        if (subSeg.length > 0) {
          return resolveUrl(resolved, subSeg);
        }
      }
      pendingInf = false;
    }
    return '';
  }

  private static parseSegmentFromText(text: string): string {
    const lines = text.split('\n');
    let pendingInf = false;
    for (const raw of lines) {
      const line = raw.trim();
      if (line.startsWith('#EXTINF')) {
        pendingInf = true;
        continue;
      }
      if (line.startsWith('#') || line.length === 0) {
        continue;
      }
      if (pendingInf) {
        return line;
      }
    }
    return '';
  }

  private static fetchText(url: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const req = http.createHttp();
      req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 3500,
        readTimeout: 6000,
        expectDataType: http.HttpDataType.STRING
      }).then((resp) => {
        req.destroy();
        if (typeof resp.result === 'string' && resp.result.startsWith('#EXT')) {
          resolve(resp.result);
        } else {
          reject(new Error('not m3u8'));
        }
      }).catch((e: Object) => {
        req.destroy();
        reject(new Error(`${e}`));
      });
    });
  }

  /** 对 ts 段持续拉 probeMs 毫秒,返回 kbps */
  private static pullFor(url: string, probeMs: number): Promise<number> {
    return new Promise<number>((resolve) => {
      const req = http.createHttp();
      let bytes = 0;
      const t0 = Date.now();
      let settled = false;
      const finish = () => {
        if (settled) {
          return;
        }
        settled = true;
        const durS = (Date.now() - t0) / 1000;
        let kbps = 0;
        if (durS > 0.2 && bytes > 8192) {
          kbps = bytes * 8 / durS / 1000;
        }
        try {
          req.destroy();
        } catch (e) {
          // ignore
        }
        resolve(kbps);
      };
      req.on('dataReceive', (chunk: ArrayBuffer) => {
        bytes += chunk.byteLength;
      });
      req.requestInStream(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 3500,
        readTimeout: probeMs + 1500
      }).catch(() => {
        finish();
      });
      setTimeout(finish, probeMs);
    });
  }

  private static key(name: string, urls: string[]): string {
    return `${name}|${urls.length}|${urls[0] ?? ''}`;
  }
}
