// 漫客栈第四轮:真实搜索 API(comic.js 端点清单) + 分类页卡片结构与排序语义
import { writeFileSync, readFileSync, mkdirSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const WWW = 'https://www.mkzhan.com';
const STATIC = 'https://static.mkzcdn.com/home/assets/script';
const CACHE = join(tmpdir(), 'mkzhanapicache');
mkdirSync(CACHE, { recursive: true });

async function get(url) {
  const file = join(CACHE, encodeURIComponent(url).substring(0, 180));
  if (existsSync(file)) return readFileSync(file, 'utf8');
  for (let i = 1; i <= 3; i++) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 15000);
    try {
      const r = await fetch(url, { headers: { 'user-agent': UA, referer: WWW + '/' }, signal: ctrl.signal });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const text = await r.text();
      writeFileSync(file, text);
      return text;
    } catch (e) {
      await new Promise((r2) => setTimeout(r2, 1200 * i));
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error(`放弃:${url}`);
}

// A. comic.js API 端点清单
const apiJs = await get(`${STATIC}/modules/httpApi/apis/comic.js`);
console.log('=== comic.js 长度:', apiJs.length);
const urls = [...new Set([...apiJs.matchAll(/['"`](\/[^'"`]{3,80})['"`]/g)].map((m) => m[1]))];
console.log('=== 端点清单:\n' + urls.join('\n'));

// B. 搜索页引用的 JS bundle(找 search 相关模块)
const sp = await get(`${WWW}/search/?q=test`);
const js = [...new Set([...sp.matchAll(/src="([^"]+\.js[^"]*)"/g)].map((m) => m[1]))].filter((u) => !/baidu|respond|bdshare/.test(u));
console.log('=== 搜索页 JS:\n' + js.join('\n'));

// C. 分类页卡片结构(theme_id=1 已缓存)
const cat = await get(`${WWW}/category/?theme_id=1`);
const i = cat.search(/href="\/\d+\/"/);
console.log('--- 分类页首卡片上下文 ---');
console.log(cat.substring(Math.max(0, i - 800), i + 400).replace(/\s+/g, ' ').substring(0, 1200));

// D. 排序语义:order=1/2 与默认页首 3 卡对比
const cids = (s) => [...s.matchAll(/href="\/(\d+)\/"/g)].map((m) => m[1]).filter((v, idx, a) => a.indexOf(v) === idx).slice(0, 3);
const c0 = cids(await get(`${WWW}/category/`));
const c1 = cids(await get(`${WWW}/category/?order=1`));
const c2 = cids(await get(`${WWW}/category/?order=2`));
console.log(`=== 默认首3: ${c0.join(',')} | order=1: ${c1.join(',')} | order=2: ${c2.join(',')}`);
// 排序控件文字:找 order 链接附近的中文
const ordCtx = cat.match(/href="\/category\/\?[^"]*order[^"]*"[^>]*>\s*([^<]{1,16})\s*</g);
console.log('=== order 链接文字:', JSON.stringify(ordCtx));
