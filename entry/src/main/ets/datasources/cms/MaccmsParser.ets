import { CmsVideoBrief, CmsVodRaw, Episode, PlayRoute } from '../../models/cms/MaccmsModels';

/**
 * vod_play_url 解析(纯函数,移植自 any-reader maccms.ts):
 * - vod_play_from 按 $$$ 分线路,vod_play_url 对应索引同样分线路
 * - 每条线路按 # 分集,每集按 $ 分「名$址」
 * - 跨线路 URL 前缀去重;仅保留首集为 .mp4/.m3u8 的线路
 */
export class MaccmsParser {
  static readonly PLAYABLE = /\.(mp4|m3u8)/;

  /** 解析线路与集数;解析失败返回空数组 */
  static parsePlayRoutes(playFrom?: string, playUrl?: string): PlayRoute[] {
    if (!playFrom || !playUrl) {
      return [];
    }
    const fromList = playFrom.split('$$$');
    const urlList = playUrl.split('$$$');
    const acceptedPrefixes: string[] = [];
    const routes: PlayRoute[] = [];
    for (let i = 0; i < fromList.length && i < urlList.length; i++) {
      const route = MaccmsParser.parseOneRoute(i, fromList[i], urlList[i], acceptedPrefixes);
      if (route !== null) {
        routes.push(route);
      }
    }
    return routes;
  }

  private static parseOneRoute(routeIndex: number, name: string, urlSegment: string,
    acceptedPrefixes: string[]): PlayRoute | null {
    const episodes: Episode[] = [];
    const parts = urlSegment.split('#');
    for (let i = 0; i < parts.length; i++) {
      const seg = parts[i].trim();
      if (seg.length === 0) {
        continue;
      }
      const dollar = seg.indexOf('$');
      let key: string;
      let value: string;
      if (dollar >= 0) {
        key = seg.substring(0, dollar).trim();
        value = seg.substring(dollar + 1).trim();
        if (key.length === 0) {
          key = String(i + 1);
        }
        if (value.length === 0) {
          value = key;
        }
      } else {
        key = String(i + 1);
        value = seg;
      }
      if (MaccmsParser.isDuplicatePrefix(value, acceptedPrefixes)) {
        continue;
      }
      acceptedPrefixes.push(MaccmsParser.urlPrefix(value));
      episodes.push({ index: episodes.length, name: key, url: value });
    }
    if (episodes.length === 0) {
      return null;
    }
    // 仅当保留下来的第一集是可直连播放的流才收录整条线路
    if (!MaccmsParser.PLAYABLE.test(episodes[0].url)) {
      return null;
    }
    return { index: routeIndex, name: name.trim().length > 0 ? name.trim() : `线路${routeIndex + 1}`, episodes };
  }

  /** 提取 URL 去重前缀:去掉协议头、去尾空白、截断 query */
  private static urlPrefix(url: string): string {
    let u = url;
    const proto = u.indexOf('//');
    if (proto >= 0) {
      u = u.substring(proto + 2);
    }
    const q = u.indexOf('?');
    if (q >= 0) {
      u = u.substring(0, q);
    }
    return u.toLowerCase();
  }

  private static isDuplicatePrefix(url: string, acceptedPrefixes: string[]): boolean {
    const prefix = MaccmsParser.urlPrefix(url);
    for (let i = 0; i < acceptedPrefixes.length; i++) {
      if (prefix.startsWith(acceptedPrefixes[i]) || acceptedPrefixes[i].startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  /** 清洗 vod_content 里的 HTML 标签与实体 */
  static cleanDescription(raw?: string): string {
    if (!raw) {
      return '';
    }
    let text = raw.replace(/<[^>]+>/g, '');
    text = text.replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#\d+;/g, '');
    return text.trim();
  }

  /** 上游 raw → 领域模型 */
  static toBrief(raw: CmsVodRaw, sourceId: number): CmsVideoBrief {
    const brief: CmsVideoBrief = {
      sourceId: sourceId,
      vodId: raw.vod_id,
      title: raw.vod_name ?? `未知-${raw.vod_id}`,
      cover: raw.vod_pic ?? '',
      category: raw.type_name ?? '',
      remarks: raw.vod_remarks ?? '',
      year: raw.vod_year ?? ''
    };
    return brief;
  }
}
