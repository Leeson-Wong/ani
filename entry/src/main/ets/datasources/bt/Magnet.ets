/** magnet 链接解析:提取 infoHash(20 字节) / 显示名 / tracker 列表 */

export class MagnetInfo {
  infoHash: Uint8Array = new Uint8Array(0);
  infoHashHex: string = '';
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
      const prefix = 'urn:btih:';
      const low = value.toLowerCase();
      const pos = low.indexOf(prefix);
      if (pos === 0) {
        const raw = value.substring(prefix.length);
        if (raw.length === 40) {
          hash = hexDecode(raw);
        } else if (raw.length === 32) {
          hash = base32Decode(raw);
        }
      }
    } else if (key === 'dn') {
      info.displayName = value.replace(/\+/g, ' ');
    } else if (key === 'tr') {
      info.trackers.push(value);
    }
  }

  if (hash.length !== 20) {
    return undefined;
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
