/** BT 协议字节工具:大端读写 / 拼接 / 百分号编码 / peer id / 公网 IPv4 判断 */

export class BtUtil {
  /** 拼接多段字节 */
  static concat(parts: Uint8Array[]): Uint8Array {
    let n = 0;
    for (const p of parts) {
      n += p.length;
    }
    const out = new Uint8Array(n);
    let off = 0;
    for (const p of parts) {
      out.set(p, off);
      off += p.length;
    }
    return out;
  }

  /** 取精确覆盖该视图的 ArrayBuffer(socket send 用;视图可能是 subarray) */
  static toAb(b: Uint8Array): ArrayBuffer {
    if (b.byteOffset === 0 && b.byteLength === b.buffer.byteLength) {
      return b.buffer as ArrayBuffer;
    }
    return b.slice().buffer as ArrayBuffer;
  }

  /** 字节 → %xx 百分号编码(tracker 查询里的 info_hash/peer_id 必须按原始字节编码) */
  static pct(bytes: Uint8Array): string {
    const hexc = '0123456789abcdef';
    let out = '';
    for (let i = 0; i < bytes.length; i++) {
      out += '%' + hexc.charAt((bytes[i] >> 4) & 0x0f) + hexc.charAt(bytes[i] & 0x0f);
    }
    return out;
  }

  static readBe16(b: Uint8Array, off: number): number {
    return (b[off] << 8) | b[off + 1];
  }

  static readBe32(b: Uint8Array, off: number): number {
    return ((b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]) >>> 0;
  }

  static putBe16(b: Uint8Array, off: number, v: number): void {
    b[off] = (v >> 8) & 0xff;
    b[off + 1] = v & 0xff;
  }

  static putBe32(b: Uint8Array, off: number, v: number): void {
    b[off] = (v >>> 24) & 0xff;
    b[off + 1] = (v >>> 16) & 0xff;
    b[off + 2] = (v >>> 8) & 0xff;
    b[off + 3] = v & 0xff;
  }

  /** 64 位大端(v < 2^53,JS Number 精度内) */
  static putBe64(b: Uint8Array, off: number, v: number): void {
    const hi = Math.floor(v / 4294967296);
    const lo = v - hi * 4294967296;
    BtUtil.putBe32(b, off, hi);
    BtUtil.putBe32(b, off + 4, lo);
  }

  /** ASCII 区间取字符串(错误消息用) */
  static ascStr(b: Uint8Array, off: number): string {
    let out = '';
    for (let i = off; i < b.length; i++) {
      out += String.fromCharCode(b[i] >= 0x20 && b[i] < 0x7f ? b[i] : 0x2e);
    }
    return out;
  }

  /** bitfield 置位数(peer 持有的 piece 数) */
  static countBits(bytes: Uint8Array): number {
    let n = 0;
    for (let i = 0; i < bytes.length; i++) {
      let b = bytes[i];
      while (b !== 0) {
        n += b & 1;
        b = b >>> 1;
      }
    }
    return n;
  }

  /** 是否公网 IPv4(过滤 NAT/监测节点候选时用;v6 直接 false) */
  static isPublicIpv4(ip: string): boolean {
    const m = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(ip);
    if (m === null) {
      return false;
    }
    const a = Number(m[1]);
    const b = Number(m[2]);
    if (a === 0 || a === 10 || a === 127 || a >= 224) {
      return false;
    }
    if (a === 172 && b >= 16 && b <= 31) {
      return false;
    }
    if (a === 192 && b === 168) {
      return false;
    }
    if (a === 169 && b === 254) {
      return false;
    }
    if (a === 100 && b >= 64 && b <= 127) {
      return false;
    }
    return true;
  }

  /** 20 字节 peer id(Azureus 风格:-AN0001- + 12 位随机) */
  static randomPeerId(): Uint8Array {
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    let s = '-AN0001-';
    for (let i = 0; i < 12; i++) {
      s += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    const out = new Uint8Array(20);
    for (let i = 0; i < 20; i++) {
      out[i] = s.charCodeAt(i) & 0x7f;
    }
    return out;
  }
}
