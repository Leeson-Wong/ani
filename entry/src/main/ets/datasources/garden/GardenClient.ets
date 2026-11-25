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
}
