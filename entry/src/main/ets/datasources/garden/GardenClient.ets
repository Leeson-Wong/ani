import { HttpClient } from '../http/HttpClient';
import { asObj, jArr, jNum, jObj, jStr } from '../../common/Json';
import { AppError } from '../../common/AppError';
import { GardenResource } from '../../models/garden/GardenModels';

/** AnimeGarden 开放 API(https://api.animes.garden,无需鉴权)客户端 */
export class GardenClient {
  private static readonly BASE = 'https://api.animes.garden';

  /**
   * 资源列表:keyword 全包含过滤 + 分页(默认按时间倒序)
   */
  static async resources(keyword: string, page: number = 1, pageSize: number = 25): Promise<GardenResource[]> {
    const q = keyword.trim().length > 0 ? `&search=${encodeURIComponent(keyword.trim())}` : '';
    const url = `${GardenClient.BASE}/resources?page=${page}&pageSize=${pageSize}${q}`;
    const text = await HttpClient.getText(url);
    const envelope = JSON.parse(text) as Record<string, Object>;
    const status = jStr(envelope, 'status');
    if (status.length > 0 && status !== 'OK') {
      throw new AppError(`AnimeGarden 接口错误:${status}`);
    }
    const out: GardenResource[] = [];
    for (const raw of jArr(envelope, 'resources')) {
      const r = asObj(raw);
      if (r === undefined) {
        continue;
      }
      const fansub = jObj(r, 'fansub');
      const publisher = jObj(r, 'publisher');
      const item: GardenResource = {
        id: jNum(r, 'id'),
        provider: jStr(r, 'provider'),
        title: jStr(r, 'title'),
        type: jStr(r, 'type'),
        magnet: jStr(r, 'magnet'),
        tracker: jStr(r, 'tracker'),
        size: jNum(r, 'size'),
        fansub: fansub !== undefined ? jStr(fansub, 'name') : '',
        publisher: publisher !== undefined ? jStr(publisher, 'name') : '',
        createdAt: jStr(r, 'createdAt')
      };
      if (item.magnet.length > 0) {
        out.push(item);
      }
    }
    return out;
  }

  /**
   * 按 infohash 查详情(BT 元数据第一级:detail.magnets[] 里找 .torrent 的 HTTPS 直链)。
   *  实测 mikan/moe 镜像可达;dmhy 的 dl.dmhy.org 部分网络不可达。
   */
  static async detailByInfohash(infoHashHex: string): Promise<GardenDetail> {
    const text = await HttpClient.getText(`${GardenClient.BASE}/detail/infohash/${infoHashHex}`,
      undefined, { connectMs: 6000, readMs: 12000, quiet: true });
    const envelope = JSON.parse(text) as Record<string, Object>;
    const status = jStr(envelope, 'status');
    if (status.length > 0 && status !== 'OK') {
      throw new AppError(`AnimeGarden 详情接口错误:${status}`);
    }
    const r = jObj(envelope, 'resource');
    if (r === undefined) {
      throw new AppError('详情接口未返回该资源');
    }
    let torrentUrl = '';
    let fullMagnet = '';
    const detail = jObj(envelope, 'detail');
    if (detail !== undefined) {
      for (const raw of jArr(detail, 'magnets')) {
        const m = asObj(raw);
        if (m === undefined) {
          continue;
        }
        const u = jStr(m, 'url');
        if (torrentUrl.length === 0 && /^https?:/i.test(u)) {
          torrentUrl = u;
        } else if (fullMagnet.length === 0 && u.startsWith('magnet:')) {
          fullMagnet = u;
        }
      }
    }
    if (fullMagnet.length === 0) {
      // 资源自带的 tracker 是 "tr=xxx&tr=yyy" 追加串,直接拼在 magnet 后
      fullMagnet = `${jStr(r, 'magnet')}${jStr(r, 'tracker')}`;
    }
    const out: GardenDetail = {
      title: jStr(r, 'title'),
      provider: jStr(r, 'provider'),
      torrentUrl: torrentUrl,
      fullMagnet: fullMagnet
    };
    return out;
  }
}

/** AnimeGarden 资源详情(BT 诊断/下载的元数据入口) */
export interface GardenDetail {
  title: string;
  provider: string;
  /** .torrent 文件 HTTPS 直链('' = 详情里没有) */
  torrentUrl: string;
  /** 含资源自带 tr= 的完整磁力('' = 详情里没有) */
  fullMagnet: string;
}
