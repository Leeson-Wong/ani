// 漫客栈补充探测:卡片完整结构 / 有效搜索 / 排序页 URL / 真 VIP content / 详情 SSR 作者名
import { writeFileSync, readFileSync, mkdirSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const CDN = 'https://comic.mkzcdn.com';
const WWW = 'https://www.mkzhan.com';
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
      console.log(`[fetch ok] ${url} ${text.length}B`);
      return text;
    } catch (e) {
      console.log(`[retry ${i}] ${url} → ${e.cause?.code ?? e.message}`);
      await new Promise((r2) => setTimeout(r2, 1200 * i));
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error(`放弃:${url}`);
}

// A. 有效搜索词 + 完整卡片块
const t = await get(`${WWW}/search/?q=${encodeURIComponent('斗破苍穹')}`);
console.log('=== 斗破苍穹 搜索头:', (t.match(/search_head">([^<]*)</) ?? ['', '(无)'])[1].trim());
const blocks = [...t.matchAll(/<div class="common-comic-item"[\s\S]{0,2600}?<\/div>\s*<\/div>/g)].map((m) => m[0]);
console.log('=== 卡片块数:', blocks.length);
if (blocks.length > 0) {
  console.log('--- 首卡片完整 HTML(压缩) ---');
  console.log(blocks[0].replace(/\s+/g, ' ').substring(0, 2400));
}

// B. 首页导航里的排序/分类链接
const home = await get(`${WWW}/`);
const links = [...new Set([...home.matchAll(/href="(\/sort[^"]*|\/category[^"]*|\/booklist[^"]*)"/g)].map((m) => m[1]))];
console.log('=== 首页 sort/category 链接:\n' + links.slice(0, 30).join('\n'));

// C. 排序页结构(取第一个链接试)
if (links.length > 0) {
  const s = await get(WWW + links[0]);
  console.log(`=== ${links[0]} title:`, (s.match(/<title>([^<]*)</) ?? ['', '?'])[1]);
  const slinks = [...new Set([...s.matchAll(/href="(\/sort\/[^"]*)"/g)].map((m) => m[1]))];
  console.log('=== 页内 sort 链接前25:\n' + slinks.slice(0, 25).join('\n'));
  const items = [...s.matchAll(/href="\/(\d+)\/"/g)].map((m) => m[1]);
  console.log('=== 页内漫画卡片数:', [...new Set(items)].length);
  const pager = [...new Set([...s.matchAll(/href="([^"]*\/sort\/[^"]*)"[^>]*class="[^"]*page|class="[^"]*page[^"]*"[^>]*href="([^"]*)"/g)])];
  console.log('=== 分页标记样本:', JSON.stringify(pager).substring(0, 300));
  const nextI = s.indexOf('下一页');
  if (nextI >= 0) {
    console.log('--- 下一页上下文 ---');
    console.log(s.substring(Math.max(0, nextI - 300), nextI + 80).replace(/\s+/g, ' '));
  }
}

// D. 真 VIP 章节 content(is_vip === '1')
const cl = JSON.parse(await get(`${CDN}/chapter/v1/?comic_id=217087`));
const vip = (cl.data ?? []).find((c) => c.is_vip === '1');
console.log(`=== VIP content chapter_id=${vip?.chapter_id}`);
const vc = JSON.parse(await get(`${CDN}/chapter/content/?comic_id=217087&chapter_id=${vip.chapter_id}`));
console.log('code:', JSON.stringify(vc.code), '; data:', JSON.stringify(vc.data).substring(0, 200));

// E. 详情 SSR:作者名与主题标签
const d = await get(`${WWW}/217087/`);
const authorI = d.search(/作者|author/i);
console.log('--- 详情页作者上下文 ---');
console.log(d.substring(Math.max(0, authorI - 200), authorI + 300).replace(/\s+/g, ' '));
const themeTags = [...new Set([...d.matchAll(/<a[^>]*href="\/sort\/[^"]*"[^>]*>([^<]{1,12})<\/a>/g)].map((m) => m[1]))];
console.log('=== 详情页主题标签:', themeTags.join(','));
