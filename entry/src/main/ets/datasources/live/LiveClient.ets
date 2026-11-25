import { HttpClient } from '../http/HttpClient';
import { AppError } from '../../common/AppError';
import { LiveChannel, LivePlaylist } from '../../models/live/LiveModels';

/** 内置直播源(iptv-org,实测可用);用户可在设置追加自定义 m3u */
const BUILTIN_M3U: string[] = [
  'https://iptv-org.github.io/iptv/languages/zho.m3u',
  'https://iptv-org.github.io/iptv/countries/cn.m3u'
];

interface RawEntry {
  name: string;
  group: string;
  url: string;
}

/** 聚合中间结构:url 与其来源名称的清晰度档位 */
interface UrlQuality {
  url: string;
  q: number;
}

interface AggChannel {
  name: string;
  group: string;
  urls: UrlQuality[];
}

/** iptv-org 英文分组 → 中文 */
const GROUP_MAP: Record<string, string> = {
  'animation': '动画', 'business': '财经', 'classic': '经典', 'culture': '文化',
  'documentary': '纪录', 'education': '教育', 'entertainment': '娱乐', 'food': '美食',
  'general': '综合', 'kids': '少儿', 'legislative': '议会', 'movies': '电影',
  'music': '音乐', 'news': '新闻', 'relax': '休闲', 'religious': '宗教',
  'series': '剧集', 'shopping': '购物', 'sports': '体育', 'travel': '旅行',
  'weather': '天气', 'undefined': ''
};

function guessGroup(name: string, groupTitle: string): string {
  const title = groupTitle.trim();
  if (title.length > 0) {
    const mapped = GROUP_MAP[title.toLowerCase()];
    if (mapped !== undefined && mapped.length > 0) {
      return mapped;
    }
    if (mapped === undefined && title.toLowerCase() !== 'undefined') {
      return title;
    }
  }
  const upper = name.toUpperCase();
  if (upper.indexOf('CCTV') >= 0) {
    return '央视';
  }
  if (name.indexOf('卫视') >= 0) {
    return '卫视';
  }
  if (upper.indexOf('CGTN') >= 0) {
    return '央视频道';
  }
  return '其他';
}

/** 分辨率档位:URL 无标注,档位来自频道名 */
function qualityRank(name: string): number {
  const n = name.toUpperCase();
  if (n.indexOf('1080') >= 0 || n.indexOf('FHD') >= 0) {
    return 0;
  }
  if (n.indexOf('720') >= 0 || n.indexOf('HD') >= 0 || n.indexOf('高清') >= 0) {
    return 1;
  }
  return 2;
}

/** 解析单个 m3u 文本 */
function parseM3U(text: string): RawEntry[] {
  const out: RawEntry[] = [];
  const lines = text.split('\n');
  let pendingName = '';
  let pendingGroup = '';
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.length === 0) {
      continue;
    }
    if (line.startsWith('#EXTINF')) {
      const commaIdx = line.lastIndexOf(',');
      pendingName = commaIdx >= 0 ? line.substring(commaIdx + 1).trim() : '';
      const g = line.match(/group-title="([^"]*)"/);
      pendingGroup = g !== null && g.length > 1 ? g[1] : '';
    } else if (line.startsWith('http')) {
      if (pendingName.length > 0) {
        out.push({ name: pendingName, group: pendingGroup, url: line });
      }
      pendingName = '';
      pendingGroup = '';
    }
  }
  return out;
}

/** 频道名规范化:去掉 (720p)/(HD) 等标注用于聚合与展示 */
function normalizeName(name: string): string {
  return name.replace(/[[(]\s*\d{3,4}p\s*[\])]/gi, '')
    .replace(/[([](FHD|HD|SD|高清|标清|超清)[\])]/gi, '')
    .trim();
}

export class LiveClient {
  /** 拉取并聚合全部内置源(+自定义源);单源失败吞掉 */
  static async playlist(extraUrls: string[] = []): Promise<LivePlaylist> {
    const urls: string[] = BUILTIN_M3U.concat(extraUrls);
    const tasks: Promise<RawEntry[] | null>[] = urls.map((u: string) => {
      return HttpClient.getText(u).then((text: string) => parseM3U(text)).catch(() => null);
    });
    const results = await Promise.all(tasks);
    const map = new Map<string, AggChannel>();
    for (const result of results) {
      if (result === null) {
        continue;
      }
      for (const e of result) {
        const display = normalizeName(e.name);
        if (display.length === 0) {
          continue;
        }
        let ch = map.get(display);
        if (ch === undefined) {
          const fresh: AggChannel = { name: display, group: guessGroup(display, e.group), urls: [] };
          map.set(display, fresh);
          ch = fresh;
        }
        if (ch.urls.findIndex((x: UrlQuality) => x.url === e.url) < 0) {
          const uq: UrlQuality = { url: e.url, q: qualityRank(e.name) };
          ch.urls.push(uq);
        }
      }
    }
    const channels: LiveChannel[] = [];
    map.forEach((ch: AggChannel) => {
      if (ch.urls.length === 0) {
        return;
      }
      ch.urls.sort((a: UrlQuality, b: UrlQuality) => a.q - b.q);
      const plain: string[] = [];
      for (const u of ch.urls) {
        plain.push(u.url);
      }
      const out: LiveChannel = { name: ch.name, group: ch.group, urls: plain };
      channels.push(out);
    });
    // 分组排序:央视/卫视优先,其余按中文序
    const groupOrder = (g: string): number => {
      if (g === '央视') {
        return 0;
      }
      if (g === '卫视') {
        return 1;
      }
      return 2;
    };
    channels.sort((a: LiveChannel, b: LiveChannel) => {
      const ga = groupOrder(a.group);
      const gb = groupOrder(b.group);
      if (ga !== gb) {
        return ga - gb;
      }
      return a.group.localeCompare(b.group, 'zh');
    });
    const groups: string[] = [];
    for (const ch of channels) {
      if (groups.indexOf(ch.group) < 0) {
        groups.push(ch.group);
      }
    }
    if (channels.length === 0) {
      throw new AppError('直播源全部不可用');
    }
    const playlist: LivePlaylist = { channels: channels, groups: groups };
    return playlist;
  }
}
