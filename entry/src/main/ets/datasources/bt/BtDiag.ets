import { HttpClient } from '../http/HttpClient';
import { GardenClient, GardenDetail } from '../garden/GardenClient';
import { GardenResource } from '../../models/garden/GardenModels';
import { FALLBACK_TRACKERS, MagnetInfo, parseMagnet } from './Magnet';
import { PeerStats, PeerWire, PeerWireHooks } from './PeerWire';
import { TorrentFile, TorrentFileEntry, TorrentMeta } from './TorrentFile';
import { AnnounceResult, Tracker, TrackerPeer } from './Tracker';
import { BtUtil } from './BtUtil';

/** 诊断行:label 概括该步结果,detail 为多行明细 */
export interface DiagLine {
  id: number;
  label: string;
  state: string; // run | ok | fail | info | warn
  detail: string;
}

export interface DiagOptions {
  wantData: boolean; // 是否做吞吐实测(每个被测 peer ≤1MiB 流量)
  maxPeers: number; // 最多探测的 peer 数
}

/** 跨 peer 共享的 ut_metadata 装配状态(多 peer 并行补片) */
interface MetaShared {
  size: number;
  pieces: Map<number, Uint8Array>;
  meta: TorrentMeta | null;
  verifying: boolean;
  done: boolean;
}

const META_PIECE = 16384;
const MAX_META_SIZE = 2 * 1024 * 1024; // 超大元数据(几百上千文件)不拉,防卡

/**
 * BT 链路诊断(真机技术验证入口):磁力 → AnimeGarden 详情(.torrent 直链)→
 * 元数据(.torrent 下载校验,失败转 ut_metadata)→ tracker announce(HTTP/UDP)→
 * peer 并行握手 → 最优 peer 吞吐实测(piece 0 前 ≤1MiB)。
 * 结果按固定 id 的 DiagLine 流式回调,页面逐步渲染。
 */
export class BtDiag {
  /** 诊断行 id */
  static readonly L_INPUT = 0;
  static readonly L_DETAIL = 1;
  static readonly L_META = 2;
  static readonly L_TRACKER = 3;
  static readonly L_PEER = 4;
  static readonly L_SPEED = 5;
  static readonly L_SUM = 6;

  static async run(inputRaw: string, opts: DiagOptions, emit: (line: DiagLine) => void): Promise<void> {
    const t0 = Date.now();
    const peerId = BtUtil.randomPeerId();
    const L = (id: number, label: string, state: string, detail: string): void => {
      const line: DiagLine = { id: id, label: label, state: state, detail: detail };
      emit(line);
    };
    const failAll = (msg: string): void => {
      L(BtDiag.L_SUM, '结论', 'fail', `总耗时 ${BtDiag.since(t0)}s\n${msg}`);
    };

    // ── ① 输入:magnet / 40 位 infohash / 空 = 自动取最新 v1 ──
    let input = inputRaw.trim();
    L(BtDiag.L_INPUT, '输入解析', 'run', '');
    if (input.length === 0) {
      L(BtDiag.L_INPUT, '输入解析', 'run', '未指定资源,取 AnimeGarden 最新 v1 资源…');
      try {
        const list = await GardenClient.resources('', 1, 20);
        let picked: GardenResource | null = null;
        for (const r of list) {
          const m = parseMagnet(r.magnet);
          if (m !== undefined && m.infoHash.length === 20) {
            picked = r;
            input = r.magnet;
            break;
          }
        }
        if (picked === null) {
          L(BtDiag.L_INPUT, '输入解析', 'fail', '最新列表里没有 v1(hex btih)磁力资源');
          failAll('无可用输入');
          return;
        }
        L(BtDiag.L_INPUT, '输入解析', 'ok', `自动选取:${picked.title}`);
      } catch (e) {
        L(BtDiag.L_INPUT, '输入解析', 'fail', `AnimeGarden 列表失败:${e}`);
        failAll('拿不到测试资源');
        return;
      }
    }
    let mag: MagnetInfo | undefined = undefined;
    if (input.startsWith('magnet:')) {
      mag = parseMagnet(input);
    } else if (/^[0-9a-fA-F]{40}$/.test(input)) {
      mag = parseMagnet(`magnet:?xt=urn:btih:${input.toLowerCase()}`);
    }
    if (mag === undefined || mag.infoHash.length !== 20) {
      if (mag !== undefined && mag.v2HashHex.length > 0) {
        L(BtDiag.L_INPUT, '输入解析', 'fail',
          `该资源只有 v2 infohash(btmh:${mag.v2HashHex.substring(0, 16)}…),纯 v1 内核暂不支持`);
      } else {
        L(BtDiag.L_INPUT, '输入解析', 'fail', '无法解析输入:需要 magnet 链接或 40 位 v1 infohash');
      }
      failAll('输入不可用');
      return;
    }
    L(BtDiag.L_INPUT, '输入解析', 'ok',
      `infohash=${mag.infoHashHex}` +
      `${mag.displayName.length > 0 ? `\n名称:${mag.displayName}` : ''}` +
      `\n磁力自带 tracker ${mag.trackers.length} 个`);
    const hash = mag.infoHash;

    // ── ② AnimeGarden 详情:.torrent 直链 + 完整 tracker ──
    L(BtDiag.L_DETAIL, 'AnimeGarden 详情', 'run', '查询 .torrent 直链与完整 tracker…');
    let torrentUrl = '';
    let fullMagnet = input;
    try {
      const d: GardenDetail = await GardenClient.detailByInfohash(mag.infoHashHex);
      torrentUrl = d.torrentUrl;
      if (d.fullMagnet.length > 0) {
        fullMagnet = d.fullMagnet;
      }
      const dm = parseMagnet(d.fullMagnet);
      L(BtDiag.L_DETAIL, 'AnimeGarden 详情', 'ok',
        `${d.title}\n.torrent 直链:${torrentUrl.length > 0 ? BtDiag.hostOf(torrentUrl) : '无'};` +
        `详情磁力 tracker ${dm !== undefined ? dm.trackers.length : 0} 个`);
    } catch (e) {
      L(BtDiag.L_DETAIL, 'AnimeGarden 详情', 'warn', `详情接口不可达(${e});只用磁力自带 tracker + 内置兜底`);
    }
    const magFull = parseMagnet(fullMagnet) ?? mag;

    // ── ③ 元数据:第一级 .torrent(HTTPS),失败转 ut_metadata ──
    L(BtDiag.L_META, '元数据', 'run', '');
    let meta: TorrentMeta | null = null;
    if (torrentUrl.length > 0) {
      L(BtDiag.L_META, '元数据', 'run', `下载 .torrent(${BtDiag.hostOf(torrentUrl)})…`);
      try {
        const buf = await HttpClient.getBinary(torrentUrl, { 'user-agent': 'Transmission/4.0.0' },
          { connectMs: 6000, readMs: 20000, quiet: true });
        meta = await TorrentFile.parse(buf, hash);
        L(BtDiag.L_META, '元数据', 'ok', BtDiag.describeMeta(meta, '.torrent(HTTPS)'));
      } catch (e) {
        L(BtDiag.L_META, '元数据', 'warn', `.torrent 下载或校验失败(${e});改走 ut_metadata`);
      }
    } else {
      L(BtDiag.L_META, '元数据', 'info', '详情里没有 .torrent 直链,元数据走 ut_metadata(向 peer 要)');
    }

    // ── ④ tracker announce(HTTP/HTTPS/UDP 并行)──
    L(BtDiag.L_TRACKER, 'Tracker announce', 'run', '并行探测…');
    const seen = new Set<string>();
    const allTrackers: string[] = [];
    const pushTr = (u: string): void => {
      const t = u.trim();
      if (t.length > 0 && !seen.has(t) && /^(https?|udp):/i.test(t)) {
        seen.add(t);
        allTrackers.push(t);
      }
    };
    for (const t of magFull.trackers) {
      pushTr(t);
    }
    if (meta !== null) {
      for (const t of meta.trackers) {
        pushTr(t);
      }
    }
    if (allTrackers.length === 0) {
      for (const t of FALLBACK_TRACKERS) {
        pushTr(t);
      }
      L(BtDiag.L_TRACKER, 'Tracker announce', 'run', '磁力与种子均无可用 tracker,补内置兜底');
    }
    const left = meta !== null ? meta.totalLength : 0;
    const results: AnnounceResult[] = await Promise.all(allTrackers.map((u: string) =>
      Tracker.announce(u, hash, peerId, left, u.startsWith('udp') ? 6000 : 9000)));
    const peerMap = new Map<string, TrackerPeer>();
    let okTrackers = 0;
    const tLines: string[] = [];
    for (const r of results) {
      const label = BtDiag.shortTracker(r.url);
      if (r.ok) {
        okTrackers++;
        tLines.push(`✓ ${label}  peers=${r.peers.length}  seed=${r.seeders} leech=${r.leechers}`);
      } else {
        tLines.push(`✗ ${label}  ${r.err}`);
      }
      for (const p of r.peers) {
        const key = `${p.ip}:${p.port}`;
        if (!peerMap.has(key) && BtUtil.isPublicIpv4(p.ip) && p.port > 0) {
          peerMap.set(key, p);
        }
      }
    }
    const peersAll = Array.from(peerMap.values());
    L(BtDiag.L_TRACKER, `Tracker announce(可用 ${okTrackers}/${allTrackers.length},公网 peer ${peersAll.length})`,
      peersAll.length > 0 ? 'ok' : 'fail', tLines.join('\n'));
    if (peersAll.length === 0) {
      failAll('tracker 没有给出任何公网 peer(本轮未做 DHT);换资源或稍后重试');
      return;
    }

    // ── ⑤ peer 并行握手(+ ut_metadata 兜底装配)──
    const shared: MetaShared | null = meta === null
      ? { size: 0, pieces: new Map<number, Uint8Array>(), meta: null, verifying: false, done: false }
      : null;
    const picked = BtDiag.shufflePick(peersAll, opts.maxPeers);
    L(BtDiag.L_PEER, `Peer 探测(${picked.length}/${peersAll.length})`, 'run', '并行握手…');
    const pws: PeerWire[] = await Promise.all(picked.map((p: TrackerPeer) =>
      BtDiag.probePeer(p, hash, peerId, shared, 15000)));
    let handshaked = 0;
    let seeders = 0;
    let utmetaCount = 0;
    const clients = new Map<string, number>();
    const pLines: string[] = [];
    for (const pw of pws) {
      const s = pw.stats;
      if (s.hashMatched) {
        handshaked++;
        if (s.uploadOnly) {
          seeders++;
        }
        if (s.supportsUtMeta) {
          utmetaCount++;
        }
        const c = s.client.length > 0 ? s.client : '?';
        clients.set(c, (clients.get(c) ?? 0) + 1);
      }
      pLines.push(BtDiag.describePeer(s));
    }
    L(BtDiag.L_PEER, `Peer 探测(握手 ${handshaked}/${picked.length},做种 ${seeders},支持元数据 ${utmetaCount})`,
      handshaked > 0 ? 'ok' : 'fail', pLines.join('\n'));
    // ut_metadata 兜底结果收口(verify 异步,给一点收敛时间)
    if (shared !== null && !shared.done && shared.pieces.size > 0) {
      await BtDiag.sleep(600);
    }
    if (shared !== null && shared.done && shared.meta !== null) {
      meta = shared.meta;
      L(BtDiag.L_META, '元数据', 'ok', BtDiag.describeMeta(meta, 'ut_metadata(peer 扩展协议)'));
    }
    if (meta === null) {
      L(BtDiag.L_META, '元数据', 'fail', '两级元数据(.torrent / ut_metadata)都失败,无法下载与测速');
      failAll(`拿不到元数据${handshaked > 0 ? '(peer 不支持 ut_metadata 或未回应)' : '(无可达 peer)'}`);
      return;
    }

    // ── ⑥ 吞吐实测:重连最优 peer,请求 piece 0 前 ≤1MiB ──
    const kbpsAll: number[] = [];
    if (!opts.wantData) {
      L(BtDiag.L_SPEED, '吞吐实测', 'info', '未开启');
    } else {
      const cands = pws
        .filter((pw: PeerWire) => pw.stats.hashMatched &&
          (pw.stats.uploadOnly || pw.stats.bitfieldPieces > 0 || pw.stats.haveCount > 0))
        .sort((a: PeerWire, b: PeerWire) =>
          ((b.stats.uploadOnly ? 1 : 0) - (a.stats.uploadOnly ? 1 : 0)) ||
          (b.stats.bitfieldPieces - a.stats.bitfieldPieces))
        .slice(0, 3);
      if (cands.length === 0) {
        L(BtDiag.L_SPEED, '吞吐实测', 'warn', '没有可下数据的 peer(无 bitfield/做种标记)');
      } else {
        L(BtDiag.L_SPEED, '吞吐实测', 'run', `重连最优 ${cands.length} 个 peer,各请求 piece 0 前 ≤1MiB…`);
        const metaOk: TorrentMeta = meta;
        const speeds = await Promise.all(cands.map((pw: PeerWire) =>
          BtDiag.speedProbe(pw.stats.ip, pw.stats.port, hash, peerId, metaOk, 30000)));
        const sLines: string[] = [];
        for (const pw of speeds) {
          const s = pw.stats;
          if (s.dataBytes > 0) {
            const k = s.dataMs > 0 ? Math.round(s.dataBytes / 1024 / (s.dataMs / 1000)) : 0;
            kbpsAll.push(k);
            sLines.push(`✓ ${s.ip}:${s.port}  ${BtDiag.fmtBytes(s.dataBytes)} 用时 ${(s.dataMs / 1000).toFixed(1)}s` +
              `${s.firstBlockMs > 0 ? ` 首块 ${s.firstBlockMs}ms` : ''} ≈ ${k} KB/s`);
          } else {
            sLines.push(`✗ ${s.ip}:${s.port}  未给出数据(${s.why})`);
          }
        }
        L(BtDiag.L_SPEED, '吞吐实测', kbpsAll.length > 0 ? 'ok' : 'warn', sLines.join('\n'));
      }
    }

    // ── ⑦ 结论 ──
    let verdict = '';
    let vState = 'info';
    if (kbpsAll.length > 0) {
      const sorted = kbpsAll.slice().sort((a: number, b: number) => a - b);
      const median = sorted[Math.floor(sorted.length / 2)];
      const top = sorted[sorted.length - 1];
      if (median >= 300) {
        verdict = `✓ 可下载:中位 ${median} KB/s / 最高 ${top} KB/s(≥300 KB/s 够 1080p 边下边播)`;
        vState = 'ok';
      } else {
        verdict = `⚠ 速度偏慢:中位 ${median} KB/s / 最高 ${top} KB/s,边下边播可能卡顿`;
        vState = 'warn';
      }
    } else if (handshaked > 0) {
      verdict = '⚠ 有握手成功的 peer 但未给出数据(候选里多监测节点/下载者,或都太慢)';
      vState = 'warn';
    } else {
      verdict = '✗ 无有效握手:该资源当前没有可达做种者(换资源或稍后重试)';
    }
    L(BtDiag.L_SUM, '结论', vState,
      `总耗时 ${BtDiag.since(t0)}s\n${verdict}\n元数据:${meta.name}(${BtDiag.fmtBytes(meta.totalLength)},` +
      `${meta.pieceCount} pieces,${meta.files.length} 个文件)`);
  }

  // ================================================================ 内部实现

  /** 阶段⑤:单个 peer 握手探测;shared 非空时顺带拉 ut_metadata */
  private static async probePeer(peer: TrackerPeer, hash: Uint8Array, peerId: Uint8Array,
    shared: MetaShared | null, timeoutMs: number): Promise<PeerWire> {
    const hooks: PeerWireHooks = {};
    const pw = new PeerWire(peer.ip, peer.port, hash, peerId, hooks, true);
    if (shared !== null) {
      hooks.onExtHandshake = (p: PeerWire) => {
        if (shared.done || p.extUtMetadataId <= 0) {
          return;
        }
        const size = p.stats.metadataSize;
        if (size <= 0 || size > MAX_META_SIZE) {
          return;
        }
        shared.size = size;
        const total = Math.ceil(size / META_PIECE);
        for (let i = 0; i < total; i++) {
          p.postMetadataRequest(i);
        }
      };
      hooks.onMetadataData = (piece: number, data: Uint8Array) => {
        if (shared.done || shared.size <= 0 || shared.pieces.has(piece)) {
          return;
        }
        shared.pieces.set(piece, data);
        if (shared.pieces.size >= Math.ceil(shared.size / META_PIECE)) {
          BtDiag.verifyMeta(shared, hash);
        }
      };
    }
    await pw.start(timeoutMs);
    return pw;
  }

  /** ut_metadata 装配 + SHA1 校验(坏片清空待后续块重试;单飞防并发) */
  private static async verifyMeta(shared: MetaShared, hash: Uint8Array): Promise<void> {
    if (shared.verifying || shared.done) {
      return;
    }
    shared.verifying = true;
    try {
      const total = Math.ceil(shared.size / META_PIECE);
      const parts: Uint8Array[] = [];
      for (let i = 0; i < total; i++) {
        const b = shared.pieces.get(i);
        if (b === undefined) {
          shared.verifying = false;
          return;
        }
        parts.push(b);
      }
      const infoBuf = BtUtil.concat(parts).slice(0, shared.size);
      const m = await TorrentFile.fromInfo(infoBuf, hash);
      shared.meta = m;
      shared.done = true;
    } catch (e) {
      shared.pieces.clear();
    }
    shared.verifying = false;
  }

  /** 阶段⑥:吞吐实测 —— interested → unchoke 后请求 piece 0 的前 ≤64 块(每块 16KiB) */
  private static async speedProbe(ip: string, port: number, hash: Uint8Array, peerId: Uint8Array,
    meta: TorrentMeta, timeoutMs: number): Promise<PeerWire> {
    const BLOCK = 16384;
    const nBlocks = Math.min(64, Math.max(1, Math.ceil(meta.pieceLength / BLOCK)));
    let sent = false;
    let got = 0;
    let reqAt = 0;
    const hooks: PeerWireHooks = {};
    const pw = new PeerWire(ip, port, hash, peerId, hooks, false);
    hooks.onHandshakeDone = (p: PeerWire) => {
      p.postInterested();
    };
    hooks.onUnchoke = (p: PeerWire) => {
      if (sent) {
        return;
      }
      sent = true;
      reqAt = Date.now();
      for (let i = 0; i < nBlocks; i++) {
        const begin = i * BLOCK;
        const len = Math.min(BLOCK, meta.pieceLength - begin);
        if (len <= 0) {
          break;
        }
        p.postRequest(0, begin, len);
      }
    };
    hooks.onPieceBlock = (index: number, begin: number, data: Uint8Array) => {
      if (reqAt <= 0) {
        return;
      }
      if (pw.stats.firstBlockMs === 0) {
        pw.stats.firstBlockMs = Date.now() - reqAt;
      }
      got++;
      if (got >= nBlocks) {
        pw.stats.dataMs = Date.now() - reqAt;
        pw.close('data-ok');
      }
    };
    await pw.start(timeoutMs);
    return pw;
  }

  private static shufflePick(arr: TrackerPeer[], n: number): TrackerPeer[] {
    const a = arr.slice();
    for (let i = a.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      const t = a[i];
      a[i] = a[j];
      a[j] = t;
    }
    return a.slice(0, Math.min(n, a.length));
  }

  // ================================================================ 展示辅助

  private static describeMeta(meta: TorrentMeta, from: string): string {
    const fileLine = (f: TorrentFileEntry): string => `  ${f.path}(${BtDiag.fmtBytes(f.length)})`;
    let filesBlock = '';
    if (meta.files.length <= 4) {
      for (const f of meta.files) {
        filesBlock += `\n${fileLine(f)}`;
      }
    } else {
      for (const f of meta.files.slice(0, 3)) {
        filesBlock += `\n${fileLine(f)}`;
      }
      filesBlock += `\n  … 共 ${meta.files.length} 个文件`;
    }
    return `来源:${from}\n${meta.name}  ${BtDiag.fmtBytes(meta.totalLength)}` +
      ` / ${meta.pieceCount} pieces × ${BtDiag.fmtBytes(meta.pieceLength)}` +
      `${meta.isPrivate ? ' [私有]' : ''}${meta.isV2 ? ' [含v2字段]' : ''}${filesBlock}`;
  }

  private static describePeer(s: PeerStats): string {
    const head = `${s.connected ? (s.hashMatched ? '✓' : '○') : '·'} ${s.ip}:${s.port}`;
    if (!s.connected) {
      return `${head}  连接失败(${s.why})`;
    }
    if (!s.hashMatched) {
      return `${head}  无有效握手(${s.why})`;
    }
    const bits: string[] = [];
    if (s.client.length > 0) {
      bits.push(s.client);
    }
    if (s.uploadOnly) {
      bits.push('做种');
    }
    if (s.bitfieldPieces >= 0) {
      bits.push(`bf=${s.bitfieldPieces}`);
    }
    if (s.haveCount > 0) {
      bits.push(`have×${s.haveCount}`);
    }
    if (s.unchoked) {
      bits.push('已放行');
    } else if (s.chokeCount > 0) {
      bits.push(`choke×${s.chokeCount}`);
    }
    bits.push(`→${s.why}`);
    return `${head}  ${bits.join(' ')}`;
  }

  private static hostOf(u: string): string {
    const m = /^https?:\/\/([^/]+)/.exec(u);
    return m !== null ? m[1] : u;
  }

  private static shortTracker(u: string): string {
    const m = /^(https?|udp):\/\/([^/]+)\//.exec(u);
    return m !== null ? `${m[1]}://${m[2]}` : u;
  }

  private static fmtBytes(n: number): string {
    if (n >= 1024 * 1024 * 1024) {
      return `${(n / 1024 / 1024 / 1024).toFixed(2)}GB`;
    }
    if (n >= 1024 * 1024) {
      return `${(n / 1024 / 1024).toFixed(1)}MB`;
    }
    return `${Math.round(n / 1024)}KB`;
  }

  private static since(t0: number): string {
    return `${((Date.now() - t0) / 1000).toFixed(1)}`;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}
