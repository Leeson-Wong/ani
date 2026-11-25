import { util } from '@kit.ArkTS';

/**
 * Bencode 编解码(BitTorrent / tracker 协议的基础编码)。
 * ArkTS 严格模式:用 class 承载节点,避免无类型对象字面量。
 */

export const BK_INT: number = 0;
export const BK_BYTES: number = 1;
export const BK_LIST: number = 2;
export const BK_DICT: number = 3;

/** bencode 节点:按 kind 读取 intVal / bytes / list / dict 之一 */
export class BNode {
  kind: number = BK_INT;
  intVal: number = 0;
  bytes: Uint8Array = new Uint8Array(0);
  list: BNode[] = [];
  dict: Map<string, BNode> = new Map<string, BNode>();

  static intValue(v: number): BNode {
    const n = new BNode();
    n.kind = BK_INT;
    n.intVal = v;
    return n;
  }

  static bytesValue(v: Uint8Array): BNode {
    const n = new BNode();
    n.kind = BK_BYTES;
    n.bytes = v;
    return n;
  }

  static stringValue(v: string): BNode {
    const buf = new util.TextEncoder().encodeInto(v);
    return BNode.bytesValue(buf);
  }

  static listValue(v: BNode[]): BNode {
    const n = new BNode();
    n.kind = BK_LIST;
    n.list = v;
    return n;
  }

  static dictValue(v: Map<string, BNode>): BNode {
    const n = new BNode();
    n.kind = BK_DICT;
    n.dict = v;
    return n;
  }

  /** 取字典子节点,不存在返回 undefined */
  get(key: string): BNode | undefined {
    return this.dict.get(key);
  }

  /** 取字节节点的字符串表示 */
  asString(): string {
    if (this.kind !== BK_BYTES) {
      return '';
    }
    return util.TextDecoder.create('utf-8').decodeToString(this.bytes);
  }
}

/** bencode 解码:返回节点树;格式非法抛 Error */
export class Bencode {
  static decode(buf: Uint8Array): BNode {
    const ctx = new BReader(buf);
    const node = ctx.read();
    return node;
  }

  /** 编码节点为字节(主要给扩展协议握手用) */
  static encode(node: BNode): Uint8Array {
    const out = new ByteSink();
    Bencode.write(node, out);
    return out.toArray();
  }

  private static write(node: BNode, out: ByteSink): void {
    if (node.kind === BK_INT) {
      out.text(`i${node.intVal}e`);
    } else if (node.kind === BK_BYTES) {
      out.text(`${node.bytes.length}:`);
      out.bytes(node.bytes);
    } else if (node.kind === BK_LIST) {
      out.text('l');
      for (const child of node.list) {
        Bencode.write(child, out);
      }
      out.text('e');
    } else {
      out.text('d');
      // bencode 字典要求 key 按字节序排序
      const keys: string[] = Array.from(node.dict.keys()).sort((a: string, b: string) => {
        const ab = new util.TextEncoder().encodeInto(a);
        const bb = new util.TextEncoder().encodeInto(b);
        const len = Math.min(ab.length, bb.length);
        for (let i = 0; i < len; i++) {
          if (ab[i] !== bb[i]) {
            return ab[i] - bb[i];
          }
        }
        return ab.length - bb.length;
      });
      for (const key of keys) {
        const child = node.dict.get(key);
        if (child !== undefined) {
          out.text(`${key.length}:`);
          out.text(key);
          Bencode.write(child, out);
        }
      }
      out.text('e');
    }
  }
}

class BReader {
  private buf: Uint8Array;
  private pos: number = 0;

  constructor(buf: Uint8Array) {
    this.buf = buf;
  }

  read(): BNode {
    if (this.pos >= this.buf.length) {
      throw new Error('bencode: unexpected end');
    }
    const c = this.buf[this.pos];
    if (c === 0x69) {
      return this.readInt();
    }
    if (c === 0x6c) {
      return this.readList();
    }
    if (c === 0x64) {
      return this.readDict();
    }
    return BNode.bytesValue(this.readBytes());
  }

  private readInt(): BNode {
    this.pos++; // i
    const start = this.pos;
    while (this.pos < this.buf.length && this.buf[this.pos] !== 0x65) {
      this.pos++;
    }
    const text = this.str(start, this.pos);
    this.pos++; // e
    const value = Number(text);
    return BNode.intValue(value);
  }

  private readBytes(): Uint8Array {
    const start = this.pos;
    while (this.pos < this.buf.length && this.buf[this.pos] >= 0x30 && this.buf[this.pos] <= 0x39) {
      this.pos++;
    }
    const lenText = this.str(start, this.pos);
    const len = Number(lenText);
    this.pos++; // :
    const data = this.buf.slice(this.pos, this.pos + len);
    this.pos += len;
    return data;
  }

  private readList(): BNode {
    this.pos++; // l
    const arr: BNode[] = [];
    while (this.pos < this.buf.length && this.buf[this.pos] !== 0x65) {
      arr.push(this.read());
    }
    this.pos++; // e
    return BNode.listValue(arr);
  }

  private readDict(): BNode {
    this.pos++; // d
    const map = new Map<string, BNode>();
    while (this.pos < this.buf.length && this.buf[this.pos] !== 0x65) {
      const keyBytes = this.readBytes();
      const key = util.TextDecoder.create('utf-8').decodeToString(keyBytes);
      const value = this.read();
      map.set(key, value);
    }
    this.pos++; // e
    return BNode.dictValue(map);
  }

  private str(from: number, to: number): string {
    return util.TextDecoder.create('utf-8')
      .decodeToString(this.buf.slice(from, to));
  }
}

/** 可变字节缓冲,用于编码 */
class ByteSink {
  private chunks: Uint8Array[] = [];
  private length: number = 0;

  text(s: string): void {
    this.bytes(new util.TextEncoder().encodeInto(s));
  }

  bytes(b: Uint8Array): void {
    this.chunks.push(b);
    this.length += b.length;
  }

  toArray(): Uint8Array {
    const out = new Uint8Array(this.length);
    let offset = 0;
    for (const chunk of this.chunks) {
      out.set(chunk, offset);
      offset += chunk.length;
    }
    return out;
  }
}
