import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { resolveUrl } from '../../utils/UrlUtil';
import { Log } from '../../common/Logger';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/** 一次下载调用的结果:stopped=true 表示暂停/移除(不算失败) */
export interface HlsDownloadResult {
  ok: boolean;
  stopped: boolean;
  bytes: number;
  done: number;
  total: number;
  outFile: string;
  message: string;
  estDurSec: number; // playlist EXTINF 合计秒(完成时写 vdur,供本地代理播放列表用)
}

/** 断点文件:恢复下载的全部信息(段清单落盘,恢复时不再拉 playlist) */
interface HlsSidecar {
  url: string;
  outFile: string;
  total: number;
  done: number;
  mediaSeq: number;
  keyUri: string; // '' = 未加密
  keyIvHex: string; // '' = IV 用段序号
  segs: string[];
  bytes: number;
  estDurSec: number; // 旧断点文件可能没有此字段,读出来按 0 处理
}

interface KeyInfo {
  method: string;
  uri: string;
  ivHex: string;
}

/** media playlist 解析结果 */
interface ParsedPlaylist {
  segs: string[];
  key: KeyInfo | null;
  mediaSeq: number;
  durSec: number; // EXTINF 合计秒
}

/** 体积预估结果 */
interface SizeEstimate {
  total: number;
  approxBytes: number;
}

function fromHex(hex: string): Uint8Array {
  const out = new Uint8Array(Math.floor(hex.length / 2));
  for (let i = 0; i + 1 < hex.length; i += 2) {
    out[i / 2] = parseInt(hex.substring(i, i + 2), 16);
  }
  return out;
}

function seqIv(seq: number): Uint8Array {
  const iv = new Uint8Array(16);
  iv[12] = (seq >>> 24) & 0xff;
  iv[13] = (seq >>> 16) & 0xff;
  iv[14] = (seq >>> 8) & 0xff;
  iv[15] = seq & 0xff;
  return iv;
}

/** 去 PKCS7 填充(每段独立加密,尾部 1~16 字节填充) */
function stripPkcs7(data: Uint8Array): Uint8Array {
  if (data.length === 0) {
    return data;
  }
  const pad = data[data.length - 1];
  if (pad < 1 || pad > 16 || pad > data.length) {
    return data;
  }
  for (let i = data.length - pad; i < data.length; i++) {
    if (data[i] !== pad) {
      return data;
    }
  }
  return data.slice(0, data.length - pad);
}

/**
 * HLS → 单个 .ts 的离线下载内核(路线 A,已由 HlsProbe 真机验证):
 * media playlist → (AES-128 密钥/IV) → 4 并发下载 → 按序解密追加落盘 → 断点续传。
 * 断点 = sidecar json({base}.sidecar.json);恢复时沿用已落盘的段清单,不再拉 playlist。
 */
export class HlsDownloader {
  private static async fetchText(url: string): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'user-agent': UA },
        connectTimeout: 8000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING
      });
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      return resp.result as string;
    } finally {
      req.destroy();
    }
  }

  private static async fetchBinary(url: string): Promise<Uint8Array> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'user-agent': UA },
        connectTimeout: 8000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      return new Uint8Array(resp.result as ArrayBuffer);
    } finally {
      req.destroy();
    }
  }

  /** master playlist 自动下钻一层 */
  static async resolveMedia(m3u8Url: string): Promise<string[]> {
    const text = await HlsDownloader.fetchText(m3u8Url);
    if (text.indexOf('#EXTINF') >= 0) {
      return HlsDownloader.parseSegments(text, m3u8Url).segs;
    }
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].trim().startsWith('#EXT-X-STREAM-INF')) {
        for (let j = i + 1; j < lines.length; j++) {
          const l = lines[j].trim();
          if (l.length === 0 || l.startsWith('#')) {
            continue;
          }
          const subUrl = resolveUrl(m3u8Url, l);
          const subText = await HlsDownloader.fetchText(subUrl);
          return HlsDownloader.parseSegments(subText, subUrl).segs;
        }
      }
    }
    throw new Error('playlist 里既无 EXTINF 也无子表');
  }

  private static parseAttr(line: string, name: string): string {
    const marker = `${name}=`;
    const idx = line.indexOf(marker);
    if (idx < 0) {
      return '';
    }
    const rest = line.substring(idx + marker.length);
    if (rest.startsWith('"')) {
      const end = rest.indexOf('"', 1);
      return end > 0 ? rest.substring(1, end) : '';
    }
    const comma = rest.indexOf(',');
    return comma >= 0 ? rest.substring(0, comma) : rest;
  }

  /** media playlist → 段清单 + 密钥信息 + 起始序号 */
  static parseSegments(text: string, baseUrl: string): ParsedPlaylist {
    let key: KeyInfo | null = null;
    let mediaSeq = 0;
    let durSec = 0;
    const segs: string[] = [];
    for (const raw of text.split('\n')) {
      const line = raw.trim();
      if (line.startsWith('#EXTINF:')) {
        const comma = line.indexOf(',');
        const v = Number(line.substring('#EXTINF:'.length, comma >= 0 ? comma : line.length));
        if (Number.isFinite(v) && v > 0) {
          durSec += v;
        }
      } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        mediaSeq = Number(line.substring('#EXT-X-MEDIA-SEQUENCE:'.length));
      } else if (line.startsWith('#EXT-X-KEY:') && key === null) {
        key = {
          method: HlsDownloader.parseAttr(line, 'METHOD'),
          uri: resolveUrl(baseUrl, HlsDownloader.parseAttr(line, 'URI')),
          ivHex: HlsDownloader.parseAttr(line, 'IV').replace(/^0[xX]/, '')
        };
      } else if (!line.startsWith('#') && line.length > 0) {
        segs.push(resolveUrl(baseUrl, line));
      }
    }
    if (key !== null && key.method.toUpperCase() !== 'AES-128') {
      key = null; // SAMPLE-AES 等暂不支持,按未加密处理会得到坏数据,这里显式置空走原样合并
    }
    const parsed: ParsedPlaylist = { segs: segs, key: key, mediaSeq: mediaSeq, durSec: durSec };
    return parsed;
  }

  private static async decryptSegment(cipher: cryptoFramework.Cipher,
    symKey: cryptoFramework.SymKey, keyIvHex: string, seq: number, enc: Uint8Array): Promise<Uint8Array> {
    const usable = enc.byteLength - (enc.byteLength % 16);
    if (usable <= 0) {
      throw new Error(`段 #${seq} 长度 ${enc.byteLength} 不足一个 AES 块`);
    }
    const body = new Uint8Array(enc.buffer, enc.byteOffset, usable);
    const iv = keyIvHex.length === 32 ? fromHex(keyIvHex) : seqIv(seq);
    const ivBlob: cryptoFramework.DataBlob = { data: iv };
    const spec: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: ivBlob };
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, spec);
    const input: cryptoFramework.DataBlob = { data: body };
    const out = await cipher.doFinal(input);
    return stripPkcs7(out.data);
  }

  private static sidecarPath(base: string): string {
    return `${base}.sidecar.json`;
  }

  private static loadSidecar(base: string): HlsSidecar | null {
    const p = HlsDownloader.sidecarPath(base);
    if (!fileIo.accessSync(p)) {
      return null;
    }
    try {
      return JSON.parse(fileIo.readTextSync(p)) as HlsSidecar;
    } catch (e) {
      return null;
    }
  }

  private static saveSidecar(base: string, sc: HlsSidecar): void {
    try {
      const f = fileIo.openSync(HlsDownloader.sidecarPath(base),
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(f.fd, JSON.stringify(sc));
      } finally {
        fileIo.closeSync(f);
      }
    } catch (e) {
      Log.warn('save sidecar failed', base, `${e}`);
    }
  }

  /**
   * 下载一集到 `{base}.ts`。
   * base 例:`{filesDir}/video_cache/v360_12345_e3`(sidecar 同名 .json)。
   * shouldStop 返回 true 时尽快收尾,返回 stopped=true(已写入部分与断点保留,续传接得上)。
   */
  static async download(m3u8Url: string, base: string, concurrency: number,
    onProgress: (done: number, total: number, bytes: number) => void,
    shouldStop: () => boolean): Promise<HlsDownloadResult> {
    const t0 = Date.now();
    let sc = HlsDownloader.loadSidecar(base);
    try {
      // ① 断点无效/不存在 → 重新解析 playlist
      if (sc === null || sc.url !== m3u8Url || sc.segs.length === 0) {
        const text = await HlsDownloader.fetchText(m3u8Url);
        let parsed: ParsedPlaylist;
        if (text.indexOf('#EXTINF') >= 0) {
          parsed = HlsDownloader.parseSegments(text, m3u8Url);
        } else {
          // master:下钻一层
          let subUrl = '';
          const lines = text.split('\n');
          for (let i = 0; i < lines.length && subUrl.length === 0; i++) {
            if (!lines[i].trim().startsWith('#EXT-X-STREAM-INF')) {
              continue;
            }
            for (let j = i + 1; j < lines.length; j++) {
              const l = lines[j].trim();
              if (l.length > 0 && !l.startsWith('#')) {
                subUrl = resolveUrl(m3u8Url, l);
                break;
              }
            }
          }
          if (subUrl.length === 0) {
            throw new Error('playlist 里既无 EXTINF 也无子表');
          }
          parsed = HlsDownloader.parseSegments(await HlsDownloader.fetchText(subUrl), subUrl);
        }
        if (parsed.segs.length === 0) {
          throw new Error('playlist 没有媒体段');
        }
        const outFile = `${base}.ts`;
        sc = {
          url: m3u8Url,
          outFile: outFile,
          total: parsed.segs.length,
          done: 0,
          mediaSeq: parsed.mediaSeq,
          keyUri: parsed.key !== null ? parsed.key.uri : '',
          keyIvHex: parsed.key !== null ? parsed.key.ivHex : '',
          segs: parsed.segs,
          bytes: 0,
          estDurSec: parsed.durSec
        };
        HlsDownloader.saveSidecar(base, sc);
        // 换了源重新下:清掉旧产物
        if (fileIo.accessSync(outFile)) {
          fileIo.unlinkSync(outFile);
        }
      }
      // 闭包里引用会让 TS 丢失非空收窄,固定一份非空引用
      const side: HlsSidecar = sc;

      // ② 解密准备
      let cipher: cryptoFramework.Cipher | null = null;
      let symKey: cryptoFramework.SymKey | null = null;
      if (side.keyUri.length > 0) {
        const keyBytes = await HlsDownloader.fetchBinary(side.keyUri);
        if (keyBytes.byteLength !== 16) {
          throw new Error(`密钥长度异常:${keyBytes.byteLength}`);
        }
        const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
        symKey = await cryptoFramework.createSymKeyGenerator('AES128').convertKey(keyBlob);
        cipher = cryptoFramework.createCipher('AES128|CBC|NoPadding');
      }

      // ③ 4 并发下载 + 顺序解密追加落盘(写窗口:领先待写序号 10 段,失败时浪费有限)
      let mode = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE;
      if (side.done === 0) {
        mode |= fileIo.OpenMode.TRUNC; // 全新下载清旧文件;续传则追加
      }
      const f = fileIo.openSync(side.outFile, mode);
      const buf = new Map<number, Uint8Array>();
      let nextWrite = side.done;
      let bytes = side.bytes;
      let stop = false;
      let dlFail = '';
      let dlDone = false;
      try {
        let idx = nextWrite;
        const worker = async (): Promise<void> => {
          for (;;) {
            if (stop || dlFail.length > 0 || idx >= side.total) {
              return;
            }
            if (idx - nextWrite >= 10) {
              // 写入跟不上:让出,等下一轮
              await new Promise<void>((r: () => void) => setTimeout(r, 120));
              continue;
            }
            const i = idx;
            idx++;
            try {
              buf.set(i, await HlsDownloader.fetchBinary(side.segs[i]));
            } catch (e) {
              idx--; // 失败的段让给别人重试一次
              if (dlFail.length === 0) {
                dlFail = `段 #${i} 下载失败:${e}`;
              }
              return;
            }
          }
        };
        const ws: Promise<void>[] = [];
        for (let k = 0; k < Math.min(concurrency, side.total - nextWrite); k++) {
          ws.push(worker());
        }
        Promise.all(ws).then(() => {
          dlDone = true;
        }).catch(() => {
          dlDone = true;
        });
        // 写循环:按序取已下载段解密追加;下载侧全部结束且缺段 → 跳出判失败
        const writeLoop = async (): Promise<void> => {
          while (nextWrite < side.total) {
            if (shouldStop()) {
              stop = true;
              return;
            }
            const piece = buf.get(nextWrite);
            if (piece === undefined) {
              if (dlDone) {
                return;
              }
              await new Promise<void>((r: () => void) => setTimeout(r, 60));
              continue;
            }
            const plain = cipher !== null && symKey !== null
              ? await HlsDownloader.decryptSegment(cipher, symKey, side.keyIvHex, side.mediaSeq + nextWrite, piece)
              : piece;
            fileIo.writeSync(f.fd, plain.buffer as ArrayBuffer, { offset: bytes, length: plain.byteLength });
            bytes += plain.byteLength;
            buf.delete(nextWrite);
            nextWrite++;
            if (nextWrite % 10 === 0 || nextWrite === side.total) {
              side.done = nextWrite;
              side.bytes = bytes;
              HlsDownloader.saveSidecar(base, side);
            }
            onProgress(nextWrite, side.total, bytes);
          }
        };
        await writeLoop();
        await Promise.all(ws).catch(() => {
        });
        // 收尾判定
        if (stop) {
          side.done = nextWrite;
          side.bytes = bytes;
          HlsDownloader.saveSidecar(base, side);
          const stopped: HlsDownloadResult = {
            ok: false, stopped: true, bytes: bytes, done: nextWrite, total: side.total,
            outFile: side.outFile, message: '已暂停/移除', estDurSec: side.estDurSec
          };
          return stopped;
        }
        if (nextWrite < side.total) {
          side.done = nextWrite;
          side.bytes = bytes;
          HlsDownloader.saveSidecar(base, side);
          const failed: HlsDownloadResult = {
            ok: false, stopped: false, bytes: bytes, done: nextWrite, total: side.total,
            outFile: side.outFile, message: dlFail.length > 0 ? dlFail : '下载中断', estDurSec: side.estDurSec
          };
          return failed;
        }
      } finally {
        fileIo.closeSync(f);
      }

      // ④ 完成:清断点文件
      side.done = side.total;
      side.bytes = bytes;
      try {
        if (fileIo.accessSync(HlsDownloader.sidecarPath(base))) {
          fileIo.unlinkSync(HlsDownloader.sidecarPath(base));
        }
      } catch (e) {
        // 忽略
      }
      const done: HlsDownloadResult = {
        ok: true, stopped: false, bytes: bytes, done: side.total, total: side.total,
        outFile: side.outFile, message: `完成,${(bytes / 1024 / 1024).toFixed(0)}MB,耗时 ${Math.round((Date.now() - t0) / 1000)}s`,
        estDurSec: side.estDurSec
      };
      return done;
    } catch (e) {
      Log.warn('hls download failed', base, `${e}`);
      const failed: HlsDownloadResult = {
        ok: false, stopped: false, bytes: sc !== null ? sc.bytes : 0,
        done: sc !== null ? sc.done : 0, total: sc !== null ? sc.total : 0,
        outFile: sc !== null ? sc.outFile : '', message: `${e}`,
        estDurSec: sc !== null ? sc.estDurSec : 0
      };
      return failed;
    }
  }

  /** 预估一集体积:解析 playlist,取第 1 段字节数 × 总段数 */
  static async estimate(m3u8Url: string): Promise<SizeEstimate> {
    const segs = await HlsDownloader.resolveMedia(m3u8Url);
    if (segs.length === 0) {
      const zero: SizeEstimate = { total: 0, approxBytes: 0 };
      return zero;
    }
    const sample = await HlsDownloader.fetchBinary(segs[0]);
    const est: SizeEstimate = {
      total: segs.length,
      approxBytes: sample.byteLength * segs.length
    };
    return est;
  }
}
