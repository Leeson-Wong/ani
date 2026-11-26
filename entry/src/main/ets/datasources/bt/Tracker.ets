import { socket } from '@kit.NetworkKit';
import { url } from '@kit.ArkTS';
import { HttpClient } from '../http/HttpClient';
import { Bencode, BNode, BK_BYTES, BK_DICT, BK_INT, BK_LIST } from './Bencode';
import { BtUtil } from './BtUtil';
import { AppError } from '../../common/AppError';

export interface TrackerPeer {
  ip: string;
  port: number;
}

/** 一次 announce 的结果(ok=false 时 err 说明原因) */
export interface AnnounceResult {
  url: string;
  ok: boolean;
  err: string;
  peers: TrackerPeer[];
  seeders: number; // -1 = 未知
  leechers: number;
}

/**
 * tracker announce:BEP 3(HTTP/HTTPS,compact=1)与 BEP 15(UDP)。
 * wss:// 等 WebTorrent 信号服务器不支持,调用方应先过滤。
 */
export class Tracker {
  static async announce(trackerUrl: string, infoHash: Uint8Array, peerId: Uint8Array,
    left: number, timeoutMs: number): Promise<AnnounceResult> {
    if (/^udp:/i.test(trackerUrl)) {
      return Tracker.udpAnnounce(trackerUrl, infoHash, peerId, left, timeoutMs);
    }
    return Tracker.httpAnnounce(trackerUrl, infoHash, peerId, left, timeoutMs);
  }

  // ---------------------------------------------------------------- HTTP(S)
  private static async httpAnnounce(trackerUrl: string, infoHash: Uint8Array, peerId: Uint8Array,
    left: number, timeoutMs: number): Promise<AnnounceResult> {
    const res: AnnounceResult = {
      url: trackerUrl, ok: false, err: '', peers: [], seeders: -1, leechers: -1
    };
    let u: url.URL;
    try {
      u = new url.URL(trackerUrl);
    } catch (e) {
      res.err = 'bad url';
      return res;
    }
    const q = `info_hash=${BtUtil.pct(infoHash)}&peer_id=${BtUtil.pct(peerId)}&port=6881` +
      `&uploaded=0&downloaded=0&left=${left}&compact=1&numwant=80&event=started`;
    let full = `${u.protocol}//${u.host}${u.pathname}?${q}`;
    if (u.search.length > 1) {
      full += `&${u.search.substring(1)}`; // 保留原 URL 自带参数
    }
    let buf: Uint8Array;
    try {
      buf = await HttpClient.getBinary(full, { 'user-agent': 'Transmission/4.0.0' },
        { connectMs: Math.min(timeoutMs, 7000), readMs: timeoutMs, quiet: true });
    } catch (e) {
      res.err = AppError.from(e as Object).message;
      return res;
    }
    let root: BNode;
    try {
      root = Bencode.decode(buf);
    } catch (e) {
      res.err = '非 bencode 响应';
      return res;
    }
    if (root.kind !== BK_DICT) {
      res.err = '响应不是字典';
      return res;
    }
    const fail = root.get('failure reason');
    if (fail !== undefined && fail.kind === BK_BYTES) {
      res.err = fail.asString();
      return res;
    }
    const peersNode = root.get('peers');
    if (peersNode !== undefined && peersNode.kind === BK_BYTES) {
      res.peers = Tracker.compactPeers(peersNode.bytes);
    } else if (peersNode !== undefined && peersNode.kind === BK_LIST) {
      for (const raw of peersNode.list) {
        if (raw.kind !== BK_DICT) {
          continue;
        }
        const ipNode = raw.get('ip');
        const portNode = raw.get('port');
        if (ipNode !== undefined && ipNode.kind === BK_BYTES && portNode !== undefined && portNode.kind === BK_INT) {
          if (portNode.intVal > 0 && portNode.intVal < 65536) {
            const peer: TrackerPeer = { ip: ipNode.asString(), port: portNode.intVal };
            res.peers.push(peer);
          }
        }
      }
    }
    res.seeders = Tracker.intVal(root.get('complete'));
    res.leechers = Tracker.intVal(root.get('incomplete'));
    res.ok = true;
    return res;
  }

  // ---------------------------------------------------------------- UDP(BEP 15)
  private static udpAnnounce(trackerUrl: string, infoHash: Uint8Array, peerId: Uint8Array,
    left: number, timeoutMs: number): Promise<AnnounceResult> {
    return new Promise<AnnounceResult>((resolve) => {
      const res: AnnounceResult = {
        url: trackerUrl, ok: false, err: '', peers: [], seeders: -1, leechers: -1
      };
      let u: url.URL;
      try {
        u = new url.URL(trackerUrl);
      } catch (e) {
        res.err = 'bad url';
        resolve(res);
        return;
      }
      const host = u.hostname;
      const port = u.port.length > 0 ? Number(u.port) : 80;
      const sock = socket.constructUDPSocketInstance();
      const tx1 = Math.floor(Math.random() * 0x7ffffff0) + 1;
      const tx2 = tx1 + 1;
      let stage = 0;
      let settled = false;
      const timer = setTimeout(() => {
        finish('timeout');
      }, timeoutMs);
      const finish = (err: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        res.err = err;
        clearTimeout(timer);
        sock.off('message');
        sock.off('error');
        sock.close().catch(() => {
          // 已关闭
        });
        resolve(res);
      };
      sock.on('error', (err: Error) => {
        finish(`${err}`.substring(0, 60));
      });
      sock.on('message', (info: socket.SocketMessageInfo) => {
        const msg = new Uint8Array(info.message);
        if (msg.length < 8) {
          return;
        }
        const action = BtUtil.readBe32(msg, 0);
        const tx = BtUtil.readBe32(msg, 4);
        if (stage === 0 && action === 0 && tx === tx1 && msg.length >= 16) {
          const req = new Uint8Array(98);
          req.set(msg.slice(8, 16), 0); // connection_id 原样带回
          BtUtil.putBe32(req, 8, 1); // action = announce
          BtUtil.putBe32(req, 12, tx2);
          req.set(infoHash, 16);
          req.set(peerId, 36);
          BtUtil.putBe64(req, 56, 0); // downloaded
          BtUtil.putBe64(req, 64, left); // left
          BtUtil.putBe64(req, 72, 0); // uploaded
          BtUtil.putBe32(req, 80, 2); // event = started
          BtUtil.putBe32(req, 84, 0); // ip
          BtUtil.putBe32(req, 88, Math.floor(Math.random() * 0x7fffffff)); // key
          BtUtil.putBe32(req, 92, 80); // num_want
          BtUtil.putBe16(req, 96, 6881); // port
          stage = 1;
          sock.send({ data: BtUtil.toAb(req), address: { address: host, port: port } }).catch((e: Object) => {
            finish('udp send fail');
          });
        } else if (tx === tx2 && action === 1 && msg.length >= 20) {
          res.ok = true;
          res.err = '';
          res.leechers = BtUtil.readBe32(msg, 12);
          res.seeders = BtUtil.readBe32(msg, 16);
          res.peers = Tracker.compactPeers(msg.slice(20));
          finish('');
        } else if (tx === tx2 && action === 3) {
          finish(`tracker:${BtUtil.ascStr(msg, 8)}`);
        }
      });
      const conn = new Uint8Array(16);
      BtUtil.putBe64(conn, 0, 0x41727101980); // magic
      BtUtil.putBe32(conn, 8, 0); // action = connect
      BtUtil.putBe32(conn, 12, tx1);
      const localPort = 20000 + Math.floor(Math.random() * 30000);
      sock.bind({ address: '0.0.0.0', port: localPort }).then((): Promise<void> => {
        return sock.send({ data: BtUtil.toAb(conn), address: { address: host, port: port } });
      }).catch((e: Object) => {
        finish('udp bind/send fail');
      });
    });
  }

  // ---------------------------------------------------------------- 共用
  /** compact peers:每 6 字节一组(4 字节 IPv4 + 2 字节端口) */
  private static compactPeers(buf: Uint8Array): TrackerPeer[] {
    const out: TrackerPeer[] = [];
    for (let i = 0; i + 6 <= buf.length; i += 6) {
      const ip = `${buf[i]}.${buf[i + 1]}.${buf[i + 2]}.${buf[i + 3]}`;
      const port = BtUtil.readBe16(buf, i + 4);
      if (port > 0 && port < 65536) {
        const peer: TrackerPeer = { ip: ip, port: port };
        out.push(peer);
      }
    }
    return out;
  }

  private static intVal(node: BNode | undefined): number {
    if (node === undefined || node.kind !== BK_INT) {
      return -1;
    }
    return node.intVal;
  }
}
