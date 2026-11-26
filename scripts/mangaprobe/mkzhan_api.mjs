// 漫客栈 JSON API 结构探测:为 ArkTS(MkzhanClient)实现取准确字段(2026-11-26)
// 用法:node scripts/mangaprobe/mkzhan_api.mjs [step]  step=all|info|chapters|content|vip|search|sort
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

const step = process.argv[2] ?? 'all';

// ① 详情 JSON
async function info() {
  const t = await get(`${CDN}/comic/info/?comic_id=217087`);
  const j = JSON.parse(t);
  console.log('=== comic/info 顶层键:', Object.keys(j).join(','));
  console.log('=== comic/info data 键:', Object.keys(j.data ?? {}).join(','));
  console.log(JSON.stringify(j.data, null, 1).substring(0, 1600));
}

// ② 章节列表 JSON
async function chapters() {
  const t = await get(`${CDN}/chapter/v1/?comic_id=217087`);
  const j = JSON.parse(t);
  console.log('=== chapter/v1 顶层键:', Object.keys(j).join(','));
  const arr = j.data ?? j.list ?? [];
  console.log('=== 章节数:', Array.isArray(arr) ? arr.length : typeof arr, '; 首项键:',
    Array.isArray(arr) && arr.length > 0 ? Object.keys(arr[0]).join(',') : '-');
  console.log('首项:', JSON.stringify(arr[0]));
  console.log('次项:', JSON.stringify(arr[1]));
  console.log('末项:', JSON.stringify(arr[arr.length - 1]));
  return arr;
}

// ③ 章节图片 JSON(免费章节)
async function content(arr) {
  const free = arr.find((c) => !c.is_vip) ?? arr[0];
  console.log(`=== chapter/content comic_id=217087 chapter_id=${free.chapter_id}`);
  const t = await get(`${CDN}/chapter/content/?comic_id=217087&chapter_id=${free.chapter_id}`);
  const j = JSON.parse(t);
  console.log('=== content 顶层键:', Object.keys(j).join(','), '; data 类型:', Array.isArray(j.data) ? 'array' : typeof j.data);
  const pages = Array.isArray(j.data) ? j.data : (j.data?.list ?? []);
  console.log('=== 页数:', pages.length, '; 首页键:', pages.length > 0 ? Object.keys(pages[0]).join(',') : '-');
  console.log('首页:', JSON.stringify(pages[0]));
  console.log('次页:', JSON.stringify(pages[1]));
}

// ④ VIP 章节 content(确认匿名拉不到图的具体返回)
async function vip(arr) {
  const v = arr.find((c) => c.is_vip);
  if (v === undefined) {
    console.log('=== 该漫画无 VIP 章节');
    return;
  }
  console.log(`=== VIP 章节 content chapter_id=${v.chapter_id}`);
  const t = await get(`${CDN}/chapter/content/?comic_id=217087&chapter_id=${v.chapter_id}`);
  console.log(t.substring(0, 400));
}

// ⑤ 搜索 SSR(找卡片结构:comicId/name/cover/author 的标记特征)
async function search() {
  const t = await get(`${WWW}/search/?q=${encodeURIComponent('斗罗大陆')}`);
  console.log('=== search HTML 长度:', t.length);
  const cards = [...t.matchAll(/href="\/(\d+)\/"/g)].map((m) => m[1]);
  console.log('=== 卡片 id 前10:', [...new Set(cards)].slice(0, 10).join(','));
  const i = t.indexOf('href="/' + [...new Set(cards)][0] + '/"');
  console.log('--- 首卡片上下文 ---');
  console.log(t.substring(Math.max(0, i - 700), i + 300).replace(/\s+/g, ' '));
}

// ⑥ 分类/排序 SSR(发现 URL 规律与分页方式)
async function sort() {
  const t = await get(`${WWW}/sort/`);
  console.log('=== /sort/ 长度:', t.length, '; title:', (t.match(/<title>([^<]*)</) ?? ['', '?'])[1]);
  const links = [...new Set([...t.matchAll(/href="(\/sort\/[^"]*)"/g)].map((m) => m[1]))];
  console.log('=== sort 链接前20:\n' + links.slice(0, 20).join('\n'));
  const i = t.search(/href="\/sort\/[^"]*"/);
  console.log('--- 首链接上下文 ---');
  console.log(t.substring(Math.max(0, i - 400), i + 200).replace(/\s+/g, ' '));
}

if (step === 'all' || step === 'info') await info();
if (step === 'all' || step === 'chapters') { const a = await chapters(); if (step === 'all') { await content(a); await vip(a); } }
if (step === 'content') await content(await chapters());
if (step === 'vip') await vip(await chapters());
if (step === 'all' || step === 'search') await search();
if (step === 'all' || step === 'sort') await sort();
