import { HttpClient, HttpOpts } from '../http/HttpClient';
import { AppError } from '../../common/AppError';
import { CmsCategory, CmsVodResp, CmsVodRaw, CmsVideo, CmsVideoBrief, HomePage, PlayRoute, VodPage } from '../../models/cms/MaccmsModels';
import { MaccmsParser } from './MaccmsParser';
import { SourceHealth } from './SourceHealth';

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
 * 全部请求走 fetchVod:网络层失败计入源健康分(连续 3 次自动停用),成功清零。
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

  /** 统一请求入口:失败(网络层/5xx/非 JSON)计入源健康分;4xx 与业务错误不计 */
  private async fetchVod(params: Record<string, string>, opts?: HttpOpts): Promise<CmsVodResp> {
    const url = this.buildUrl(params);
    try {
      const resp = await HttpClient.getJson<CmsVodResp>(url, undefined, opts);
      SourceHealth.recordOk(this.sourceId);
      return resp;
    } catch (e) {
      const err = AppError.from(e as Object);
      if (err.code === 0 || err.code >= 500) {
        SourceHealth.recordFail(this.sourceId);
      }
      throw err;
    }
  }

  /** 分类列表 + 最近更新(首页 discover)。
   *  分类走 ac=list(360/速播等站只有该模式返回 class;量子/暴风两种都有)。
   */
  async recent(page: number): Promise<HomePage> {
    const opts: HttpOpts = { connectMs: 5000, readMs: 12000, retries: 1 };
    const listResp = await this.fetchVod({ 'ac': 'list', 'pg': String(page) }, opts);
    const detailResp = await this.fetchVod({ 'ac': 'detail', 'pg': String(page) }, opts);
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
    const resp = await this.fetchVod(
      { 'ac': 'detail', 'pg': String(page), 't': String(typeId) },
      { connectMs: 5000, readMs: 12000, retries: 1 });
    const result: VodPage = {
      items: MaccmsClient.mapBrief(resp.list ?? [], this.sourceId),
      pagecount: toInt(resp.pagecount, 1)
    };
    return result;
  }

  /** 关键词搜索(多源扇出场景:超时更紧 + 1 次重试,死源不拖慢整体) */
  async search(keyword: string, page: number): Promise<CmsVideoBrief[]> {
    const resp = await this.fetchVod(
      { 'ac': 'detail', 'wd': keyword, 'pg': String(page) },
      { connectMs: 4000, readMs: 6000, retries: 1 });
    return MaccmsClient.mapBrief(resp.list ?? [], this.sourceId);
  }

  /** 详情(含线路/集数解析) */
  async detail(vodId: number): Promise<CmsVideo> {
    const resp = await this.fetchVod(
      { 'ac': 'detail', 'ids': String(vodId) },
      { connectMs: 5000, readMs: 12000, retries: 1 });
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
