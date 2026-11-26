// 漫客栈第三轮:搜索命中判定 / 分类页 12 主题名与排序语义 / VIP 页数 / 详情页作者与主题提取
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
      return text;
    } catch (e) {
      await new Promise((r2) => setTimeout(r2, 1200 * i));
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error(`放弃:${url}`);
}

// A. 搜索:精确命中词 + 模糊词,判定结果头与卡片作者
for (const q of ['傲娇小蛮妻', '斗罗', '帝少']) {
  const t = await get(`${WWW}/search/?q=${encodeURIComponent(q)}`);
  const head = (t.match(/search_head">([^<]*)</) ?? ['', '(无 search_head)'])[1].trim();
  const cids = [...new Set([...t.matchAll(/data-cid="(\d+)"/g)].map((m) => m[1]))];
  const hasAuthor = /comic-author|author_name|class="author/.test(t);
  console.log(`[search ${q}] head="${head}" 卡片=${cids.length} 含作者标记=${hasAuthor}`);
}

// B. 12 个主题名(页面 title) + 默认/排序语义(对比首卡片 cid)
const themeNames = {};
for (let i = 1; i <= 12; i++) {
  const s = await get(`${WWW}/category/?theme_id=${i}`);
  themeNames[i] = (s.match(/<title>\s*([^_]+?)\s*_/)[1] ?? '').trim();
}
console.log('=== 主题表:', JSON.stringify(themeNames));

const firstCid = (s) => ([...s.matchAll(/data-cid="(\d+)"/g)].map((m) => m[1]))[0] ?? '-';
const c0 = await get(`${WWW}/category/`);
const c1 = await get(`${WWW}/category/?order=1`);
const c2 = await get(`${WWW}/category/?order=2`);
console.log(`=== 默认首卡=${firstCid(c0)} order=1 首卡=${firstCid(c1)} order=2 首卡=${firstCid(c2)}`);
const f1 = await get(`${WWW}/category/?order=1&finish=1`);
const f2 = await get(`${WWW}/category/?order=1&finish=2`);
console.log(`=== finish=1 首卡=${firstCid(f1)} finish=2 首卡=${firstCid(f2)}`);
const mi = c1.indexOf('漫画检索');
console.log('--- order=1 页排序控件上下文 ---');
console.log(c1.substring(Math.max(0, mi - 500), mi + 100).replace(/\s+/g, ' ').substring(0, 700));
const oi = c1.search(/class="(on|active)[^"]*"/);
console.log('--- order=1 选中态上下文 ---');
console.log(c1.substring(Math.max(0, oi - 400), oi + 200).replace(/\s+/g, ' ').substring(0, 600));

// C. VIP 章节:两话的页数(确认匿名可见性稳定性)
for (const cid of ['1069859', '1070100']) {
  const j = JSON.parse(await get(`${CDN}/chapter/content/?comic_id=217087&chapter_id=${cid}`));
  const n = Array.isArray(j.data) ? j.data.length : -1;
  console.log(`=== VIP content ${cid}: code=${JSON.stringify(j.code)} 页数=${n} 首图=${n > 0 ? j.data[0].image : '-'}`);
}

// D. 详情页:作者 span.name + 主题链接
const d = await get(`${WWW}/217087/`);
const nameM = d.match(/comic-author[\s\S]{0,600}?<span class="name[^>]*>([^<]*)</);
console.log('=== 作者(span.name):', nameM ? nameM[1].trim() : '(未匹配)');
const altM = d.match(/comic-author[\s\S]{0,400}?alt="([^"]+)"/);
console.log('=== 作者(img.alt):', altM ? altM[1] : '(未匹配)');
const themeLinks = [...new Set([...d.matchAll(/href="\/category\/\?theme_id=(\d+)"[^>]*>\s*([^<]{1,12}?)\s*</g)].map((m) => `${m[1]}=${m[2]}`))];
console.log('=== 详情页主题链接:', themeLinks.join(','));
