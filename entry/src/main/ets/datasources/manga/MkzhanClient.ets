import { HttpClient } from '../http/HttpClient';
import { AppError } from '../../common/AppError';
import { asObj, jArr, jNum, jObj, jStr } from '../../common/Json';
import { Log } from '../../common/Logger';
import {
  MangaBrief, MangaChapter, MangaChapterImages, MangaDetail, MangaHome
} from '../../models/manga/MangaModels';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const WWW = 'https://www.mkzhan.com';
const CDN = 'https://comic.mkzcdn.com';
/** 分类页每页卡片数(SSR 固定 30) */
const LIST_PAGE_SIZE = 30;

/** mkzhan 主题 id → 名称(2026-11-26 实测;11=漫画大全与「全部」语义重复,不进 chips) */
const THEME_NAMES: Record<string, string> = {
  '1': '霸总',
  '2': '修真',
  '3': '恋爱',
  '4': '校园',
  '5': '冒险',
  '6': '搞笑',
  '7': '生活',
  '8': '热血',
  '9': '架空',
  '10': '后宫',
  '12': '玄幻'
};

/** 乱序还原用(图片按 page_id 排序) */
interface PagePair {
  pos: number;
  url: string;
}

/**
 * 漫客栈(mkzhan.com)客户端。端点全部为 2026-11-26 无代理实测(见 scripts/mangaprobe/mkzhan_api*.mjs):
 *  - 搜索   GET {CDN}/search/keyword/?keyword=&page_num=&page_size=  JSON(list;code 199=空结果)
 *  - 详情   GET {CDN}/comic/info/?comic_id=  JSON(作者名不在 JSON,从 /{id}/ SSR 页补)
 *  - 章节   GET {CDN}/chapter/v1/?comic_id=  JSON(data 数组,number 升序;is_vip 字符串 '0'/'1')
 *  - 图片   GET {CDN}/chapter/content/?comic_id=&chapter_id=  JSON(data 数组 page_id+image,VIP 匿名也可拉)
 *  - 分类   GET {WWW}/category/?theme_id=N&order=1|2&page=P  SSR(30 张/页;order=1 人气 2 更新)
 * 坑:code/is_vip/theme_id 都是字符串;图片域 oss.mkzcdn.com 在 JSON 里是 http://,统一规范化为 https。
 */
export class MkzhanClient {
  /** 章节表缓存:chapterImages 算 prev/next 邻居要用,免得每话重复拉 chapter/v1 */
  private static chapterCache: Map<string, MangaChapter[]> = new Map();

  private static headers(): Record<string, string> {
    return {
      'user-agent': UA,
      'referer': `${WWW}/`
    };
  }

  private static normUrl(u: string): string {
    return u.replace('http://oss.mkzcdn.com', 'https://oss.mkzcdn.com');
  }

  private static async getEnvelope(apiPath: string): Promise<Record<string, Object>> {
    const text = await HttpClient.getText(`${CDN}${apiPath}`, MkzhanClient.headers(),
      { connectMs: 6000, readMs: 12000 });
    try {
      return JSON.parse(text) as Record<string, Object>;
    } catch (e) {
      throw new AppError('漫客栈响应非 JSON');
    }
  }

  /** code !== 200 抛业务错误(code 是字符串,Number 兜底) */
  private static assertOk(env: Record<string, Object>): void {
    const code = Number(env['code'] ?? 200);
    if (code !== 200) {
      throw new AppError(`漫客栈接口错误 ${code}:${jStr(env, 'message')}`);
    }
  }

  /** 关键词搜索;code 199 = 站方空结果,返回 [] */
  static async search(q: string, offset: number = 0, limit: number = 20): Promise<MangaBrief[]> {
    const page = Math.floor(offset / Math.max(1, limit)) + 1;
    const env = await MkzhanClient.getEnvelope(
      `/search/keyword/?keyword=${encodeURIComponent(q)}&page_num=${page}&page_size=${limit}`);
    if (Number(env['code'] ?? 0) === 199) {
      return [];
    }
    MkzhanClient.assertOk(env);
    const out: MangaBrief[] = [];
    for (const raw of jArr(jObj(env, 'data'), 'list')) {
      const item = asObj(raw);
      if (item === undefined) {
        continue;
      }
      const id = jStr(item, 'comic_id');
      if (id.length === 0) {
        continue;
      }
      out.push({
        pathWord: id,
        name: jStr(item, 'title'),
        cover: MkzhanClient.normUrl(jStr(item, 'cover')),
        author: jStr(item, 'author_title'),
        popular: jNum(item, 'read_count', 0),
        updatedAt: ''
      });
    }
    return out;
  }

  /** 分类/排序列表(SSR):theme 传主题 id('' = 全部);ordering '-popular'→order=1,'-datetime_updated'→order=2 */
  static async comicsList(theme: string, ordering: string, offset: number,
    limit: number = LIST_PAGE_SIZE): Promise<MangaBrief[]> {
    const page = Math.floor(offset / LIST_PAGE_SIZE) + 1;
    const parts: string[] = [];
    if (theme.length > 0) {
      parts.push(`theme_id=${encodeURIComponent(theme)}`);
    }
    parts.push(ordering === '-popular' ? 'order=1' : 'order=2');
    if (page > 1) {
      parts.push(`page=${page}`);
    }
    const html = await HttpClient.getText(`${WWW}/category/?${parts.join('&')}`, MkzhanClient.headers(),
      { connectMs: 6000, readMs: 15000 });
    return MkzhanClient.parseCards(html);
  }

  /** 分类页 SSR 卡片解析:cover(img data-src)/title(comic__title,alt 兜底);href 只锚单段 /{id}/ 不吃更新链接 */
  private static parseCards(html: string): MangaBrief[] {
    const out: MangaBrief[] = [];
    const re =
      /<a class="cover" href="\/(\d+)\/"[\s\S]{0,300}?data-src="([^"]+)"[\s\S]{0,300}?alt="([^"]*)"[\s\S]{0,600}?comic__title"[^>]*><a[^>]*>([^<]*)<\/a>/g;
    let m = re.exec(html);
    while (m !== null) {
      const id = m[1];
      const title = m[4].trim().length > 0 ? m[4].trim() : m[3].trim();
      if (Number.isFinite(Number(id)) && title.length > 0) {
        out.push({
          pathWord: id,
          name: title,
          cover: MkzhanClient.normUrl(m[2]),
          author: '',
          popular: 0,
          updatedAt: ''
        });
      }
      m = re.exec(html);
    }
    return out;
  }

  /** 详情:JSON 主体 + SSR 页补作者名(作者名解析失败不致命,置空) */
  static async detail(pathWord: string): Promise<MangaDetail> {
    const env = await MkzhanClient.getEnvelope(`/comic/info/?comic_id=${encodeURIComponent(pathWord)}`);
    MkzhanClient.assertOk(env);
    const d = jObj(env, 'data');
    if (d === undefined) {
      throw new AppError('漫画不存在或已下架');
    }
    let author = '';
    try {
      const html = await HttpClient.getText(`${WWW}/${encodeURIComponent(pathWord)}/`, MkzhanClient.headers(),
        { connectMs: 6000, readMs: 12000 });
      const m = html.match(/comic-author[\s\S]{0,500}?alt="([^"]+)"/);
      if (m !== null) {
        author = m[1];
      }
    } catch (e) {
      Log.warn('mkzhan author fetch failed', pathWord, `${e}`);
    }
    const themes: string[] = [];
    for (const id of jStr(d, 'theme_id').split(',')) {
      const name = THEME_NAMES[id.trim()];
      if (name !== undefined) {
        themes.push(name);
      }
    }
    return {
      pathWord: pathWord,
      name: jStr(d, 'title'),
      cover: MkzhanClient.normUrl(jStr(d, 'cover')),
      author: author,
      description: jStr(d, 'content'),
      themes: themes,
      popular: jNum(d, 'read_count', 0),
      updatedAt: '',
      groups: ['default']
    };
  }

  /** 章节列表:站方 number 字段升序;重排后 index 连续(0 = 第 1 话) */
  static async chapters(pathWord: string, group: string = 'default'): Promise<MangaChapter[]> {
    const env = await MkzhanClient.getEnvelope(`/chapter/v1/?comic_id=${encodeURIComponent(pathWord)}`);
    MkzhanClient.assertOk(env);
    const out: MangaChapter[] = [];
    for (const raw of jArr(env, 'data')) {
      const item = asObj(raw);
      if (item === undefined) {
        continue;
      }
      const cid = jStr(item, 'chapter_id');
      if (cid.length === 0) {
        continue;
      }
      const name = jStr(item, 'title');
      out.push({
        uuid: cid,
        name: name.length > 0 ? name : `第${jNum(item, 'number', out.length + 1)}话`,
        index: jNum(item, 'number', out.length + 1) - 1,
        size: 0,
        vip: jStr(item, 'is_vip') === '1'
      });
    }
    out.sort((a: MangaChapter, b: MangaChapter) => a.index - b.index);
    for (let i = 0; i < out.length; i++) {
      out[i].index = i; // 重排后的连续序号(UI/进度用)
    }
    MkzhanClient.chapterCache.set(pathWord, out);
    return out;
  }

  /** 章节图片:按 page_id 升序;prev/next 从章节表缓存取邻居(无缓存时先拉一次章节表) */
  static async chapterImages(pathWord: string, chapterUuid: string): Promise<MangaChapterImages> {
    let chs = MkzhanClient.chapterCache.get(pathWord);
    if (chs === undefined || chs.length === 0) {
      chs = await MkzhanClient.chapters(pathWord);
    }
    let idx = -1;
    for (let i = 0; i < chs.length; i++) {
      if (chs[i].uuid === chapterUuid) {
        idx = i;
        break;
      }
    }
    const env = await MkzhanClient.getEnvelope(
      `/chapter/content/?comic_id=${encodeURIComponent(pathWord)}&chapter_id=${encodeURIComponent(chapterUuid)}`);
    MkzhanClient.assertOk(env);
    const pairs: PagePair[] = [];
    for (const raw of jArr(env, 'data')) {
      const p = asObj(raw);
      if (p === undefined) {
        continue;
      }
      const url = MkzhanClient.normUrl(jStr(p, 'image'));
      if (url.length > 0) {
        const pair: PagePair = { pos: jNum(p, 'page_id', pairs.length), url: url };
        pairs.push(pair);
      }
    }
    pairs.sort((a: PagePair, b: PagePair) => a.pos - b.pos);
    const images: string[] = [];
    for (const p of pairs) {
      images.push(p.url);
    }
    const result: MangaChapterImages = {
      chapterUuid: chapterUuid,
      chapterName: idx >= 0 ? chs[idx].name : '',
      images: images,
      prevUuid: idx > 0 ? chs[idx - 1].uuid : '',
      nextUuid: idx >= 0 && idx + 1 < chs.length ? chs[idx + 1].uuid : ''
    };
    return result;
  }

  /** mkzhan 无首页榜单接口:恒空结构(MangaSource 接口要求;Tab 页不使用) */
  static async home(): Promise<MangaHome> {
    const empty: MangaHome = {
      dayRank: [], weekRank: [], monthRank: [], newComics: [], finishComics: []
    };
    return empty;
  }
}
