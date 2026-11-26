// 知音漫客(zymk.cn)接入原型:搜索→详情→章节→图片 端到端验证(2026-11-25)
// 用法:node scripts/mangaprobe/zymk.mjs [step]
// 只请求站点公开页面,不带任何个人信息。成功响应缓存在 $TMP/zymkcache/ 避免重复请求。
import { writeFileSync, readFileSync, mkdirSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const BASE = 'https://www.zymk.cn';
const CACHE = join(tmpdir(), 'zymkcache');
mkdirSync(CACHE, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 带重试的 GET(晚高峰跨网互联不稳),成功后缓存到磁盘 */
async function get(path, { useCache = true } = {}) {
  const file = join(CACHE, encodeURIComponent(path));
  if (useCache && existsSync(file)) {
    console.log(`[cache] ${path}`);
    return readFileSync(file, 'utf8');
  }
  for (let i = 1; i <= 4; i++) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 15000);
    try {
      const r = await fetch(BASE + path, { headers: { 'user-agent': UA, referer: BASE + '/' }, signal: ctrl.signal });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const text = await r.text();
      writeFileSync(file, text);
      console.log(`[fetch ${i}] ${path} ${text.length}B`);
      await sleep(400); // 温柔一点
      return text;
    } catch (e) {
      console.log(`[retry ${i}] ${path} ${e.cause?.code ?? e.message}`);
      await sleep(1500 * i);
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error(`放弃:${path}`);
}

function dumpHrefs(html, filterRe) {
  const set = new Set();
  for (const m of html.matchAll(/href="([^"]+)"/g)) {
    if (!filterRe || filterRe.test(m[1])) set.add(m[1]);
  }
  return [...set];
}

const step = process.argv[2] ?? '1';

if (step === '1') {
  // ① 详情页:找章节入口
  const html = await get('/4982/');
  const hrefs = dumpHrefs(html, /(chapter|4982)/);
  console.log('章节相关链接:\n' + hrefs.join('\n'));
} else if (step === '2') {
  // ② 章节列表
  const html = await get('/chapterlist/4982.html');
  const title = html.match(/<title>([^<]*)<\/title>/);
  console.log('标题:', title?.[1]);
  const chaps = dumpHrefs(html, /^\/chapter\//);
  console.log('章节链接(' + chaps.length + '):\n' + chaps.slice(0, 10).join('\n'));
} else if (step === '3') {
  // ③ 章节阅读页:图片在哪。章节 URL = /{comicId}/{chapterId}.html(详情页相对链接)
  const html = await get('/4982/434454.html');
  const title = html.match(/<title>([^<]*)<\/title>/);
  console.log('标题:', title?.[1]);
  // 疑似图片:CDN 特征域名
  const pics = [...new Set([...html.matchAll(/https?:[^"'\s\\]+/g)].map((m) => m[0])
    .filter((u) => /(mhpic|zymkcdn|yyhao|img\.zymk|\.webp|\.jpg\?)/i.test(u)))];
  console.log('疑似图片(' + pics.length + '):\n' + pics.slice(0, 8).join('\n'));
  // 内联 script 数据段(图片列表/解密逻辑通常在这)
  const scripts = [...html.matchAll(/<script[^>]*>([\s\S]+?)<\/script>/g)]
    .map((m) => m[1].trim()).filter((s) => s.length > 50 && !s.includes('src='));
  console.log('内联 script ' + scripts.length + ' 段');
  for (const s of scripts) {
    if (/pic|image|page|chapter|eval|packed|var /i.test(s)) {
      console.log('▓▓▓ ' + s.substring(0, 900) + '\n');
    }
  }
} else if (step === '4') {
  // ④ 图片下载测速:node zymk.mjs 4 <图片URL>
  const url = process.argv[3];
  if (!url) throw new Error('用法:node zymk.mjs 4 <图片URL>');
  const t0 = Date.now();
  const r = await fetch(url, { headers: { 'user-agent': UA, referer: BASE + '/' } });
  const buf = await r.arrayBuffer();
  const sec = (Date.now() - t0) / 1000;
  console.log(`HTTP ${r.status}, ${(buf.byteLength / 1024).toFixed(0)}KB, ${sec.toFixed(2)}s, ${(buf.byteLength / 1024 / 1024 / sec).toFixed(2)}MB/s`);
} else if (step === '5') {
  // ⑤ 搜索接口探测:常见形态 /search?keywords= / /s/{kw}/
  for (const p of ['/search?keywords=%E9%95%BF%E7%9B%B8%E6%80%9D', '/search.html?keywords=%E9%95%BF%E7%9B%B8%E6%80%9D']) {
    try {
      const html = await get(p, { useCache: false });
      const title = html.match(/<title>([^<]*)<\/title>/);
      console.log(p, '→', title?.[1], html.length + 'B');
      const hits = dumpHrefs(html, /^\/\d+\/$/);
      console.log('  结果链接:', hits.slice(0, 8).join(' '));
    } catch (e) {
      console.log(p, '✗', e.message);
    }
  }
}
