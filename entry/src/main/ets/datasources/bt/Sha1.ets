/** SHA1 摘要(纯实现,避免依赖加密框架 API 差异)。BT piece 校验 / infoHash 计算。 */

/** 左循环移位 */
function rol(v: number, n: number): number {
  return ((v << n) | (v >>> (32 - n))) >>> 0;
}

/** 计算字节数组的 SHA1,返回 20 字节 */
export function sha1(data: Uint8Array): Uint8Array {
  const ml = data.length * 8;
  // 填充:原始字节 + 0x80 + 若干 0x00 + 8 字节长度(bit,大端)
  const zeroPad = (56 - ((data.length + 1) % 64) + 64) % 64;
  const total = data.length + 1 + zeroPad + 8;
  const msg = new Uint8Array(total);
  msg.set(data, 0);
  msg[data.length] = 0x80;
  // 大端写入 64 位长度(高位 4 字节为 0,低 4 字节为 ml,用 8 字节覆盖)
  const high = Math.floor(ml / 0x100000000);
  const low = ml >>> 0;
  const lenPos = total - 8;
  msg[lenPos] = (high >>> 24) & 0xff;
  msg[lenPos + 1] = (high >>> 16) & 0xff;
  msg[lenPos + 2] = (high >>> 8) & 0xff;
  msg[lenPos + 3] = high & 0xff;
  msg[lenPos + 4] = (low >>> 24) & 0xff;
  msg[lenPos + 5] = (low >>> 16) & 0xff;
  msg[lenPos + 6] = (low >>> 8) & 0xff;
  msg[lenPos + 7] = low & 0xff;

  let h0: number = 0x67452301;
  let h1: number = 0xefcdab89;
  let h2: number = 0x98badcfe;
  let h3: number = 0x10325476;
  let h4: number = 0xc3d2e1f0;
  const w = new Uint32Array(80);

  for (let off = 0; off < total; off += 64) {
    for (let i = 0; i < 16; i++) {
      const j = off + i * 4;
      w[i] = ((msg[j] << 24) | (msg[j + 1] << 16) | (msg[j + 2] << 8) | msg[j + 3]) >>> 0;
    }
    for (let i = 16; i < 80; i++) {
      w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;
    for (let i = 0; i < 80; i++) {
      let f: number = 0;
      let k: number = 0;
      if (i < 20) {
        f = (b & c) | ((~b) & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      const temp = (rol(a, 5) + f + e + k + w[i]) >>> 0;
      e = d;
      d = c;
      c = rol(b, 30);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
  }

  const out = new Uint8Array(20);
  const hs: number[] = [h0, h1, h2, h3, h4];
  for (let i = 0; i < 5; i++) {
    out[i * 4] = (hs[i] >>> 24) & 0xff;
    out[i * 4 + 1] = (hs[i] >>> 16) & 0xff;
    out[i * 4 + 2] = (hs[i] >>> 8) & 0xff;
    out[i * 4 + 3] = hs[i] & 0xff;
  }
  return out;
}

/** 比较两个 20 字节摘要是否相等 */
export function sha1Equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== 20 || b.length !== 20) {
    return false;
  }
  for (let i = 0; i < 20; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}
