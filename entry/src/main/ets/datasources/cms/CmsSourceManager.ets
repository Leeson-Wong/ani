import { relationalStore } from '@kit.ArkData';
import { DatabaseHelper, CmsSourceRow } from '../../db/DatabaseHelper';
import { MaccmsClient } from './MaccmsClient';
import { CandidateProbeResult, CmsVodResp, CmsVideoBrief, ProbeResult } from '../../models/cms/MaccmsModels';
import { HttpClient } from '../http/HttpClient';
import { AppError } from '../../common/AppError';
import { Log } from '../../common/Logger';

export interface SearchAllResult {
  source: CmsSourceRow;
  items: CmsVideoBrief[];
  error: string;
}

/** 深探测(播放链路验证)的结果 */
interface PlayCheck {
  ok: boolean;
  note: string;
}

/** 内置候选源池(2026-11-25 实测:仅 360/金鹰 双 ✓,其余 API 或 CDN 已死;
 *  源会复活/漂移,保留全量由「探测候选」按当时网络实测筛选,不在表里的才显示) */
const CANDIDATE_SOURCES: string[][] = [
  ['360资源', 'https://360zy.com/api.php/provide/vod'],
  ['金鹰', 'https://jyzyapi.com/api.php/provide/vod'],
  ['非凡', 'https://api.ffzyapi.com/api.php/provide/vod'],
  ['老鸭', 'https://api.apibdzy.com/api.php/provide/vod'],
  ['暴风', 'https://bfzy.tv/api.php/provide/vod'],
  ['量子', 'https://cj.lziapi.com/api.php/provide/vod'],
  ['天空', 'https://api.tiankongapi.com/api.php/provide/vod'],
  ['魔爪', 'https://mozhuazy.com/api.php/provide/vod'],
  ['豆瓣', 'https://dbzy.tv/api.php/provide/vod'],
  ['闪电', 'https://sdzyapi.com/api.php/provide/vod'],
  ['卧龙', 'https://collect.wolongzy.cc/api.php/provide/vod'],
  ['红牛', 'https://caiji.hongniuzy2.com/api.php/provide/vod'],
  ['无一', 'https://collect.wuyouzy.cc/api.php/provide/vod'],
  ['看点', 'https://kankanzyapi.com/api.php/provide/vod'],
  ['优质', 'https://api.1080zyku.com/api.php/provide/vod'],
  ['樱桃', 'https://api.yinghuazy.mobi/api.php/provide/vod'],
  ['快车', 'https://caiji.kuaichezy.org/api.php/provide/vod'],
  ['雨后', 'https://caiji.yuhouzy.com/api.php/provide/vod'],
  ['海盗', 'https://caiji.haizhizy.com/api.php/provide/vod'],
  ['速播', 'https://subocaiji.com/api.php/provide/vod'],
  ['天气', 'https://tyyszy.com/api.php/provide/vod'],
  ['极速', 'https://jszyapi.com/api.php/provide/vod']
];

/** 多源管理:CRUD(落 cms_sources 表)+ 可用性探测 + 流式并行搜索 + 候选源池 */
export class CmsSourceManager {
  private static rowToSource(resultSet: relationalStore.ResultSet): CmsSourceRow {
    return {
      id: resultSet.getLong(resultSet.getColumnIndex('id')),
      name: resultSet.getString(resultSet.getColumnIndex('name')),
      apiBase: resultSet.getString(resultSet.getColumnIndex('api_base')),
      format: resultSet.getString(resultSet.getColumnIndex('format')),
      enabled: resultSet.getLong(resultSet.getColumnIndex('enabled')) === 1,
      sort: resultSet.getLong(resultSet.getColumnIndex('sort')),
      failCount: resultSet.getLong(resultSet.getColumnIndex('fail_count')),
      autoOff: resultSet.getLong(resultSet.getColumnIndex('auto_off')) === 1
    };
  }

  static async list(): Promise<CmsSourceRow[]> {
    const resultSet = await DatabaseHelper.get().querySql(
      'SELECT * FROM cms_sources ORDER BY sort, id');
    const rows: CmsSourceRow[] = [];
    while (resultSet.goToNextRow()) {
      rows.push(CmsSourceManager.rowToSource(resultSet));
    }
    resultSet.close();
    return rows;
  }

  static async listEnabled(): Promise<CmsSourceRow[]> {
    const all = await CmsSourceManager.list();
    return all.filter((s: CmsSourceRow) => s.enabled);
  }

  static async add(name: string, apiBase: string): Promise<number> {
    const normalized = apiBase.trim();
    const store = DatabaseHelper.get();
    const all = await CmsSourceManager.list();
    const values: relationalStore.ValuesBucket = {
      'name': name.trim().length > 0 ? name.trim() : `源${all.length + 1}`,
      'api_base': normalized,
      'format': 'json',
      'enabled': 1,
      'sort': all.length,
      'created_at': Date.now()
    };
    return await store.insert('cms_sources', values);
  }

  static async remove(id: number): Promise<void> {
    await DatabaseHelper.get().executeSql('DELETE FROM cms_sources WHERE id = ?', [id]);
  }

  /** 启停。手动开启同时清掉自动停用标记与失败计数(用户明确给了机会) */
  static async setEnabled(id: number, enabled: boolean): Promise<void> {
    if (enabled) {
      await DatabaseHelper.get().executeSql(
        'UPDATE cms_sources SET enabled = 1, auto_off = 0, fail_count = 0 WHERE id = ?', [id]);
      return;
    }
    await DatabaseHelper.get().executeSql('UPDATE cms_sources SET enabled = 0 WHERE id = ?', [id]);
  }

  /** 探测源可用性。
   *  浅探测(默认):能拉到合法信封且有分类即视为可用(ac=list 是分类的标准返回模式)。
   *  深探测(deep=true):再抽一集验证 m3u8 直链可拉——「API 活但 CDN 死」的源(老鸭/非凡模式)会现形。 */
  static async probe(apiBase: string, deep: boolean = false): Promise<ProbeResult> {
    try {
      const sep = apiBase.indexOf('?') >= 0 ? '&' : '?';
      const resp = await HttpClient.getJson<CmsVodResp>(`${apiBase}${sep}ac=list&pg=1`, undefined,
        { connectMs: 5000, readMs: 8000 });
      if (resp.code !== undefined && resp.code !== 1) {
        const fail: ProbeResult = { ok: false, categories: 0, message: `站点返回错误码 ${resp.code}` };
        return fail;
      }
      let cats = 0;
      if (resp.class !== undefined && resp.class.length > 0) {
        cats = resp.class.length;
      }
      if (!deep) {
        if (cats > 0) {
          const okResult: ProbeResult = { ok: true, categories: cats, message: '可用' };
          return okResult;
        }
        if (resp.list !== undefined) {
          const okResult: ProbeResult = { ok: true, categories: 0, message: '可用(无分类列表)' };
          return okResult;
        }
        const invalid: ProbeResult = { ok: false, categories: 0, message: '响应格式不符合苹果CMS' };
        return invalid;
      }
      const play = await CmsSourceManager.probePlay(apiBase, sep);
      if (play.ok) {
        const okResult: ProbeResult = { ok: true, categories: cats, message: `可用·播放验证通过(${play.note})` };
        return okResult;
      }
      const apiOnly: ProbeResult = { ok: false, categories: cats, message: `API 活跃,但${play.note}` };
      return apiOnly;
    } catch (e) {
      const err = AppError.from(e as Object);
      const fail: ProbeResult = { ok: false, categories: 0, message: err.message };
      return fail;
    }
  }

  /** 抽第 1 页的一集验证播放直链(m3u8/mp4 可拉 = 播放链路通) */
  private static async probePlay(apiBase: string, sep: string): Promise<PlayCheck> {
    try {
      const det = await HttpClient.getJson<CmsVodResp>(`${apiBase}${sep}ac=detail&pg=1`, undefined,
        { connectMs: 5000, readMs: 8000 });
      const list = det.list ?? [];
      let ep = '';
      for (const v of list) {
        const pu = v.vod_play_url ?? '';
        if (pu.indexOf('.m3u8') >= 0 || pu.indexOf('.mp4') >= 0) {
          ep = pu.split('#')[0].split('$').pop() ?? '';
          break;
        }
      }
      if (ep.length === 0 || ep.indexOf('http') !== 0) {
        const noUrl: PlayCheck = { ok: false, note: '第 1 页没有 http 直链' };
        return noUrl;
      }
      const text = await HttpClient.getText(ep, undefined, { connectMs: 5000, readMs: 8000 });
      if (text.indexOf('#EXTM3U') >= 0) {
        const segCount = text.split('#EXTINF').length - 1;
        const enc = text.indexOf('AES-128') >= 0 ? 'AES-128' : '明文';
        const ok: PlayCheck = { ok: true, note: `${segCount} 段·${enc}` };
        return ok;
      }
      const pageLike: PlayCheck = { ok: false, note: '播放地址是网页而非直链' };
      return pageLike;
    } catch (e) {
      const err = AppError.from(e as Object);
      const fail: PlayCheck = { ok: false, note: `播放链路不通(${err.message})` };
      return fail;
    }
  }

  /** 批量深探测内置候选池(跳过已在表里的),并行执行,可用者优先 */
  static async probeCandidates(): Promise<CandidateProbeResult[]> {
    const existing = await CmsSourceManager.list();
    const existingBases: string[] = [];
    for (const s of existing) {
      existingBases.push(s.apiBase);
    }
    const results: CandidateProbeResult[] = [];
    const tasks: Promise<void>[] = [];
    for (const cand of CANDIDATE_SOURCES) {
      if (existingBases.indexOf(cand[1]) >= 0) {
        continue;
      }
      const task = CmsSourceManager.probe(cand[1], true).then((p: ProbeResult) => {
        const r: CandidateProbeResult = {
          name: cand[0], apiBase: cand[1], ok: p.ok, categories: p.categories, message: p.message
        };
        results.push(r);
      }).catch((e: Object) => {
        const r: CandidateProbeResult = {
          name: cand[0], apiBase: cand[1], ok: false, categories: 0, message: `${e}`
        };
        results.push(r);
      });
      tasks.push(task);
    }
    await Promise.all(tasks);
    results.sort((a: CandidateProbeResult, b: CandidateProbeResult) => {
      if (a.ok !== b.ok) {
        return a.ok ? -1 : 1;
      }
      return a.name.localeCompare(b.name, 'zh');
    });
    return results;
  }

  /** 把一个候选加进源表(已存在同 api_base 时返回 false) */
  static async addCandidate(name: string, apiBase: string): Promise<boolean> {
    const all = await CmsSourceManager.list();
    for (const s of all) {
      if (s.apiBase === apiBase) {
        return false;
      }
    }
    await CmsSourceManager.add(name, apiBase);
    return true;
  }

  /** 全部启用源并行搜索,每源完成即回调(渐进渲染);全部结束返回完整结果 */
  static async searchAllStream(keyword: string,
    onResult: (r: SearchAllResult) => void): Promise<SearchAllResult[]> {
    const sources = await CmsSourceManager.listEnabled();
    const tasks: Promise<SearchAllResult>[] = sources.map(
      (source: CmsSourceRow) => {
        const client = new MaccmsClient(source.id, source.apiBase);
        return client.search(keyword, 1).then((items: CmsVideoBrief[]) => {
          const ok: SearchAllResult = { source: source, items: items, error: '' };
          onResult(ok);
          return ok;
        }).catch((e: Object) => {
          Log.warn('cms search failed', source.name, `${e}`);
          const failed: SearchAllResult = { source: source, items: [] as CmsVideoBrief[], error: `${e}` };
          onResult(failed);
          return failed;
        });
      });
    return await Promise.all(tasks);
  }

  /** 兼容旧调用:等全部源返回 */
  static async searchAll(keyword: string): Promise<SearchAllResult[]> {
    return await CmsSourceManager.searchAllStream(keyword, (_r: SearchAllResult) => {
    });
  }
}
