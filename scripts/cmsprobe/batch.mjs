// 影视 CMS 候选源批量探测:API 存活 + 抽集验证 m3u8 + CDN 首段实测吞吐(2026-11-25)
// 用法:node scripts/cmsprobe/batch.mjs [--speed]
// 只请求站点公开接口,不带任何个人信息。
// 结论目标:筛出可进 App 内置源表的候选(API 活 + CDN 可达 + 速率可接受)。

const CANDIDATES = [
  // 内置对照组
  { name: '360资源', url: 'https://360zy.com/api.php/provide/vod' },
  { name: '金鹰', url: 'https://jyzyapi.com/api.php/provide/vod' },
  // 候选(存活率未知,全部实测)
  { name: '闪电', url: 'https://sdzyapi.com/api.php/provide/vod' },
  { name: '卧龙', url: 'https://collect.wolongzy.cc/api.php/provide/vod' },
  { name: '红牛', url: 'https://caiji.hongniuzy2.com/api.php/provide/vod' },
  { name: '天空', url: 'https://api.tiankongapi.com/api.php/provide/vod' },
  { name: '魔爪', url: 'https://mozhuazy.com/api.php/provide/vod' },
  { name: '豆瓣', url: 'https://dbzy.tv/api.php/provide/vod' },
  { name: '老鸭', url: 'https://api.apibdzy.com/api.php/provide/vod' },
  { name: '无一', url: 'https://collect.wuyouzy.cc/api.php/provide/vod' },
  { name: '看点', url: 'https://kankanzyapi.com/api.php/provide/vod' },
  { name: '优质', url: 'https://api.1080zyku.com/api.php/provide/vod' },
  { name: '樱桃', url: 'https://api.yinghuazy.mobi/api.php/provide/vod' },
  { name: '快车', url: 'https://caiji.kuaichezy.org/api.php/provide/vod' },
  { name: '雨后', url: 'https://caiji.yuhouzy.com/api.php/provide/vod' },
  { name: '海盗', url: 'https://caiji.haizhizy.com/api.php/provide/vod' },
  { name: '暴风', url: 'https://bfzy.tv/api.php/provide/vod' },
  { name: '量子', url: 'https://cj.lziapi.com/api.php/provide/vod' },
];

const UA = { 'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0 Safari/537.36' };

async function getText(url, timeoutMs = 7000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const r = await fetch(url, { signal: ctrl.signal, headers: UA });
    if (!r.ok) return { ok: false, msg: `HTTP ${r.status}` };
    return { ok: true, text: await r.text(), finalUrl: r.url };
  } catch (e) {
    return { ok: false, msg: `${e.cause?.code ?? e.message}`.substring(0, 60) };
  } finally {
    clearTimeout(t);
  }
}

/** CDN 首段吞吐:下载完整一段,计时 */
async function speedTest(segUrl, capMs = 12000) {
  const ctrl = new AbortController();
  const t0 = Date.now();
  const timer = setTimeout(() => ctrl.abort(), capMs);
  try {
    const r = await fetch(segUrl, { signal: ctrl.signal, headers: UA });
    if (!r.ok) return { ok: false, msg: `HTTP ${r.status}` };
    const reader = r.body.getReader();
    let bytes = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.length;
    }
    const sec = (Date.now() - t0) / 1000;
    return { ok: true, bytes, sec, kbps: Math.round(bytes / 1024 / sec) };
  } catch (e) {
    return { ok: false, msg: '下载中断' };
  } finally {
    clearTimeout(timer);
  }
}

async function probeOne(c) {
  const sep = c.url.includes('?') ? '&' : '?';
  const out = { name: c.name, api: '', total: 0, cats: 0, play: '', enc: '', speed: '', note: '' };

  // ① API 存活(ac=list 给分类)
  const list = await getText(`${c.url}${sep}ac=list&pg=1`);
  if (!list.ok) { out.api = `✗ ${list.msg}`; return out; }
  let j;
  try { j = JSON.parse(list.text); } catch { out.api = '✗ 非 JSON'; return out; }
  if (!(j.code === 1 || j.code === 0)) { out.api = `✗ code=${j.code}`; return out; }
  out.api = '✓';
  out.total = Number(j.total ?? 0);
  out.cats = (j.class ?? []).length;

  // ② 抽一集验证 m3u8
  const det = await getText(`${c.url}${sep}ac=detail&pg=1`);
  if (!det.ok) { out.play = `✗ 详情失败`; return out; }
  let d;
  try { d = JSON.parse(det.text); } catch { out.play = '✗ 详情非 JSON'; return out; }
  const vods = d.list ?? [];
  let ep = '';
  for (const v of vods) {
    const pu = v.vod_play_url ?? '';
    if (pu.includes('.m3u8') || pu.includes('.mp4')) {
      ep = pu.split('#')[0].split('$').pop();
      break;
    }
  }
  if (!ep) { out.play = '✗ 第1页无播放地址'; return out; }
  if (!ep.startsWith('http')) { out.play = '✗ 相对地址(需拼接)'; return out; }

  const pl = await getText(ep);
  if (!pl.ok) { out.play = `✗ m3u8 ${pl.msg}`; return out; }
  if (!pl.text.startsWith('#EXTM3U')) {
    out.play = pl.text.includes('#EXTM3U') ? '✓(有前导空白)' : '✗ 非 m3u8';
    if (!out.play.startsWith('✓')) return out;
  } else {
    out.play = '✓';
  }
  // master 表则下钻一层
  let playlistText = pl.text;
  let baseUrl = ep;
  if (!playlistText.includes('#EXTINF')) {
    const lines = playlistText.split('\n').map(s => s.trim());
    const i = lines.findIndex(l => l.startsWith('#EXT-X-STREAM-INF'));
    if (i < 0) { out.play = '✗ 无段'; return out; }
    const sub = lines.slice(i + 1).find(l => l && !l.startsWith('#'));
    const subUrl = new URL(sub, ep).href;
    const subR = await getText(subUrl);
    if (!subR.ok) { out.play = `✗ 子表 ${subR.msg}`; return out; }
    playlistText = subR.text;
    baseUrl = subUrl;
  }
  out.enc = playlistText.includes('AES-128') ? 'AES-128' : '明文';
  const segs = playlistText.split('\n').map(s => s.trim()).filter(l => l && !l.startsWith('#'));
  out.play += ` ${segs.length}段`;
  if (out.play.startsWith('✓')) out.note = pl.finalUrl !== ep ? `重定向→${new URL(pl.finalUrl).host}` : '';

  // ③ CDN 首段吞吐(默认不跑,--speed 开启时逐源串行,避免互相抢带宽)
  if (process.argv.includes('--speed') && segs.length > 0) {
    const segUrl = new URL(segs[0], baseUrl).href;
    const st = await speedTest(segUrl);
    out.speed = st.ok ? `${(st.kbps / 1024).toFixed(1)} MB/s (${(st.bytes / 1024 / 1024).toFixed(1)}MB/${st.sec.toFixed(1)}s)` : `✗ ${st.msg}`;
  }
  return out;
}

const results = await Promise.all(CANDIDATES.map(probeOne));
const nameW = Math.max(...CANDIDATES.map(c => c.name.length)) + 2;
console.log('名称'.padEnd(nameW) + 'API\t条数\t分类\t播放\t加密\tCDN吞吐\t备注');
console.log('-'.repeat(110));
for (const r of results) {
  console.log(r.name.padEnd(nameW) + [r.api, r.total, r.cats, r.play, r.enc, r.speed, r.note].join('\t'));
}
const okCount = results.filter(r => r.api === '✓' && r.play.startsWith('✓')).length;
console.log(`\n可用(API+播放双 ✓):${okCount}/${CANDIDATES.length}${process.argv.includes('--speed') ? '' : '(未测吞吐,加 --speed 逐源串行实测)'}`);
