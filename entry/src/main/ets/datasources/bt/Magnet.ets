/** magnet 链接解析:提取 infoHash(20 字节) / 显示名 / tracker 列表。
 *  v2(btmh)不拆 hash 只记录 hex:纯 v1 内核不支持 v2-only 种子,调用方据此给出明确提示;
 *  hybrid 种子同时带 btih/btmh 两种 xt,取 btih(v1)那条。 */

export class MagnetInfo {
  infoHash: Uint8Array = new Uint8Array(0);
  infoHashHex: string = '';
  /** v2 的 btmh hex(64 位);hybrid 时与 infoHash 同时非空 */
  v2HashHex: string = '';
  displayName: string = '';
  trackers: string[] = [];
}

const B32_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/** base32(big-endian,无填充)解码为字节;非法字符返回空 */
function base32Decode(input: string): Uint8Array {
  const s = input.toUpperCase().replace(/=+$/, '');
  let bits: string = '';
  for (let i = 0; i < s.length; i++) {
    const idx = B32_ALPHABET.indexOf(s.charAt(i));
    if (idx < 0) {
      return new Uint8Array(0);
    }
    for (let b = 4; b >= 0; b--) {
      bits += ((idx >> b) & 1).toString();
    }
  }
  const byteLen = Math.floor(bits.length / 8);
  const out = new Uint8Array(byteLen);
  for (let i = 0; i < byteLen; i++) {
    out[i] = parseInt(bits.substr(i * 8, 8), 2);
  }
  return out;
}

/** 40 位 hex 转 20 字节;非法返回空 */
function hexDecode(input: string): Uint8Array {
  if (input.length !== 40) {
    return new Uint8Array(0);
  }
  if (!/^[0-9a-fA-F]{40}$/.test(input)) {
    return new Uint8Array(0);
  }
  const out = new Uint8Array(20);
  for (let i = 0; i < 20; i++) {
    out[i] = parseInt(input.substr(i * 2, 2), 16);
  }
  return out;
}

export function bytesToHex(bytes: Uint8Array): string {
  const hex: string = '0123456789abcdef';
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    out += hex.charAt((b >> 4) & 0x0f);
    out += hex.charAt(b & 0x0f);
  }
  return out;
}

/** 解析 magnet 链接;失败返回 undefined */
export function parseMagnet(magnet: string): MagnetInfo | undefined {
  if (!magnet.startsWith('magnet:')) {
    return undefined;
  }
  const qIndex = magnet.indexOf('?');
  if (qIndex < 0) {
    return undefined;
  }
  const query = magnet.substring(qIndex + 1);
  const parts = query.split('&');
  let hash: Uint8Array = new Uint8Array(0);
  const info = new MagnetInfo();

  for (const part of parts) {
    const eq = part.indexOf('=');
    if (eq < 0) {
      continue;
    }
    const key = decodeURIComponent(part.substring(0, eq)).toLowerCase();
    let value = part.substring(eq + 1);
    try {
      value = decodeURIComponent(value);
    } catch (e) {
      // 保留原值
    }
    if (key === 'xt') {
      const low = value.toLowerCase();
      if (low.startsWith('urn:btih:')) {
        const raw = low.substring('urn:btih:'.length);
        if (raw.length === 40) {
          hash = hexDecode(raw);
        } else if (raw.length === 32) {
          hash = base32Decode(raw);
        }
      } else if (low.startsWith('urn:btmh:')) {
        const raw = low.substring('urn:btmh:'.length);
        if (/^[0-9a-f]{64}$/.test(raw)) {
          info.v2HashHex = raw;
        }
      }
    } else if (key === 'dn') {
      info.displayName = value.replace(/\+/g, ' ');
    } else if (key === 'tr') {
      info.trackers.push(value);
    }
  }

  if (hash.length !== 20) {
    // 只有 v2(btmh)时也返回:调用方用 v2HashHex 给出「暂不支持 v2」的明确提示
    return info.v2HashHex.length > 0 ? info : undefined;
  }
  info.infoHash = hash;
  info.infoHashHex = bytesToHex(hash);
  return info;
}

/** 内置公共 tracker(magnet 未携带 tr 时兜底) */
export const FALLBACK_TRACKERS: string[] = [
  'http://tracker.opentrackr.org:1337/announce',
  'http://tracker.dler.org:6969/announce',
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://tracker.dler.org:6969/announce'
];
