import { relationalStore } from '@kit.ArkData';
import { DatabaseHelper } from '../../db/DatabaseHelper';
import { Prefs } from '../../db/Prefs';
import { NetWatch } from '../../common/NetWatch';
import { Log } from '../../common/Logger';
import { HttpClient } from '../http/HttpClient';
import { CmsVodResp } from '../../models/cms/MaccmsModels';

/**
 * 影视源健康分:连续网络层失败达阈值自动停用(防死源拖慢搜索/发现页),
 * 每日启动后台探测复活。只依赖 DatabaseHelper/HttpClient,避免与 CmsSourceManager 循环引用。
 * 计数规则:网络错误/5xx/响应非 JSON 计失败;4xx 与业务错误(如 vod 不存在)不计;任何成功清零。
 */
export class SourceHealth {
  private static readonly FAIL_LIMIT: number = 3;

  /** 请求成功:清零失败计数(仅在计数非零时写库,健康时零开销) */
  static recordOk(sourceId: number): void {
    let store: relationalStore.RdbStore;
    try {
      store = DatabaseHelper.get();
    } catch (e) {
      return;
    }
    store.executeSql('UPDATE cms_sources SET fail_count = 0 WHERE id = ? AND fail_count > 0', [sourceId])
      .catch((e: Object) => {
        Log.warn('source health recordOk failed', `${e}`);
      });
  }

  /** 请求失败:计数 +1;连续达阈值且当前启用 → 自动停用并打标 */
  static recordFail(sourceId: number): void {
    let store: relationalStore.RdbStore;
    try {
      store = DatabaseHelper.get();
    } catch (e) {
      return;
    }
    store.executeSql('UPDATE cms_sources SET fail_count = fail_count + 1 WHERE id = ?', [sourceId])
      .then(() => {
        return store.querySql('SELECT fail_count, enabled, auto_off FROM cms_sources WHERE id = ?', [sourceId]);
      })
      .then((rs: relationalStore.ResultSet) => {
        let fail = 0;
        let enabled = 1;
        let autoOff = 0;
        if (rs.goToNextRow()) {
          fail = rs.getLong(rs.getColumnIndex('fail_count'));
          enabled = rs.getLong(rs.getColumnIndex('enabled'));
          autoOff = rs.getLong(rs.getColumnIndex('auto_off'));
        }
        rs.close();
        if (fail >= SourceHealth.FAIL_LIMIT && enabled === 1 && autoOff === 0) {
          return store.executeSql('UPDATE cms_sources SET enabled = 0, auto_off = 1 WHERE id = ?', [sourceId])
            .then(() => {
              Log.warn('cms source auto disabled after consecutive failures', `id=${sourceId}`);
            });
        }
        return Promise.resolve();
      })
      .catch((e: Object) => {
        Log.warn('source health recordFail failed', `${e}`);
      });
  }

  /** 每日一次的后台复活(离线跳过);EntryAbility 在 DB+Prefs 双就绪后调用 */
  static maybeDailyRevive(): void {
    try {
      if (!NetWatch.get().online) {
        return;
      }
      const last = Prefs.getLastSourceRevive();
      const now = new Date().getTime();
      if (now - last < 24 * 3600 * 1000) {
        return;
      }
      Prefs.setLastSourceRevive(now);
      SourceHealth.reviveAutoOff().then((n: number) => {
        if (n > 0) {
          Log.info('cms sources revived', `count=${n}`);
        }
      }).catch((e: Object) => {
        Log.warn('revive auto-off sources failed', `${e}`);
      });
    } catch (e) {
      Log.warn('maybeDailyRevive skipped', `${e}`);
    }
  }

  /** 探测所有自动停用的源,轻探测通过的恢复启用 */
  static async reviveAutoOff(): Promise<number> {
    const store = DatabaseHelper.get();
    const rs = await store.querySql('SELECT id, api_base FROM cms_sources WHERE auto_off = 1');
    const ids: number[] = [];
    const bases: string[] = [];
    while (rs.goToNextRow()) {
      ids.push(rs.getLong(rs.getColumnIndex('id')));
      bases.push(rs.getString(rs.getColumnIndex('api_base')));
    }
    rs.close();
    let revived = 0;
    for (let i = 0; i < ids.length; i++) {
      if (await SourceHealth.lightProbe(bases[i])) {
        await store.executeSql(
          'UPDATE cms_sources SET enabled = 1, auto_off = 0, fail_count = 0 WHERE id = ?', [ids[i]]);
        revived++;
      }
    }
    return revived;
  }

  /** 轻探测:ac=list 拉到合法信封即算活(不验播放,快) */
  private static async lightProbe(apiBase: string): Promise<boolean> {
    try {
      const sep = apiBase.indexOf('?') >= 0 ? '&' : '?';
      const resp = await HttpClient.getJson<CmsVodResp>(`${apiBase}${sep}ac=list&pg=1`, undefined,
        { connectMs: 5000, readMs: 8000 });
      if (resp.code !== undefined && resp.code !== 1) {
        return false;
      }
      return resp.class !== undefined || resp.list !== undefined;
    } catch (e) {
      return false;
    }
  }
}
