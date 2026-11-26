// 漫客栈(mkzhan.com)接入原型:详情页章节数据定位 + 阅读页图片提取(2026-11-26)
// 用法:node scripts/mangaprobe/mkzhan.mjs [1|2|3]
import { writeFileSync, readFileSync, mkdirSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const BASE = 'https://www.mkzhan.com';
const CACHE = join(tmpdir(), 'mkzhancache');
mkdirSync(CACHE, { recursive: true });

async function get(path) {
  const file = join(CACHE, encodeURIComponent(path));
  if (existsSync(file)) return readFileSync(file, 'utf8');
  for (let i = 1; i <= 4; i++) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 15000);
    try {
      const r = await fetch(BASE + path, { headers: { 'user-agent': UA, referer: BASE + '/' }, signal: ctrl.signal });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const text = await r.text();
      writeFileSync(file, text);
      console.log(`[fetch] ${path} ${text.length}B`);
      return text;
    } catch (e) {
      console.log(`[retry ${i}] ${e.cause?.code ?? e.message}`);
      await new Promise((r2) => setTimeout(r2, 1200 * i));
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error(`放弃:${path}`);
}

const step = process.argv[2] ?? '1';

if (step === '1') {
  // ① 详情页:139 个章节 URL 到底住在哪(找数据容器)
  const t = await get('/217087/');
  const idxs = [...t.matchAll(/\/217087\/\d+\.html/g)].map((m) => m.index).slice(0, 3);
  for (const i of idxs) {
    console.log('--- 上下文 @', i, '---');
    console.log(t.substring(Math.max(0, i - 300), i + 120).replace(/\s+/g, ' '));
  }
} else if (step === '2') {
  // ② 阅读页:图片与元数据
  const t = await get('/217087/1069798.html');
  const title = t.match(/<title>([^<]*)<\/title>/);
  console.log('标题:', title?.[1]);
  const imgs = [...new Set([...t.matchAll(/https?:\/\/[^"'\s\\]+/g)].map((m) => m[0])
    .filter((u) => /(kaimanhua|mkzcdn|\.jpg\?|\.webp|\.png\?)/i.test(u)))];
  console.log('图片 URL(' + imgs.length + '):\n' + imgs.slice(0, 5).join('\n'));
  for (const key of ['chapterData', 'imageList', 'pic_list', 'images', 'chapter_image']) {
    const m = t.match(new RegExp('(?:' + key + ')\\s*[:=]\\s*(\\[[^\\]]{10,600}|\\{.{10,400})'));
    if (m) console.log('数据[' + key + ']:', m[1].substring(0, 400));
  }
  // script src 清单
  const js = [...new Set([...t.matchAll(/src="([^"]+\.js[^"]*)"/g)].map((m) => m[1]))].filter((u) => !/baidu|respond/.test(u));
  console.log('JS:', js.join('\n'));
} else if (step === '3') {
  // ③ 图片下载测速:node mkzhan.mjs 3 <url>
  const url = process.argv[3];
  const t0 = Date.now();
  const r = await fetch(url, { headers: { 'user-agent': UA, referer: BASE + '/' } });
  const buf = await r.arrayBuffer();
  const sec = (Date.now() - t0) / 1000;
  console.log(`HTTP ${r.status}, ${(buf.byteLength / 1024).toFixed(0)}KB, ${sec.toFixed(2)}s, ${(buf.byteLength / 1024 / 1024 / sec).toFixed(2)}MB/s`);
}
