// BT 内核可行性验证:magnet 解析 + tracker announce + bencode 解析 peer 列表
import http from 'node:http';
import https from 'node:https';

const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function infoHashFromMagnet(magnet) {
  const m = /[?&]xt=urn:btih:([^&]+)/i.exec(magnet);
  if (!m) return null;
  let v = decodeURIComponent(m[1]);
  if (/^[0-9a-fA-F]{40}$/.test(v)) return Buffer.from(v, 'hex');
  v = v.toUpperCase().replace(/=+$/, '');
  if (/^[A-Z2-7]{32}$/.test(v)) {
    let bits = '';
    for (const c of v) bits += B32.indexOf(c).toString(2).padStart(5, '0');
    const buf = Buffer.alloc(20);
    for (let i = 0; i < 20; i++) buf[i] = parseInt(bits.slice(i * 8, i * 8 + 8), 2);
    return buf;
  }
  return null;
}

// 逐字节 %XX,避免 UTF-8 重编码
function pct(buf) {
  let s = '';
  for (const b of buf) s += '%' + b.toString(16).padStart(2, '0');
  return s;
}

// 最小 bencode 解析:返回 {peers, interval, ...}
function bdecode(buf) {
  let i = 0;
  function dec() {
    const c = buf[i];
    if (c === 0x69) { // i
      i++; let s = '';
      while (buf[i] !== 0x65) s += String.fromCharCode(buf[i++]);
      i++; return parseInt(s, 10);
    }
    if (c === 0x6c) { // l
      i++; const a = [];
      while (buf[i] !== 0x65) a.push(dec());
      i++; return a;
    }
    if (c === 0x64) { // d
      i++; const o = {};
      while (buf[i] !== 0x65) { const k = dec(); o[k] = dec(); }
      i++; return o;
    }
    // string "len:data"
    let len = 0;
    while (buf[i] >= 0x30 && buf[i] <= 0x39) { len = len * 10 + (buf[i] - 0x30); i++; }
    i++; // :
    const out = buf.slice(i, i + len); i += len; return out;
  }
  return dec();
}

const TRACKERS = [
  'http://tracker.opentrackr.org:1337/announce',
  'http://tracker.dler.org:6969/announce',
  'http://open.stealth.si:80/announce',
  'http://tracker.torrent.eu.org:451/announce',
  'https://tracker.gbitt.info:443/announce',
  'https://tracker.lolibi.cn:443/announce',
];

function httpAnnounce(url, hash) {
  return new Promise((resolve) => {
    let u;
    try { u = new URL(url); } catch { return resolve({ url, err: 'bad url' }); }
    const peerId = '-ANIX01-123456789012';
    const path = u.pathname + '?' +
      'info_hash=' + pct(hash) +
      '&peer_id=' + pct(Buffer.from(peerId, 'latin1')) +
      '&port=6881&uploaded=0&downloaded=0&left=0&compact=1&event=started';
    const driver = u.protocol === 'https:' ? https : http;
    const opts = { host: u.hostname, port: u.port || (u.protocol === 'https:' ? 443 : 80), path, timeout: 8000, headers: { 'User-Agent': 'Bittorrent' } };
    const req = driver.get(opts, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        const body = Buffer.concat(chunks);
        let info = { status: res.statusCode, len: body.length };
        if (res.statusCode === 200 && body[0] === 0x64) {
          try {
            const d = bdecode(body);
            const peers = d.peers;
            if (Buffer.isBuffer(peers)) {
              info.peers = peers.length / 6; // compact: 每 6 字节一 peer
              info.sample = Array.from(peers.slice(0, 18)).map(b => b);
            } else if (Array.isArray(peers)) {
              info.peers = peers.length;
              info.sample = peers.slice(0, 2).map(p => p && p.toString ? p.toString('latin1') : p);
            }
            info.interval = d.interval;
          } catch (e) { info.decodeErr = e.message; }
        } else {
          info.head = body.slice(0, 40).toString('latin1').replace(/[^\x20-\x7e]/g, '.');
        }
        resolve({ url, ...info });
      });
    });
    req.on('error', e => resolve({ url, err: e.code || e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ url, err: 'timeout' }); });
  });
}

const magnet = process.argv[2] || 'magnet:?xt=urn:btih:070012114120d189066178af1e2f1c4d05d3ba95';
const hash = infoHashFromMagnet(magnet);
console.log('info_hash(hex):', hash ? hash.toString('hex') : 'PARSE FAIL');
console.log('base32 解析自检: 7R332QTL6HMLMTAUJRIZHDDAAJIADYNQ ->',
  infoHashFromMagnet('magnet:?xt=urn:btih:7R332QTL6HMLMTAUJRIZHDDAAJIADYNQ')?.toString('hex'));
if (!hash) process.exit(1);
const results = await Promise.all(TRACKERS.map(t => httpAnnounce(t, hash)));
for (const r of results) console.log(JSON.stringify(r));
