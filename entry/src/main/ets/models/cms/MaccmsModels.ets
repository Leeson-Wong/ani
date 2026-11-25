/** 苹果CMS(macCMS v10) vod API 的上游 JSON 信封(字段全部可能缺失) */
export interface CmsCategory {
  type_id: number;
  type_name: string;
}

export interface CmsVodRaw {
  vod_id: number;
  vod_name?: string;
  vod_pic?: string;
  type_id?: number;
  type_name?: string;
  vod_remarks?: string;
  vod_time?: string;
  vod_year?: string;
  vod_area?: string;
  vod_actor?: string;
  vod_director?: string;
  vod_content?: string;
  vod_play_from?: string;
  vod_play_url?: string;
  vod_author?: string;
}

export interface CmsVodResp {
  code?: number;
  msg?: string;
  /** 不同站返回 string 或 number,统一在客户端转 int */
  page?: Object;
  pagecount?: Object;
  total?: Object;
  limit?: Object;
  class?: CmsCategory[];
  list?: CmsVodRaw[];
}

/** 解析后的领域模型 */
export interface PlayRoute {
  index: number;
  name: string;
  episodes: Episode[];
}

export interface Episode {
  index: number;
  name: string;
  url: string;
}

export interface CmsVideo {
  sourceId: number;
  vodId: number;
  title: string;
  cover: string;
  category: string;
  remarks: string;
  year: string;
  area: string;
  actors: string;
  director: string;
  description: string;
  routes: PlayRoute[];
}

/** 搜索结果条目(不拉详情,无线路信息) */
export interface CmsVideoBrief {
  sourceId: number;
  vodId: number;
  title: string;
  cover: string;
  category: string;
  remarks: string;
  year: string;
}

/** 分类/检索分页结果 */
export interface VodPage {
  items: CmsVideoBrief[];
  pagecount: number;
}

/** 首页(最近更新 + 分类列表) */
export interface HomePage {
  categories: CmsCategory[];
  items: CmsVideoBrief[];
  pagecount: number;
}

/** 源探测结果 */
export interface ProbeResult {
  ok: boolean;
  categories: number;
  message: string;
}
