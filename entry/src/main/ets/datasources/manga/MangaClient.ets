import { HttpClient } from '../http/HttpClient';
import { asObj, jArr, jNum, jObj, jStr } from '../../common/Json';
import { AppError } from '../../common/AppError';
import {
  MangaBrief, MangaChapter, MangaChapterImages, MangaDetail, MangaHome, MangaRankItem
} from '../../models/manga/MangaModels';

const BASE = 'https://api.mangacopy.com';

/** 乱序还原中间结构 */
interface ImagePair {
  pos: number;
  url: string;
}

/**
 * copymanga(拷贝漫画)客户端。
 * 必须携带 platform/region/version/webp 请求头,否则接口返回裸 "error"。
 * 章节图片接口返回乱序 contents,由 words[] 指定每张图的真实页码,需还原。
 */
export class MangaClient {
  private static headers(): Record<string, string> {
    return {
      'platform': '1',
      'region': '1',
      'version': '20240614',
      'webp': '1'
    };
  }

  private static async get(path: string): Promise<Record<string, Object> | undefined> {
    const text = await HttpClient.getText(`${BASE}${path}`, MangaClient.headers());
    if (text === 'error' || text.trim().startsWith('<')) {
      throw new AppError('漫画接口不可用(可能域名又漂移了)');
    }
    const envelope = JSON.parse(text) as Record<string, Object>;
    const code = Number(envelope['code'] ?? 200);
    if (code !== 200) {
      throw new AppError(`漫画接口错误 ${code}:${jStr(envelope, 'message')}`);
    }
    return jObj(envelope, 'results');
  }

  private static brief(raw: Record<string, Object>): MangaBrief | null {
    const pathWord = jStr(raw, 'path_word');
    if (pathWord.length === 0) {
      return null;
    }
    const authors = jArr(raw, 'author');
    const author = authors.length > 0 ? jStr(asObj(authors[0]) ?? {}, 'name') : '';
    return {
      pathWord: pathWord,
      name: jStr(raw, 'name'),
      cover: jStr(raw, 'cover'),
      author: author,
      popular: jNum(raw, 'popular'),
      updatedAt: jStr(raw, 'datetime_updated')
    };
  }

  private static rankList(results: Record<string, Object> | undefined, key: string): MangaRankItem[] {
    const out: MangaRankItem[] = [];
    for (const raw of jArr(results, key)) {
      const item = asObj(raw);
      if (item === undefined) {
        continue;
      }
      const comic = jObj(item, 'comic');
      if (comic === undefined) {
        continue;
      }
      const b = MangaClient.brief(comic);
      if (b !== null) {
        const rank: MangaRankItem = {
          pathWord: b.pathWord, name: b.name, cover: b.cover, author: b.author,
          popular: b.popular, updatedAt: b.updatedAt, sort: jNum(item, 'sort', 0)
        };
        out.push(rank);
      }
    }
    return out;
  }

  private static briefList(results: Record<string, Object> | undefined, key: string): MangaBrief[] {
    const out: MangaBrief[] = [];
    for (const raw of jArr(results, key)) {
      const item = asObj(raw);
      if (item === undefined) {
        continue;
      }
      const holder = jObj(item, 'comic') ?? item; // recComics 嵌套在 comic 里
      const b = MangaClient.brief(holder);
      if (b !== null) {
        out.push(b);
      }
    }
    return out;
  }

  /** 首页榜单:日/周/月榜 + 最新 + 完结 */
  static async home(): Promise<MangaHome> {
    const results = await MangaClient.get('/api/v3/h5/homeIndex?platform=1');
    const home: MangaHome = {
      dayRank: MangaClient.rankList(results, 'rankDayComics'),
      weekRank: MangaClient.rankList(results, 'rankWeekComics'),
      monthRank: MangaClient.rankList(results, 'rankMonthComics'),
      newComics: MangaClient.briefList(results, 'newComics'),
      finishComics: MangaClient.briefList(results, 'finishComics')
    };
    return home;
  }

  /**
   * 全量分页列表:/api/v3/comics(支持 theme 筛选 + ordering 排序)。
   * theme 为空 = 全部;ordering:'-datetime_updated' 最新 / '-popular' 人气。
   */
  static async comicsList(theme: string, ordering: string, offset: number,
    limit: number = 24): Promise<MangaBrief[]> {
    const themeQ = theme.length > 0 ? `&theme=${encodeURIComponent(theme)}` : '';
    const results = await MangaClient.get(
      `/api/v3/comics?limit=${limit}&offset=${offset}&ordering=${ordering}${themeQ}`);
    return MangaClient.briefList(results, 'list');
  }

  /** 关键词搜索(q 必须非空,空 q 接口返回空列表) */
  static async search(q: string, offset: number = 0, limit: number = 20): Promise<MangaBrief[]> {
    const results = await MangaClient.get(
      `/api/v3/search/comic?q=${encodeURIComponent(q)}&offset=${offset}&limit=${limit}`);
    return MangaClient.briefList(results, 'list');
  }

  /** 漫画详情(含分组) */
  static async detail(pathWord: string): Promise<MangaDetail> {
    const results = await MangaClient.get(`/api/v3/comic2/${pathWord}`);
    const comic = jObj(results, 'comic');
    if (comic === undefined) {
      throw new AppError('漫画不存在或已下架');
    }
    const themes: string[] = [];
    for (const t of jArr(comic, 'theme')) {
      const obj = asObj(t);
      if (obj !== undefined) {
        const name = jStr(obj, 'name');
        if (name.length > 0) {
          themes.push(name);
        }
      }
    }
    const authors = jArr(comic, 'author');
    const groups: string[] = [];
    const groupsObj = jObj(results, 'groups');
    if (groupsObj !== undefined) {
      const keys = Object.keys(groupsObj);
      for (const g of keys) {
        groups.push(g);
      }
    }
    return {
      pathWord: pathWord,
      name: jStr(comic, 'name'),
      cover: jStr(comic, 'cover'),
      author: authors.length > 0 ? jStr(asObj(authors[0]) ?? {}, 'name') : '',
      description: jStr(comic, 'brief'),
      themes: themes,
      popular: jNum(comic, 'popular'),
      updatedAt: jStr(comic, 'datetime_updated'),
      groups: groups.length > 0 ? groups : ['default']
    };
  }

  /** 章节列表:按站方权威 index 字段升序返回(0 = 第 1 话)。
   *  实测 API 响应顺序不稳定可依赖,index 是每话自带的话序(番外也编在其中),显式排序最稳。 */
  static async chapters(pathWord: string, group: string = 'default'): Promise<MangaChapter[]> {
    const out: MangaChapter[] = [];
    let offset = 0;
    for (;;) {
      const results = await MangaClient.get(
        `/api/v3/comic/${pathWord}/group/${group}/chapters?limit=100&offset=${offset}`);
      const list = jArr(results, 'list');
      for (const raw of list) {
        const item = asObj(raw);
        if (item === undefined) {
          continue;
        }
        const uuid = jStr(item, 'uuid');
        if (uuid.length === 0) {
          continue;
        }
        const ch: MangaChapter = {
          uuid: uuid,
          name: jStr(item, 'name').length > 0 ? jStr(item, 'name') : `第${out.length + 1}话`,
          index: jNum(item, 'index', 0),
          size: jNum(item, 'size', 0)
        };
        out.push(ch);
      }
      const total = jNum(results, 'total', 0);
      offset += 100;
      if (out.length >= total || list.length === 0) {
        break;
      }
    }
    out.sort((a: MangaChapter, b: MangaChapter) => a.index - b.index);
    for (let i = 0; i < out.length; i++) {
      out[i].index = i; // 重排后的连续序号(UI/进度用)
    }
    return out;
  }

  /**
   * 章节图片:contents 乱序,words[i] 是第 i 张图的真实页码 → 排序还原。
   * 返回 prev/next 章节 uuid 便于连读。
   */
  static async chapterImages(pathWord: string, chapterUuid: string): Promise<MangaChapterImages> {
    const results = await MangaClient.get(`/api/v3/comic/${pathWord}/chapter2/${chapterUuid}`);
    const chapter = jObj(results, 'chapter');
    if (chapter === undefined) {
      throw new AppError('章节不存在');
    }
    const contents = jArr(chapter, 'contents');
    const words = jArr(chapter, 'words');
    const wordsNum: number[] = [];
    for (const w of words) {
      wordsNum.push(Number(w));
    }
    // contents[i] 的真实页码 = words[i];按页码升序排列
    const pairs: ImagePair[] = [];
    for (let i = 0; i < contents.length && i < wordsNum.length; i++) {
      const c = asObj(contents[i]);
      if (c === undefined) {
        continue;
      }
      const url = jStr(c, 'url');
      if (url.length > 0) {
        const pair: ImagePair = { pos: wordsNum[i], url: url };
        pairs.push(pair);
      }
    }
    pairs.sort((a: ImagePair, b: ImagePair) => a.pos - b.pos);
    const images: string[] = [];
    for (const p of pairs) {
      images.push(p.url);
    }
    const prev = jObj(chapter, 'prev');
    const next = jObj(chapter, 'next');
    const result: MangaChapterImages = {
      chapterUuid: chapterUuid,
      chapterName: jStr(chapter, 'name'),
      images: images,
      prevUuid: prev !== undefined ? jStr(prev, 'uuid') : '',
      nextUuid: next !== undefined ? jStr(next, 'uuid') : ''
    };
    return result;
  }
}
