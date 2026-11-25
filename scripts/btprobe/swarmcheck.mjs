// BT 可行性复核(修正版):元数据 + peer 发现 + 握手 + ut_metadata + 首块数据吞吐
//
// 用法:
//   node scripts/btprobe/swarmcheck.mjs                      # 自动取 AnimeGarden 最新一个 v1 资源
//   node scripts/btprobe/swarmcheck.mjs <magnet|infohash>    # 指定资源
//   选项: --data          向未 choke 的 peer 请求 piece 0 的首个 ≤1MB,实测吞吐
//         --dht           追加 DHT(BEP 5) get_peers,评估无 tracker 时的 peer 发现
//         --peers=40      最多探测的 peer 数
//         --ext           发送我方的扩展握手 + ut_metadata 取元数据(dmhy 等拿不到 .torrent 时用)
//         --no-torrent    不走 HTTPS 取 .torrent,强制用 peer 的 ut_metadata 取元数据(需配合 --ext)
//         --torrent=URL   直接指定 .torrent(测任意公开种子,不走 AnimeGarden)
//
// 与旧脚本(debug2/fullprobe)的差别:
//   1. 协议消息 id 按规范解析:0=CHOKE 1=UNCHOKE 2=INTERESTED 3=NOT_INTERESTED
//      4=HAVE 5=BITFIELD 6=REQUEST 7=PIECE 8=CANCEL 9=DHT_PORT 20=EXT
//      (旧脚本把 1 标成 CHOKE、5 标成 UNCHOKE,结论相反)
//   2. 扩展握手里的 upload_only=1 表示对方是「做种者/已下完」,不是吸血节点
//   3. 用资源自带的 tracker(detail.magnets 里的完整磁力),而不是只问两个公共 tracker
//   4. 元数据优先走 HTTPS 下 .torrent(AnimeGarden detail 提供),ut_metadata 只做兜底并校验 SHA1
//   5. 支持 UDP tracker(BEP 15)与 DHT
//   6. 修正扩展消息长度前缀(旧脚本少算 1 字节)。旧脚本「发完扩展握手/ut_metadata 请求后连接被断、
//      拿不到 metadata」正是这个 framing bug 导致的,与 peer 是否 choke 无关
//   7. 默认不发送我方的扩展握手:元数据已由 .torrent 取得时不必要,少发少错;需要 ut_metadata 兜底时加 --ext

import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import dgram from 'node:dgram';
import crypto from 'node:crypto';

const argv = process.argv.slice(2);
const FLAGS = new Set(argv.filter((a) => a.startsWith('--')));
const WANT_DATA = FLAGS.has('--data');
const WANT_DHT = FLAGS.has('--dht');
const WANT_EXT = FLAGS.has('--ext');
const TORRENT_URL = (argv.find((a) => a.startsWith('--torrent=')) || '').slice('--torrent='.length);
const NO_TORRENT = FLAGS.has('--no-torrent');
const MAX_PEERS = Number((argv.find((a) => a.startsWith('--peers=')) || '--peers=40').split('=')[1]);
const target = argv.find((a) => !a.startsWith('--')) || '';

const UA = 'Transmission/4.0.0';
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const META_PIECE = 16384;
const DATA_BLOCK = 16384;
const DATA_BLOCKS = 64; // 64 × 16KiB = 1MiB
const now = () => Date.now();

const PEER_ID = Buffer.from(`-AN0001-${crypto.randomInt(0, 1e12).toString().padStart(12, '0')}`, 'latin1');

// ---------------------------------------------------------------- 基础工具
function pct(buf) {
  let s = '';
  for (const b of buf) s += '%' + b.toString(16).padStart(2, '0');
  return s;
}

const hex = (b) => Buffer.from(b).toString('hex');

function fmtBytes(n) {
  if (n >= 1 << 30) return `${(n / (1 << 30)).toFixed(2)}GB`;
  if (n >= 1 << 20) return `${(n / (1 << 20)).toFixed(1)}MB`;
  return `${(n / 1024).toFixed(0)}KB`;
}

function isPublicIpv4(ip) {
  const m = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(ip);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  if (a === 169 && b === 254) return false;
  if (a === 100 && b >= 64 && b <= 127) return false;
  return true;
}

/** bencode 解码,返回 [值, 下一个偏移]。字节串用 Buffer,整数用 Number。 */
function bdec(buf, pos = 0) {
  const c = buf[pos];
  if (c === 0x69) {
    const e = buf.indexOf(0x65, pos);
    if (e < 0) throw new Error('bencode: int 无终止');
    return [Number(buf.toString('latin1', pos + 1, e)), e + 1];
  }
  if (c === 0x6c) {
    const arr = [];
    let p = pos + 1;
    while (buf[p] !== 0x65) {
      const [v, np] = bdec(buf, p);
      arr.push(v);
      p = np;
    }
    return [arr, p + 1];
  }
  if (c === 0x64) {
    const obj = {};
    let p = pos + 1;
    while (buf[p] !== 0x65) {
      const [k, p2] = bdec(buf, p);
      const [v, p3] = bdec(buf, p2);
      obj[k.toString('latin1')] = v;
      p = p3;
    }
    return [obj, p + 1];
  }
  const colon = buf.indexOf(0x3a, pos);
  const len = Number(buf.toString('latin1', pos, colon));
  const start = colon + 1;
  if (start + len > buf.length) throw new Error('bencode: 字节串越界');
  return [buf.subarray(start, start + len), start + len];
}

/** 解析 .torrent,并记下 info 字典的原始字节区间(算 infoHash 用) */
function parseTorrent(buf) {
  if (buf[0] !== 0x64) throw new Error('torrent 顶层不是字典');
  const root = {};
  let p = 1;
  let infoStart = -1;
  let infoEnd = -1;
  while (buf[p] !== 0x65) {
    const [k, p2] = bdec(buf, p);
    const key = k.toString('latin1');
    const [v, p3] = bdec(buf, p2);
    if (key === 'info') {
      infoStart = p2;
      infoEnd = p3;
    }
    root[key] = v;
    p = p3;
  }
  const info = root.info;
  const files = [];
  if (info.files) {
    for (const f of info.files) files.push({ path: f.path.map((x) => x.toString('utf8')).join('/'), length: Number(f.length) });
  } else {
    files.push({ path: info.name.toString('utf8'), length: Number(info.length) });
  }
  const total = files.reduce((s, f) => s + f.length, 0);
  const trackers = new Set();
  if (root.announce) trackers.add(root.announce.toString('utf8'));
  if (Array.isArray(root['announce-list'])) {
    for (const tier of root['announce-list']) for (const t of tier) trackers.add(t.toString('utf8'));
  }
  return {
    root,
    infoBytes: buf.subarray(infoStart, infoEnd),
    name: info.name.toString('utf8'),
    pieceLength: Number(info['piece length']),
    pieceCount: Math.floor(info.pieces.length / 20),
    files,
    totalLength: total,
    isPrivate: Number(info.private || 0) === 1,
    isV2: info['meta version'] !== undefined,
    trackers: [...trackers]
  };
}

function parseMagnet(magnet) {
  const info = { hash: null, hashV2Hex: '', trackers: [], name: '' };
  const q = magnet.indexOf('?');
  if (q < 0) return info;
  for (const part of magnet.slice(q + 1).split('&')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    const k = decodeURIComponent(part.slice(0, i)).toLowerCase();
    let v = part.slice(i + 1);
    try { v = decodeURIComponent(v); } catch { /* 保留原值 */ }
    if (k === 'xt') {
      const m = /^urn:(btih|btmh):([A-Za-z0-9]+)$/.exec(v);
      if (!m) continue;
      const raw = m[2];
      if (m[1] === 'btmh' && /^[0-9a-f]{64}$/i.test(raw)) {
        info.hashV2Hex = raw.toLowerCase(); // BitTorrent v2 完整 infohash
      } else if (m[1] === 'btih' && /^[0-9a-f]{40}$/i.test(raw)) {
        info.hash = Buffer.from(raw, 'hex'); // v1
      } else if (m[1] === 'btih' && /^[A-Za-z2-7]{32}$/.test(raw)) {
        // base32:可能是 v1 的 base32 写法,也可能是 v2 的 sha256 截断。无法仅凭写法区分,先按 20 字节解出
        let bits = '';
        for (const c of raw.toUpperCase()) bits += B32.indexOf(c).toString(2).padStart(5, '0');
        const b = Buffer.alloc(20);
        for (let j = 0; j < 20; j++) b[j] = parseInt(bits.slice(j * 8, j * 8 + 8), 2);
        info.hash = b;
      }
    } else if (k === 'tr') {
      info.trackers.push(v);
    } else if (k === 'dn') {
      info.name = v;
    }
  }
  return info;
}

function httpGet(url, { timeout = 8000 } = {}) {
  return new Promise((resolve) => {
    let u;
    try { u = new URL(url); } catch { return resolve({ err: 'bad url' }); }
    const driver = u.protocol === 'https:' ? https : http;
    const req = driver.get(url, { timeout, headers: { 'User-Agent': UA, 'Accept-Encoding': 'identity' } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        return resolve(httpGet(new URL(res.headers.location, u).toString(), { timeout }));
      }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
      res.on('error', (e) => resolve({ err: e.code || e.message }));
    });
    req.on('timeout', () => { req.destroy(); resolve({ err: 'timeout' }); });
    req.on('error', (e) => resolve({ err: e.code || e.message }));
  });
}

// ---------------------------------------------------------------- tracker
function compactPeers(buf) {
  const out = [];
  for (let i = 0; i + 6 <= buf.length; i += 6) {
    out.push({ ip: `${buf[i]}.${buf[i + 1]}.${buf[i + 2]}.${buf[i + 3]}`, port: buf.readUInt16BE(i + 4) });
  }
  return out;
}

async function httpTracker(url, hash, left) {
  const out = { url, ok: false, peers: [], seeders: -1, leechers: -1, err: '' };
  let u;
  try { u = new URL(url); } catch { out.err = 'bad url'; return out; }
  const q = `info_hash=${pct(hash)}&peer_id=${pct(PEER_ID)}&port=6881&uploaded=0&downloaded=0&left=${left}` +
    `&compact=1&numwant=80&event=started`;
  const full = `${u.origin}${u.pathname}?${q}${u.search ? '&' + u.search.slice(1) : ''}`;
  const r = await httpGet(full, { timeout: 8000 });
  if (r.err) { out.err = r.err; return out; }
  if (r.status !== 200) { out.err = `http ${r.status}`; return out; }
  try {
    const [d] = bdec(r.body, 0);
    if (d['failure reason']) { out.err = d['failure reason'].toString('utf8'); return out; }
    if (Buffer.isBuffer(d.peers)) out.peers.push(...compactPeers(d.peers));
    if (Array.isArray(d.peers)) for (const p of d.peers) out.peers.push({ ip: p.ip.toString('utf8'), port: Number(p.port) });
    out.seeders = Number(d.complete ?? -1);
    out.leechers = Number(d.incomplete ?? -1);
    out.ok = true;
  } catch (e) {
    out.err = `decode: ${e.message} ${r.body.toString('latin1', 0, 40).replace(/[^\x20-\x7e]/g, '.')}`;
  }
  return out;
}

function udpTracker(url, hash, left, timeoutMs = 6000) {
  return new Promise((resolve) => {
    const out = { url, ok: false, peers: [], seeders: -1, leechers: -1, err: '' };
    let u;
    try { u = new URL(url); } catch { out.err = 'bad url'; return resolve(out); }
    const sock = dgram.createSocket('udp4');
    const tx1 = crypto.randomInt(1, 0x7ffffff0);
    const tx2 = tx1 + 1;
    let stage = 0;
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { sock.close(); } catch { /* 已关闭 */ }
      resolve(out);
    };
    const timer = setTimeout(() => { out.err = 'timeout'; finish(); }, timeoutMs);
    sock.on('error', (e) => { out.err = e.code || e.message; finish(); });
    sock.on('message', (msg) => {
      if (msg.length < 8) return;
      const action = msg.readUInt32BE(0);
      const tx = msg.readUInt32BE(4);
      if (stage === 0 && action === 0 && tx === tx1 && msg.length >= 16) {
        const req = Buffer.alloc(98);
        msg.copy(req, 0, 8, 16); // connection_id
        req.writeUInt32BE(1, 8);
        req.writeUInt32BE(tx2, 12);
        hash.copy(req, 16);
        PEER_ID.copy(req, 36);
        req.writeBigUInt64BE(0n, 56); // downloaded
        req.writeBigUInt64BE(BigInt(left), 64); // left
        req.writeBigUInt64BE(0n, 72); // uploaded
        req.writeUInt32BE(0, 80); // event
        req.writeUInt32BE(0, 84); // ip
        req.writeUInt32BE(crypto.randomInt(0, 0x7fffffff), 88); // key
        req.writeUInt32BE(80, 92); // num_want
        req.writeUInt16BE(6881, 96);
        stage = 1;
        sock.send(req, Number(u.port || 80), u.hostname);
      } else if (tx === tx2 && action === 1 && msg.length >= 20) {
        out.ok = true;
        out.leechers = msg.readUInt32BE(12);
        out.seeders = msg.readUInt32BE(16);
        out.peers = compactPeers(msg.subarray(20));
        finish();
      } else if (tx === tx2 && action === 3) {
        out.err = `tracker error: ${msg.toString('utf8', 8)}`;
        finish();
      }
    });
    const conn = Buffer.alloc(16);
    conn.writeBigUInt64BE(0x41727101980n, 0);
    conn.writeUInt32BE(0, 8);
    conn.writeUInt32BE(tx1, 12);
    sock.send(conn, Number(u.port || 80), u.hostname);
  });
}

// ---------------------------------------------------------------- DHT(BEP 5)
const DHT_BOOTSTRAP = [
  ['router.bittorrent.com', 6881],
  ['dht.transmissionbt.com', 6881],
  ['router.stealth.si', 6881],
  ['dht.libtorrent.org', 25401]
];

function dhtGetPeers(hash, timeoutMs = 12000, maxQueries = 60) {
  return new Promise((resolve) => {
    const out = { peers: [], nodesSeen: 0, responded: 0 };
    const sock = dgram.createSocket('udp4');
    const myId = crypto.randomBytes(20);
    const nodes = new Map(); // idHex → {id, addr, port, queried, failed}
    const pending = new Map();
    const seenPeer = new Set();
    let tx = 0;
    let queries = 0;
    let finished = false;
    const xor = (a, b) => {
      const r = Buffer.alloc(20);
      for (let i = 0; i < 20; i++) r[i] = a[i] ^ b[i];
      return r;
    };
    const cmp = (a, b) => Buffer.compare(xor(a.id, hash), xor(b.id, hash));
    const addNode = (id, addr, port) => {
      if (!Buffer.isBuffer(id) || id.length !== 20 || !port || addr.startsWith('0.')) return;
      const k = hex(id);
      if (!nodes.has(k)) nodes.set(k, { id, addr, port, queried: false, failed: false });
    };
    const finish = () => {
      if (finished) return;
      finished = true;
      clearInterval(tick);
      clearTimeout(timer);
      out.nodesSeen = nodes.size;
      try { sock.close(); } catch { /* 已关闭 */ }
      resolve(out);
    };
    const query = (node) => {
      node.queried = true;
      queries++;
      const t = (++tx) & 0xffff;
      const tb = Buffer.alloc(2);
      tb.writeUInt16BE(t);
      const msg = Buffer.concat([
        Buffer.from('d1:ad2:id20:'), myId, Buffer.from('9:info_hash20:'), hash,
        Buffer.from('e1:q9:get_peers1:t2:'), tb, Buffer.from('1:y1:qe')
      ]);
      node.sentAt = now();
      pending.set(t, node);
      sock.send(msg, node.port, node.addr);
    };
    sock.on('error', () => { /* 网络不可达时等超时 */ });
    sock.on('message', (msg, rinfo) => {
      let root;
      try { [root] = bdec(msg, 0); } catch { return; }
      const t = Buffer.isBuffer(root.t) && root.t.length === 2 ? root.t.readUInt16BE(0) : -1;
      if (!pending.has(t)) return;
      pending.get(t).replied = true;
      pending.delete(t);
      if (root.y.toString('latin1') !== 'r') return;
      out.responded++;
      const r = root.r || {};
      addNode(r.id, rinfo.address, rinfo.port);
      if (Array.isArray(r.values)) {
        for (const v of r.values) {
          if (v.length >= 6) {
            const ip = `${v[0]}.${v[1]}.${v[2]}.${v[3]}`;
            const port = v.readUInt16BE(4);
            const key = `${ip}:${port}`;
            if (port > 0 && !seenPeer.has(key)) {
              seenPeer.add(key);
              out.peers.push({ ip, port });
            }
          }
        }
      }
      if (Buffer.isBuffer(r.nodes)) {
        for (let i = 0; i + 26 <= r.nodes.length; i += 26) {
          addNode(r.nodes.subarray(i, i + 20),
            `${r.nodes[i + 20]}.${r.nodes[i + 21]}.${r.nodes[i + 22]}.${r.nodes[i + 23]}`, r.nodes.readUInt16BE(i + 24));
        }
      }
    });
    DHT_BOOTSTRAP.forEach(([addr, port], i) => {
      const id = Buffer.alloc(20);
      id[19] = i + 1; // 占位 id,拿到回应后用真实 id 重新登记
      nodes.set(hex(id), { id, addr, port, queried: false, failed: false });
    });
    const tick = setInterval(() => {
      if (queries >= maxQueries) { finish(); return; }
      // 已知节点全部问过,且距离目标最近的 8 个都已回应(或超时) → 收敛结束
      const idle = [...nodes.values()].filter((n) => !n.queried && !n.failed).sort(cmp);
      const closest = [...nodes.values()].filter((n) => n.queried && !n.failed).sort(cmp).slice(0, 8);
      const settled = closest.every((n) => n.replied || now() - n.sentAt > 2500);
      if (idle.length === 0 && settled) { finish(); return; }
      for (const n of idle.slice(0, 3)) query(n);
    }, 400);
    const timer = setTimeout(finish, timeoutMs);
  });
}

// ---------------------------------------------------------------- peer 线协议
const MSG_NAME = ['CHOKE', 'UNCHOKE', 'INTERESTED', 'NOT_INTERESTED', 'HAVE', 'BITFIELD', 'REQUEST', 'PIECE', 'CANCEL', 'DHT_PORT'];

function makeHandshake(hash) {
  const r = Buffer.alloc(8);
  r[5] |= 0x10; // extension protocol
  return Buffer.concat([Buffer.from([19]), Buffer.from('BitTorrent protocol', 'latin1'), r, hash, PEER_ID]);
}

function extMsg(extId, body) {
  const inner = Buffer.concat([Buffer.from([extId]), body]);
  // 长度 = id(1 字节) + inner;旧脚本(debug2/fullprobe)和本脚本早期版本都漏了 id 那 1 字节,
  // 对端会因此把后续消息吞进一条假消息里并断连 —— 这才是「发了扩展握手就拿不到数据」的真因
  const h = Buffer.alloc(4);
  h.writeUInt32BE(inner.length + 1);
  return Buffer.concat([h, Buffer.from([20]), inner]);
}

/**
 * 连一个 peer:握手 → 扩展握手 →(可选)ut_metadata 取元数据 →(可选)要 piece 0 的首个 ≤1MB。
 * state 是跨 peer 共享的对象:拿到并校验过元数据后,后续连接直接做数据测试。
 */
function peerProbe(peer, hash, state, timeoutMs = WANT_DATA ? 45000 : 12000) {
  return new Promise((resolve) => {
    const res = {
      ip: peer.ip, port: peer.port, connected: false, handshake: false, hashMatched: false, client: '',
      uploadOnly: false, supportsMeta: false, metaPieces: 0, metaOk: false, metaMs: 0,
      unchoked: false, unchokeMs: 0, chokeCount: 0, bfMs: 0, bfPieces: -1, haveCount: 0,
      dataBytes: 0, dataMs: 0, firstBlockMs: 0, kbps: 0, why: '', extSent: WANT_EXT
    };
    const t0 = now();
    const sock = net.createConnection({ host: peer.ip, port: peer.port });
    sock.setTimeout(timeoutMs); // 空闲超时
    const deadline = setTimeout(() => finish('deadline'), timeoutMs + 15000); // 总时长兜底:对端慢速滴数据时空闲超时不会触发
    deadline.unref();
    let buf = Buffer.alloc(0);
    let hsDone = false;
    let extId = 0;
    let metaSize = 0;
    let metaTotalPieces = 0;
    const metaPieces = new Map();
    let requested = false;
    let reqAt = 0;
    let blocksWanted = 0;
    let blocksGot = 0;
    let done = false;
    const finish = (why) => {
      if (done) return;
      done = true;
      res.why = why;
      try { sock.destroy(); } catch { /* 已断开 */ }
      resolve(res);
    };
    const startDataTest = () => {
      if (requested || !state.info) return;
      requested = true;
      const pl = state.info.pieceLength;
      blocksWanted = Math.min(DATA_BLOCKS, Math.ceil(pl / DATA_BLOCK));
      reqAt = now();
      for (let i = 0; i < blocksWanted; i++) {
        const m = Buffer.alloc(17);
        m.writeUInt32BE(13, 0);
        m[4] = 6;
        m.writeUInt32BE(0, 5);
        m.writeUInt32BE(i * DATA_BLOCK, 9);
        m.writeUInt32BE(Math.min(DATA_BLOCK, pl - i * DATA_BLOCK), 13);
        sock.write(m);
      }
    };
    sock.on('connect', () => {
      res.connected = true;
      sock.write(makeHandshake(hash));
      if (WANT_EXT) sock.write(extMsg(0, Buffer.from('d1:md6:ut_pexi2e11:ut_metadatai1ee4:reqqi250e1:v4:ani0e', 'latin1')));
    });
    sock.on('timeout', () => finish('timeout'));
    sock.on('error', (e) => finish(e.code || 'error'));
    sock.on('close', () => finish(res.why || 'closed'));
    sock.on('data', (chunk) => {
      buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
      if (!hsDone) {
        if (buf.length < 1) return;
        const hl = 49 + buf[0];
        if (buf.length < hl) return;
        res.handshake = buf[0] === 19 && buf.toString('latin1', 1, 20) === 'BitTorrent protocol';
        res.hashMatched = res.handshake && buf.subarray(28, 48).equals(hash);
        res.reserved = hex(buf.subarray(20, 28));
        if (!res.hashMatched) { finish('handshake mismatch'); return; }
        buf = buf.subarray(hl);
        hsDone = true;
        res.hsMs = now() - t0;
        if (state.info && WANT_DATA) sock.write(Buffer.from([0, 0, 0, 1, 2])); // interested
      }
      for (;;) {
        if (buf.length < 4) return;
        const len = buf.readUInt32BE(0);
        if (len === 0) { buf = buf.subarray(4); continue; } // keep-alive
        if (buf.length < 4 + len) return;
        const id = buf[4];
        const payload = buf.subarray(5, 4 + len);
        buf = buf.subarray(4 + len);
        if (id === 20) {
          if (payload.length === 0) continue;
          const eid = payload[0];
          const body = payload.subarray(1);
          if (eid === 0) {
            try {
              const [d] = bdec(body, 0);
              const m = d.m || {};
              res.client = d.v ? d.v.toString('utf8') : '';
              res.uploadOnly = Number(d.upload_only || 0) === 1;
              if (m.ut_metadata) {
                extId = Number(m.ut_metadata);
                metaSize = Number(d.metadata_size || 0);
                res.supportsMeta = metaSize > 0;
                if (!state.info && metaSize > 0) {
                  metaTotalPieces = Math.ceil(metaSize / META_PIECE);
                  for (let i = 0; i < metaTotalPieces; i++) {
                    sock.write(extMsg(extId, Buffer.from(`d8:msg_typei0e5:piecei${i}ee`, 'latin1')));
                  }
                }
              }
            } catch { /* 忽略无法解析的扩展握手 */ }
          } else if (eid === extId && body.length > 0) {
            try {
              const [d, end] = bdec(body, 0);
              const type = Number(d.msg_type);
              if (type === 1 && !state.info) {
                if (!metaPieces.has(Number(d.piece))) {
                  metaPieces.set(Number(d.piece), Buffer.from(body.subarray(end)));
                  res.metaPieces = metaPieces.size;
                }
                if (res.metaPieces >= metaTotalPieces) {
                  const infoBuf = Buffer.concat([...metaPieces.entries()].sort((a, b) => a[0] - b[0]).map((e) => e[1])).subarray(0, metaSize);
                  res.metaOk = sha1Equals(infoBuf, hash);
                  res.metaMs = now() - t0;
                  if (res.metaOk) {
                    state.info = describeInfoBuf(infoBuf);
                    if (WANT_DATA) {
                      sock.write(Buffer.from([0, 0, 0, 1, 2]));
                      if (res.unchoked) startDataTest();
                    }
                  }
                }
              }
            } catch { /* 忽略 */ }
          }
        } else if (id === 5) {
          res.bfMs = now() - t0;
          let bits = 0;
          for (let i = 0; i < payload.length; i++) bits += payload[i].toString(2).replace(/0/g, '').length;
          res.bfPieces = bits;
        } else if (id === 4) {
          if (res.bfMs === 0) res.bfMs = now() - t0;
          res.haveCount++;
        } else if (id === 1) {
          res.unchoked = true;
          res.unchokeMs = now() - t0;
          if (WANT_DATA) startDataTest();
        } else if (id === 0) {
          res.unchoked = false;
          res.chokeCount++;
        } else if (id === 7) {
          if (!requested) continue;
          blocksGot++;
          if (blocksGot === 1) res.firstBlockMs = now() - reqAt;
          res.dataBytes += payload.length - 8;
          if (blocksGot >= blocksWanted) {
            res.dataMs = now() - reqAt;
            res.kbps = res.dataMs > 0 ? Math.round(res.dataBytes / 1024 / (res.dataMs / 1000)) : 0;
            finish('data-ok');
            return;
          }
        }
      }
    });
  });
}

function sha1Equals(buf, hash) {
  return crypto.createHash('sha1').update(buf).digest().equals(hash);
}

/** 只有 info 字典字节(来自 ut_metadata)时,补出下载所需的最小信息 */
function describeInfoBuf(infoBuf) {
  const [info] = bdec(infoBuf, 0);
  const files = [];
  if (info.files) {
    for (const f of info.files) files.push({ path: f.path.map((x) => x.toString('utf8')).join('/'), length: Number(f.length) });
  } else {
    files.push({ path: info.name.toString('utf8'), length: Number(info.length) });
  }
  return {
    name: info.name.toString('utf8'),
    pieceLength: Number(info['piece length']),
    pieceCount: Math.floor(info.pieces.length / 20),
    files,
    totalLength: files.reduce((s, f) => s + f.length, 0),
    isPrivate: Number(info.private || 0) === 1,
    isV2: info['meta version'] !== undefined
  };
}

function printInfo(info, source) {
  console.log(`  元数据来源: ${source}`);
  console.log(`  name=${info.name}  pieceLength=${fmtBytes(info.pieceLength)}  pieces=${info.pieceCount}  total=${fmtBytes(info.totalLength)}  private=${info.isPrivate ? 1 : 0}  v2=${info.isV2 ? 1 : 0}`);
  for (const f of info.files.slice(0, 8)) console.log(`    - ${f.path}  (${fmtBytes(f.length)})`);
  if (info.files.length > 8) console.log(`    … 共 ${info.files.length} 个文件`);
}

async function pickDefault() {
  const r = await httpGet('https://api.animes.garden/resources?page=1&pageSize=20', { timeout: 10000 });
  if (r.err || r.status !== 200) throw new Error(`AnimeGarden 列表接口失败: ${r.err || r.status}`);
  const list = JSON.parse(r.body.toString('utf8')).resources || [];
  const hit = list.find((x) => /^[0-9a-f]{40}$/i.test((x.magnet.split(':').pop() || '')));
  if (!hit) throw new Error('最新列表里没有 v1(hex btih)资源');
  return hit.magnet.split(':').pop();
}

async function loadResource(infoHash) {
  const r = await httpGet(`https://api.animes.garden/detail/infohash/${infoHash}`, { timeout: 12000 });
  if (r.err || r.status !== 200) throw new Error(`AnimeGarden 详情接口失败: ${r.err || r.status}`);
  const j = JSON.parse(r.body.toString('utf8'));
  const magnets = ((j.detail || {}).magnets || []).map((m) => m.url);
  const resource = j.resource || {};
  if (!resource.magnet) throw new Error('详情接口未返回资源');
  const torrentUrl = magnets.find((u) => /^https?:/.test(u)) || '';
  const fullMagnet = magnets.find((u) => u.startsWith('magnet:')) || (resource.magnet + (resource.tracker || ''));
  return { title: resource.title, provider: resource.provider, size: resource.size, torrentUrl, fullMagnet };
}

async function main() {
  console.log('peer_id =', PEER_ID.toString('latin1'));
  let torrentUrl = '';
  let fullMagnet = target;
  if (TORRENT_URL) {
    torrentUrl = TORRENT_URL; // 指定了 .torrent 就不走 AnimeGarden
  } else if (/^[0-9a-fA-F]{40}$/.test(target) || target === '') {
    const infoHash = target === '' ? await pickDefault() : target.toLowerCase();
    const res = await loadResource(infoHash);
    torrentUrl = res.torrentUrl;
    fullMagnet = res.fullMagnet;
    console.log(`资源: ${res.title}`);
    console.log(`provider=${res.provider}  size=${fmtBytes(res.size)}  infohash=${infoHash}`);
    console.log(`.torrent(HTTPS) = ${torrentUrl || '(无)'}`);
  }
  const mag = parseMagnet(fullMagnet);
  if (TORRENT_URL) mag.hash = Buffer.alloc(20); // 占位,下面用 .torrent 的 info 重算
  if (!mag.hash) {
    console.log(`该资源没有 v1 infohash${mag.hashV2Hex ? `(仅 v2: btmh ${mag.hashV2Hex})` : ''};v1 内核无法处理,需 BEP 52 适配`);
    process.exit(2);
  }
  let hash = mag.hash;
  console.log(`infohash(v1) = ${hex(hash)}${mag.hashV2Hex ? '  [hybrid: 同时带 v2]' : '  [仅 v1]'}`);
  const tStart = now();

  // ① 元数据:HTTPS .torrent
  const state = { info: null };
  let tor = null;
  if (torrentUrl && NO_TORRENT) console.log('已指定 --no-torrent:跳过 HTTPS .torrent,元数据走 ut_metadata');
  if (torrentUrl && !NO_TORRENT) {
    const r = await httpGet(torrentUrl, { timeout: 15000 });
    if (r.err) console.log(`.torrent 下载失败: ${r.err}`);
    else if (r.status !== 200) console.log(`.torrent 下载失败: http ${r.status}`);
    else {
      try {
        tor = parseTorrent(r.body);
        if (TORRENT_URL) { hash = crypto.createHash('sha1').update(tor.infoBytes).digest(); mag.hash = hash; console.log(`infohash(由 .torrent 计算) = ${hex(hash)}`); }
        const ok = sha1Equals(tor.infoBytes, hash);
        console.log(`✓ .torrent 已取得(${r.body.length} 字节,${now() - tStart}ms),SHA1(info) ${ok ? '与 infohash 一致' : '不一致!'}`);
        if (ok) state.info = tor;
      } catch (e) {
        console.log(`.torrent 解析失败: ${e.message}`);
      }
    }
  }

  // ② peer 发现
  // 只探测 http/https/udp tracker;种子 announce-list 里可能有 wss://(WebTorrent 信号服务器),本脚本与端上内核都不支持
  const allTrackers = [...mag.trackers, ...(tor ? tor.trackers : [])];
  const skipped = allTrackers.filter((u) => !/^(https?|udp):/i.test(u));
  const trackers = new Set(allTrackers.filter((u) => /^(https?|udp):/i.test(u)));
  if (skipped.length > 0) console.log(`[tracker] 忽略不支持的协议 ${skipped.length} 个: ${[...new Set(skipped.map((u) => u.split(':')[0] + '://' + new URL(u.replace(/^ws/, 'http')).host))].slice(0, 6).join(', ')}`);
  console.log(`\n[tracker] 共 ${trackers.size} 个(磁力 tr= ${mag.trackers.length},.torrent announce-list ${tor ? tor.trackers.length : 0})`);
  const left = state.info ? state.info.totalLength : 0;
  const results = await Promise.all([...trackers].map((u) => (/^udp:/i.test(u) ? udpTracker(u, hash, left) : httpTracker(u, hash, left))));
  const peerMap = new Map();
  for (const r of results) {
    const before = peerMap.size;
    for (const p of r.peers) peerMap.set(`${p.ip}:${p.port}`, p);
    const label = r.url.replace(/^(https?|udp):\/\//, '').replace(/\/announce$/, '');
    if (r.ok) console.log(`  ✓ ${label.padEnd(38)} peers=${String(r.peers.length).padStart(3)}  seed=${r.seeders}  leech=${r.leechers}`);
    else console.log(`  ✗ ${label.padEnd(38)} ${r.err}`);
  }
  const trackerPeers = [...peerMap.values()].filter((p) => isPublicIpv4(p.ip) && p.port > 0);
  console.log(`tracker 去重后 peer: ${trackerPeers.length}`);

  if (WANT_DHT) {
    const d = await dhtGetPeers(hash);
    const fresh = d.peers.filter((p) => isPublicIpv4(p.ip) && !peerMap.has(`${p.ip}:${p.port}`));
    for (const p of fresh) peerMap.set(`${p.ip}:${p.port}`, p);
    console.log(`[dht] 节点 ${d.nodesSeen},回应 ${d.responded},peer ${d.peers.length}(其中 tracker 没给的新 peer ${fresh.length}),耗时内共发现 ${peerMap.size}`);
  }

  // ③ 逐 peer 握手
  const candidates = [...peerMap.values()].filter((p) => isPublicIpv4(p.ip) && p.port > 0);
  for (let i = candidates.length - 1; i > 0; i--) {
    const j = crypto.randomInt(0, i + 1);
    [candidates[i], candidates[j]] = [candidates[j], candidates[i]];
  }
  const picked = candidates.slice(0, MAX_PEERS);
  console.log(`\n[peer] 探测 ${picked.length} 个(候选 ${candidates.length}),数据测试=${WANT_DATA ? '开' : '关'}`);
  const probes = await Promise.all(picked.map((p) => peerProbe(p, hash, state)));
  probes.sort((a, b) => b.kbps - a.kbps || Number(b.handshake) - Number(a.handshake));
  for (const p of probes) {
    const who = `${p.ip}:${p.port}`.padEnd(22);
    if (!p.connected) { console.log(`  · ${who} 连接失败 (${p.why})`); continue; }
    if (!p.handshake) { console.log(`  · ${who} 已连接但无握手回应 (${p.why})`); continue; }
    const bits = [
      `hs=${p.hsMs}ms`,
      p.client ? `client=${p.client}` : 'client=?',
      `upload_only=${p.uploadOnly ? 1 : 0}`,
      `ut_metadata=${p.supportsMeta ? 1 : 0}`
    ];
    if (p.metaPieces > 0) bits.push(`meta=${p.metaPieces}${p.metaOk ? '✓' : '✗'}@${p.metaMs}ms`);
    if (p.bfPieces >= 0) bits.push(`bitfield=${p.bfPieces}@${p.bfMs}ms`);
    if (p.haveCount) bits.push(`have×${p.haveCount}`);
    bits.push(p.unchoked ? `UNCHOKE@${p.unchokeMs}ms` : (p.chokeCount ? `CHOKE×${p.chokeCount}` : '未 unchoke'));
    if (p.dataBytes > 0) bits.push(`data=${fmtBytes(p.dataBytes)} 首块${p.firstBlockMs}ms 历时${(p.dataMs / 1000).toFixed(1)}s≈${p.kbps}KB/s`);
    bits.push(`→${p.why}`);
    console.log(`  ${p.kbps > 0 ? '✓' : '○'} ${who} ${bits.join('  ')}`);
  }

  // ④ 汇总
  const connected = probes.filter((p) => p.connected).length;
  const handshaked = probes.filter((p) => p.handshake && p.hashMatched).length;
  const extOk = probes.filter((p) => p.supportsMeta || p.client).length;
  const metaTried = probes.filter((p) => p.supportsMeta && !tor).length;
  const metaWon = probes.filter((p) => p.metaOk).length;
  const unchoked = probes.filter((p) => p.unchoked).length;
  const dataOk = probes.filter((p) => p.dataBytes > 0);
  const kbpsAll = dataOk.map((p) => p.kbps).sort((a, b) => a - b);
  console.log('\n===== 汇总 =====');
  console.log(`tracker peer(去重/公网): ${trackerPeers.length}${WANT_DHT ? `,+DHT 后 ${candidates.length}` : ''};我方扩展握手: ${WANT_EXT ? '发' : '不发'}`);
  console.log(`TCP 连上: ${connected}/${probes.length};握手成功: ${handshaked}/${probes.length};回了扩展握手: ${extOk}/${probes.length}`);
  console.log(`做种者(upload_only=1): ${probes.filter((p) => p.uploadOnly).length}/${handshaked};发过 bitfield/have 的: ${probes.filter((p) => p.bfPieces >= 0 || p.haveCount > 0).length}/${handshaked}`);
  const clients = {};
  for (const p of probes) if (p.client) clients[p.client] = (clients[p.client] || 0) + 1;
  console.log('客户端分布:', JSON.stringify(clients));
  console.log(`ut_metadata: 对端声明支持 ${probes.filter((p) => p.supportsMeta).length} 个,${tor ? '(已有 .torrent,未请求元数据)' : `取回并通过 SHA1 校验 ${metaWon} 个`}`);
  console.log(`UNCHOKE: ${unchoked}/${handshaked}`);
  if (WANT_DATA) {
    console.log(`数据: ${dataOk.length}/${handshaked} 个 peer 返回了 piece 数据` +
      (kbpsAll.length ? `;单 peer 吞吐 中位 ${kbpsAll[Math.floor(kbpsAll.length / 2)]} KB/s,最高 ${kbpsAll[kbpsAll.length - 1]} KB/s` : ''));
  } else {
    console.log('数据测试未开启(--data)');
  }
  if (state.info) printInfo(state.info, tor ? '.torrent(HTTPS)' : 'ut_metadata(peer)');
  console.log(`总耗时 ${((now() - tStart) / 1000).toFixed(1)}s`);
  process.exit(0);
}

main().catch((e) => {
  console.log('失败:', e.message);
  process.exit(1);
});
