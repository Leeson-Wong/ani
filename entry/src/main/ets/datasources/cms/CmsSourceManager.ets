import { relationalStore } from '@kit.ArkData';
import { DatabaseHelper, CmsSourceRow } from '../../db/DatabaseHelper';
import { MaccmsClient } from './MaccmsClient';
import { CmsVodResp, CmsVideoBrief, ProbeResult } from '../../models/cms/MaccmsModels';
import { HttpClient } from '../http/HttpClient';
import { Log } from '../../common/Logger';

export interface SearchAllResult {
  source: CmsSourceRow;
  items: CmsVideoBrief[];
  error: string;
}

/** 多源管理:CRUD(落 cms_sources 表)+ 可用性探测 + 并行搜索扇出 */
export class CmsSourceManager {
  private static rowToSource(resultSet: relationalStore.ResultSet): CmsSourceRow {
    return {
      id: resultSet.getLong(resultSet.getColumnIndex('id')),
      name: resultSet.getString(resultSet.getColumnIndex('name')),
      apiBase: resultSet.getString(resultSet.getColumnIndex('api_base')),
      format: resultSet.getString(resultSet.getColumnIndex('format')),
      enabled: resultSet.getLong(resultSet.getColumnIndex('enabled')) === 1,
      sort: resultSet.getLong(resultSet.getColumnIndex('sort'))
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

  static async setEnabled(id: number, enabled: boolean): Promise<void> {
    const bucket: relationalStore.ValuesBucket = { 'enabled': enabled ? 1 : 0 };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('cms_sources');
    predicates.equalTo('id', id);
    await DatabaseHelper.get().update(bucket, predicates);
  }

  /** 探测源可用性:能拉到合法信封且有分类即视为可用(ac=list 是分类的标准返回模式) */
  static async probe(apiBase: string): Promise<ProbeResult> {
    try {
      const sep = apiBase.indexOf('?') >= 0 ? '&' : '?';
      const resp = await HttpClient.getJson<CmsVodResp>(`${apiBase}${sep}ac=list&pg=1`);
      if (resp.code !== undefined && resp.code !== 1) {
        const fail: ProbeResult = { ok: false, categories: 0, message: `站点返回错误码 ${resp.code}` };
        return fail;
      }
      if (resp.class !== undefined && resp.class.length > 0) {
        const okResult: ProbeResult = { ok: true, categories: resp.class.length, message: '可用' };
        return okResult;
      }
      if (resp.list !== undefined) {
        const okResult: ProbeResult = { ok: true, categories: 0, message: '可用(无分类列表)' };
        return okResult;
      }
      const invalid: ProbeResult = { ok: false, categories: 0, message: '响应格式不符合苹果CMS' };
      return invalid;
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      const fail: ProbeResult = { ok: false, categories: 0, message: msg };
      return fail;
    }
  }

  /** 全部启用源并行搜索;单源失败吞掉并在结果里留空 */
  static async searchAll(keyword: string): Promise<SearchAllResult[]> {
    const sources = await CmsSourceManager.listEnabled();
    const tasks: Promise<SearchAllResult>[] = sources.map(
      (source: CmsSourceRow) => {
        const client = new MaccmsClient(source.id, source.apiBase);
        return client.search(keyword, 1).then((items: CmsVideoBrief[]) => {
          const ok: SearchAllResult = { source: source, items: items, error: '' };
          return ok;
        }).catch((e: Object) => {
          Log.warn('cms search failed', source.name, `${e}`);
          const failed: SearchAllResult = { source: source, items: [] as CmsVideoBrief[], error: `${e}` };
          return failed;
        });
      });
    return await Promise.all(tasks);
  }
}
