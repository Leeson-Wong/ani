import { HttpClient } from '../http/HttpClient';
import { CmsCategory, CmsVodResp, CmsVodRaw, CmsVideo, CmsVideoBrief, HomePage, PlayRoute, VodPage } from '../../models/cms/MaccmsModels';
import { MaccmsParser } from './MaccmsParser';

/** 上游分页字段可能是字符串("1")或数字(1),统一转 number */
function toInt(v: Object | undefined, fallback: number): number {
  if (v === undefined || v === null) {
    return fallback;
  }
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

/**
 * 单个苹果CMS 站的 API 客户端:
 * GET {apiBase}?ac=detail&wd=<关键词>&pg=<页>&t=<分类>&ids=<ids>
 */
export class MaccmsClient {
  readonly sourceId: number;
  readonly apiBase: string;

  constructor(sourceId: number, apiBase: string) {
    this.sourceId = sourceId;
    this.apiBase = apiBase;
  }

  private buildUrl(params: Record<string, string>): string {
    const pairs: string[] = [];
    const keys = Object.keys(params);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      pairs.push(`${encodeURIComponent(k)}=${encodeURIComponent(params[k])}`);
    }
    const sep = this.apiBase.indexOf('?') >= 0 ? '&' : '?';
    return `${this.apiBase}${sep}${pairs.join('&')}`;
  }

  /** 分类列表 + 最近更新(首页 discover)。
   *  分类走 ac=list(360/速播等站只有该模式返回 class;量子/暴风两种都有)。
   */
  async recent(page: number): Promise<HomePage> {
    const listResp = await HttpClient.getJson<CmsVodResp>(this.buildUrl({ 'ac': 'list', 'pg': String(page) }));
    const detailResp = await HttpClient.getJson<CmsVodResp>(this.buildUrl({ 'ac': 'detail', 'pg': String(page) }));
    const result: HomePage = {
      categories: listResp.class && listResp.class.length > 0
        ? listResp.class
        : (detailResp.class ?? []),
      items: MaccmsClient.mapBrief(detailResp.list ?? [], this.sourceId),
      pagecount: toInt(detailResp.pagecount, 1)
    };
    return result;
  }

  /** 分类检索 */
  async byCategory(typeId: number, page: number): Promise<VodPage> {
    const resp = await HttpClient.getJson<CmsVodResp>(
      this.buildUrl({ 'ac': 'detail', 'pg': String(page), 't': String(typeId) }));
    const result: VodPage = {
      items: MaccmsClient.mapBrief(resp.list ?? [], this.sourceId),
      pagecount: toInt(resp.pagecount, 1)
    };
    return result;
  }

  /** 关键词搜索 */
  async search(keyword: string, page: number): Promise<CmsVideoBrief[]> {
    const resp = await HttpClient.getJson<CmsVodResp>(
      this.buildUrl({ 'ac': 'detail', 'wd': keyword, 'pg': String(page) }));
    return MaccmsClient.mapBrief(resp.list ?? [], this.sourceId);
  }

  /** 详情(含线路/集数解析) */
  async detail(vodId: number): Promise<CmsVideo> {
    const resp = await HttpClient.getJson<CmsVodResp>(this.buildUrl({ 'ac': 'detail', 'ids': String(vodId) }));
    const list = resp.list ?? [];
    if (list.length === 0) {
      throw new Error(`vod ${vodId} not found`);
    }
    return MaccmsClient.mapDetail(list[0], this.sourceId);
  }

  static mapBrief(list: CmsVodRaw[], sourceId: number): CmsVideoBrief[] {
    const result: CmsVideoBrief[] = [];
    for (const raw of list) {
      result.push(MaccmsParser.toBrief(raw, sourceId));
    }
    return result;
  }

  static mapDetail(raw: CmsVodRaw, sourceId: number): CmsVideo {
    const brief = MaccmsParser.toBrief(raw, sourceId);
    const routes: PlayRoute[] = MaccmsParser.parsePlayRoutes(raw.vod_play_from, raw.vod_play_url);
    const detail: CmsVideo = {
      sourceId: sourceId,
      vodId: brief.vodId,
      title: brief.title,
      cover: brief.cover,
      category: brief.category,
      remarks: brief.remarks,
      year: brief.year,
      area: raw.vod_area ?? '',
      actors: raw.vod_actor ?? '',
      director: raw.vod_director ?? '',
      description: MaccmsParser.cleanDescription(raw.vod_content),
      routes: routes
    };
    return detail;
  }
}
