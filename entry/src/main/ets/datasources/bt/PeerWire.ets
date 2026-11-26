import { socket } from '@kit.NetworkKit';
import { Bencode, BDecodeResult, BNode, BK_BYTES, BK_DICT, BK_INT } from './Bencode';
import { BtUtil } from './BtUtil';

/** 单个 peer 的观测/交互统计(诊断展示与后续调度共用) */
export interface PeerStats {
  ip: string;
  port: number;
  connected: boolean;
  handshake: boolean;
  hashMatched: boolean;
  client: string; // 扩展握手里的 v 字段(客户端名)
  uploadOnly: boolean; // 对端已下完、只做种(最有价值的 peer)
  supportsUtMeta: boolean;
  metadataSize: number;
  bitfieldPieces: number; // -1 = 未发 bitfield
  haveCount: number;
  unchoked: boolean;
  chokeCount: number;
  dataBytes: number; // 收到的 PIECE 数据字节
  dataMs: number; // 数据测试耗时(调用方在收齐时回填)
  firstBlockMs: number; // 首块延迟(调用方回填)
  why: string; // 连接结束原因
}

/** PeerWire 事件(全部可选,构造后可再补挂) */
export interface PeerWireHooks {
  onHandshakeDone?: (pw: PeerWire) => void;
  /** 已解析扩展握手(client/upload_only/ut_metadata/metadata_size 就绪) */
  onExtHandshake?: (pw: PeerWire) => void;
  /** ut_metadata 数据片(msg_type=1;data 为字典后的原始字节) */
  onMetadataData?: (piece: number, data: Uint8Array) => void;
  onUnchoke?: (pw: PeerWire) => void;
  onPieceBlock?: (index: number, begin: number, data: Uint8Array) => void;
  onClosed?: (why: string) => void;
}

/** 消息 id(协议规范:0=CHOKE 1=UNCHOKE 2=INTERESTED 3=NOT_INTERESTED 4=HAVE 5=BITFIELD 6=REQUEST 7=PIECE 8=CANCEL 9=DHT_PORT 20=EXT) */
const MSG_CHOKE = 0;
const MSG_UNCHOKE = 1;
const MSG_HAVE = 4;
const MSG_BITFIELD = 5;
const MSG_REQUEST = 6;
const MSG_PIECE = 7;
const MSG_EXT = 20;

const PROTO = 'BitTorrent protocol';

/**
 * 单个 peer 的 TCP 状态机:握手 → 消息帧解析 → 扩展握手(BEP 10)→ ut_metadata(BEP 9)/request-piece。
 * 关键坑(§0.2 复核结论):扩展消息长度前缀 = 1(msg id)+ 1(ext id)+ 正文字节数,
 * 少算 1 字节会让对端把后续字节吞进一条假消息并断连 —— 旧调试脚本就死在这。
 * 生命周期:start() 的 Promise 在连接结束(任意原因)时 resolve,之后 stats 即最终结果。
 */
export class PeerWire {
  /** 诊断/调度读:对端声明的 ut_metadata 扩展 id(0 = 未声明) */
  extUtMetadataId: number = 0;
  readonly stats: PeerStats = {
    ip: '', port: 0, connected: false, handshake: false, hashMatched: false,
    client: '', uploadOnly: false, supportsUtMeta: false, metadataSize: 0,
    bitfieldPieces: -1, haveCount: 0, unchoked: false, chokeCount: 0,
    dataBytes: 0, dataMs: 0, firstBlockMs: 0, why: ''
  };

  private readonly sock: socket.TCPSocket;
  private readonly infoHash: Uint8Array;
  private readonly peerId: Uint8Array;
  private readonly hooks: PeerWireHooks;
  private readonly sendExt: boolean;
  private buf: Uint8Array = new Uint8Array(0);
  private closed: boolean = false;
  private handshakeDone: boolean = false;
  private deadline: number = 0;
  private resolveDone: () => void = () => {
  };
  private readonly doneP: Promise<void>;

  constructor(ip: string, port: number, infoHash: Uint8Array, peerId: Uint8Array,
    hooks: PeerWireHooks, sendExtHandshake: boolean = true) {
    this.stats.ip = ip;
    this.stats.port = port;
    this.infoHash = infoHash;
    this.peerId = peerId;
    this.hooks = hooks;
    this.sendExt = sendExtHandshake;
    this.sock = socket.constructTCPSocketInstance();
    this.doneP = new Promise<void>((resolve) => {
      this.resolveDone = resolve;
    });
    this.sock.on('message', (info: socket.SocketMessageInfo) => {
      this.onChunk(new Uint8Array(info.message));
    });
    this.sock.on('error', (err: Error) => {
      this.close(`${err}`.substring(0, 60));
    });
    this.sock.on('close', () => {
      this.close('closed');
    });
  }

  /** 连接并等待结束。timeoutMs 同时是总时长兜底。 */
  async start(timeoutMs: number): Promise<void> {
    this.deadline = setTimeout(() => {
      this.close('deadline');
    }, timeoutMs);
    try {
      await this.sock.connect({
        address: { address: this.stats.ip, port: this.stats.port },
        timeout: Math.min(timeoutMs, 8000)
      });
      this.stats.connected = true;
      this.post(this.buildHandshake());
      if (this.sendExt) {
        this.post(this.buildExtHandshake());
      }
    } catch (e) {
      this.close(`${e}`.substring(0, 60));
    }
    return this.doneP;
  }

  get isClosed(): boolean {
    return this.closed;
  }

  close(why: string): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.stats.why = why.length > 0 ? why : 'closed';
    clearTimeout(this.deadline);
    this.sock.close().catch(() => {
      // 未连接过/已断开,忽略
    });
    if (this.hooks.onClosed !== undefined) {
      this.hooks.onClosed(this.stats.why);
    }
    this.resolveDone();
  }

  // ---------------------------------------------------------------- 发送
  postInterested(): void {
    const m = new Uint8Array(5);
    BtUtil.putBe32(m, 0, 1);
    m[4] = 2;
    this.post(m);
  }

  postRequest(index: number, begin: number, len: number): void {
    const m = new Uint8Array(17);
    BtUtil.putBe32(m, 0, 13);
    m[4] = MSG_REQUEST;
    BtUtil.putBe32(m, 5, index);
    BtUtil.putBe32(m, 9, begin);
    BtUtil.putBe32(m, 13, len);
    this.post(m);
  }

  /** 请求第 piece 片元数据(发往对端声明的扩展 id) */
  postMetadataRequest(piece: number): void {
    if (this.extUtMetadataId <= 0) {
      return;
    }
    const d = new Map<string, BNode>();
    d.set('msg_type', BNode.intValue(0));
    d.set('piece', BNode.intValue(piece));
    this.postExt(this.extUtMetadataId, Bencode.encode(BNode.dictValue(d)));
  }

  private postExt(extId: number, body: Uint8Array): void {
    // 帧长度 = 1(msg id) + 1(ext id) + body;历史上最容易少算的就是这个 +2
    const m = new Uint8Array(6 + body.length);
    BtUtil.putBe32(m, 0, 2 + body.length);
    m[4] = MSG_EXT;
    m[5] = extId;
    m.set(body, 6);
    this.post(m);
  }

  /** 我方扩展握手:声明 ut_metadata=1(本端接收 id)、reqq、客户端名 */
  private buildExtHandshake(): Uint8Array {
    const m = new Map<string, BNode>();
    m.set('ut_metadata', BNode.intValue(1));
    const d = new Map<string, BNode>();
    d.set('m', BNode.dictValue(m));
    d.set('reqq', BNode.intValue(200));
    d.set('v', BNode.stringValue('ani0'));
    const body = Bencode.encode(BNode.dictValue(d));
    const out = new Uint8Array(6 + body.length);
    BtUtil.putBe32(out, 0, 2 + body.length);
    out[4] = MSG_EXT;
    out[5] = 0;
    out.set(body, 6);
    return out;
  }

  private buildHandshake(): Uint8Array {
    const m = new Uint8Array(68);
    m[0] = 19;
    for (let i = 0; i < PROTO.length; i++) {
      m[1 + i] = PROTO.charCodeAt(i);
    }
    m[25] = 0x10; // reserved[5] |= 0x10:扩展协议(BEP 10)
    m.set(this.infoHash, 28);
    m.set(this.peerId, 48);
    return m;
  }

  private post(bytes: Uint8Array): void {
    this.sock.send({ data: BtUtil.toAb(bytes) }).catch((e: Object) => {
      this.close('send-fail');
    });
  }

  // ---------------------------------------------------------------- 接收
  private onChunk(chunk: Uint8Array): void {
    this.buf = this.buf.length === 0 ? chunk : BtUtil.concat([this.buf, chunk]);
    this.pump();
  }

  private pump(): void {
    for (;;) {
      if (this.closed) {
        return;
      }
      if (!this.handshakeDone) {
        if (this.buf.length < 1) {
          return;
        }
        const hl = 49 + this.buf[0];
        if (this.buf.length < hl) {
          return;
        }
        let protoOk = this.buf[0] === 19;
        if (protoOk) {
          for (let i = 0; i < PROTO.length; i++) {
            if (this.buf[1 + i] !== PROTO.charCodeAt(i)) {
              protoOk = false;
              break;
            }
          }
        }
        let hashOk = protoOk;
        if (hashOk) {
          for (let i = 0; i < 20; i++) {
            if (this.buf[28 + i] !== this.infoHash[i]) {
              hashOk = false;
              break;
            }
          }
        }
        this.stats.handshake = protoOk;
        this.stats.hashMatched = hashOk;
        if (!hashOk) {
          this.close('handshake mismatch');
          return;
        }
        this.buf = this.buf.slice(hl);
        this.handshakeDone = true;
        if (this.hooks.onHandshakeDone !== undefined) {
          this.hooks.onHandshakeDone(this);
        }
        continue;
      }
      if (this.buf.length < 4) {
        return;
      }
      const len = BtUtil.readBe32(this.buf, 0);
      if (len === 0) {
        this.buf = this.buf.slice(4); // keep-alive
        continue;
      }
      if (len > 4 * 1024 * 1024) {
        this.close('oversize frame');
        return;
      }
      if (this.buf.length < 4 + len) {
        return;
      }
      const id = this.buf[4];
      const payload = this.buf.slice(5, 4 + len);
      this.buf = this.buf.slice(4 + len);
      this.handleMsg(id, payload);
    }
  }

  private handleMsg(id: number, payload: Uint8Array): void {
    if (id === MSG_CHOKE) {
      this.stats.unchoked = false;
      this.stats.chokeCount++;
    } else if (id === MSG_UNCHOKE) {
      this.stats.unchoked = true;
      if (this.hooks.onUnchoke !== undefined) {
        this.hooks.onUnchoke(this);
      }
    } else if (id === MSG_HAVE) {
      this.stats.haveCount++;
    } else if (id === MSG_BITFIELD) {
      this.stats.bitfieldPieces = BtUtil.countBits(payload);
    } else if (id === MSG_PIECE) {
      if (payload.length < 8) {
        return;
      }
      const index = BtUtil.readBe32(payload, 0);
      const begin = BtUtil.readBe32(payload, 4);
      const data = payload.slice(8);
      this.stats.dataBytes += data.length;
      if (this.hooks.onPieceBlock !== undefined) {
        this.hooks.onPieceBlock(index, begin, data);
      }
    } else if (id === MSG_EXT) {
      if (payload.length < 1) {
        return;
      }
      const eid = payload[0];
      const body = payload.slice(1);
      if (eid === 0) {
        this.handleExtHandshake(body);
      } else if (eid === this.extUtMetadataId && this.extUtMetadataId > 0) {
        this.handleMetadataMsg(body);
      }
    }
    // HAVE 细分序号 / DHT_PORT / PEX 等:诊断阶段不需要,忽略
  }

  private handleExtHandshake(body: Uint8Array): void {
    let root: BNode;
    try {
      root = Bencode.decode(body);
    } catch (e) {
      return;
    }
    if (root.kind !== BK_DICT) {
      return;
    }
    const v = root.get('v');
    if (v !== undefined && v.kind === BK_BYTES) {
      this.stats.client = v.asString();
    }
    const uo = root.get('upload_only');
    if (uo !== undefined && uo.kind === BK_INT && uo.intVal === 1) {
      this.stats.uploadOnly = true;
    }
    const ms = root.get('metadata_size');
    if (ms !== undefined && ms.kind === BK_INT) {
      this.stats.metadataSize = ms.intVal;
    }
    const m = root.get('m');
    if (m !== undefined && m.kind === BK_DICT) {
      const um = m.get('ut_metadata');
      if (um !== undefined && um.kind === BK_INT && um.intVal > 0) {
        this.extUtMetadataId = um.intVal;
        this.stats.supportsUtMeta = true;
      }
    }
    if (this.hooks.onExtHandshake !== undefined) {
      this.hooks.onExtHandshake(this);
    }
  }

  private handleMetadataMsg(body: Uint8Array): void {
    try {
      const res: BDecodeResult = Bencode.decodePrefix(body, 0);
      if (res.node.kind !== BK_DICT) {
        return;
      }
      const mt = res.node.get('msg_type');
      const pc = res.node.get('piece');
      if (mt === undefined || mt.kind !== BK_INT || pc === undefined || pc.kind !== BK_INT) {
        return;
      }
      if (mt.intVal !== 1) {
        return; // 0=request 2=reject
      }
      if (this.hooks.onMetadataData !== undefined) {
        this.hooks.onMetadataData(pc.intVal, body.slice(res.end));
      }
    } catch (e) {
      // 忽略无法解析的扩展消息
    }
  }
}
