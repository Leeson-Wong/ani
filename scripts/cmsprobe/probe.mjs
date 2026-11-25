// 影视备用 CMS 源探测:API 存活 + 抽一集验证 m3u8 可拉(2026-11-25,结论写入 dev/项目开发现状总结.md)
// 只请求站点公开接口,不带任何个人信息
const CANDIDATES = [
  { name: '天气预报(tyyszy)', hosts: ['https://tyyszy.com', 'https://cj.tyyszy.com', 'https://api.tyyszy.com'] },
  { name: '极速(jszyapi)', hosts: ['https://jszyapi.com', 'https://cj.jszyapi.com', 'https://api.jszyapi.com'] },
  { name: '金鹰(jyzyapi)', hosts: ['https://jyzyapi.com', 'https://cj.jyzyapi.com', 'https://api.jyzyapi.com'] },
];
const PATHS = ['/api.php/provide/vod', '/provide/vod', '/api.php/provide/vod/at/xml'];

async function getText(url, timeoutMs = 8000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const r = await fetch(url, { signal: ctrl.signal, headers: { 'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0' } });
    if (!r.ok) return { ok: false, msg: `HTTP ${r.status}` };
    const text = await r.text();
    return { ok: true, text };
  } catch (e) {
    return { ok: false, msg: `${e.cause?.code ?? e.message}` };
  } finally {
    clearTimeout(t);
  }
}

async function probeApi(host) {
  for (const p of PATHS) {
    if (p.endsWith('/xml')) continue;
    const url = `${host}${p}/?ac=list&pg=1`;
    const r = await getText(url);
    if (!r.ok) continue;
    try {
      const j = JSON.parse(r.text);
      if ((j.code === 1 || j.code === 0) && Array.isArray(j.list)) {
        return { apiBase: `${host}${p}/`, categories: (j.class ?? []).length, total: j.total ?? j.list.length };
      }
    } catch { /* not json */ }
  }
  return null;
}

async function probePlay(apiBase) {
  // 抽第一个有集数的详情,验证 m3u8
  const r = await getText(`${apiBase}?ac=detail&pg=1`);
  if (!r.ok) return { play: false, msg: r.msg };
  let j;
  try { j = JSON.parse(r.text); } catch { return { play: false, msg: 'detail 非 JSON' }; }
  const list = j.list ?? [];
  let picked = null;
  for (const v of list) {
    if ((v.vod_play_url ?? '').includes('.m3u8')) { picked = v; break; }
  }
  if (!picked) return { play: false, msg: '第 1 页没有 m3u8 集数' };
  const ep = picked.vod_play_url.split('#')[0].split('$').pop();
  const pr = await getText(ep.startsWith('http') ? ep : '');
  if (!pr.ok) return { play: false, msg: `m3u8 拉取失败:${pr.msg}` };
  const isM3u8 = pr.text.startsWith('#EXTM3U');
  const encrypted = pr.text.includes('AES-128');
  const segs = (pr.text.match(/#EXTINF/g) ?? []).length;
  return { play: isM3u8, msg: isM3u8 ? `${segs} 段${encrypted ? ' · AES-128' : ' · 未加密'}` : '响应不是 m3u8', episodeName: picked.vod_name };
}

for (const c of CANDIDATES) {
  let result = null;
  for (const host of c.hosts) {
    result = await probeApi(host);
    if (result) break;
  }
  if (!result) {
    console.log(`${c.name}: ✗ API 全部不可达/非 macCMS 信封`);
    continue;
  }
  const play = await probePlay(result.apiBase);
  console.log(`${c.name}: API ✓ ${result.apiBase} (分类 ${result.categories}, 条目 ${result.total}) · 播放 ${play.play ? '✓' : '✗'} ${play.msg}${play.episodeName ? ` · 样本《${play.episodeName}》` : ''}`);
}
