import { relationalStore } from '@kit.ArkData';
import { DatabaseHelper, WatchHistoryRow } from './DatabaseHelper';

export interface WatchSnapshot {
  cmsSourceId: number;
  vodId: number;
  title: string;
  cover: string;
  routeIndex: number;
  routeName: string;
  episodeIndex: number;
  episodeName: string;
  positionMs: number;
  durationMs: number;
  finished: boolean;
}

export class WatchHistoryDao {
  static async save(snap: WatchSnapshot): Promise<void> {
    await DatabaseHelper.get().executeSql(
      `INSERT INTO watch_history (cms_source_id, vod_id, title, cover, route_index, route_name,
         episode_index, episode_name, position_ms, duration_ms, finished, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(cms_source_id, vod_id) DO UPDATE SET
       title = excluded.title, cover = excluded.cover, route_index = excluded.route_index,
       route_name = excluded.route_name, episode_index = excluded.episode_index,
       episode_name = excluded.episode_name, position_ms = excluded.position_ms,
       duration_ms = excluded.duration_ms, finished = excluded.finished,
       updated_at = excluded.updated_at`,
      [snap.cmsSourceId, snap.vodId, snap.title, snap.cover, snap.routeIndex, snap.routeName,
        snap.episodeIndex, snap.episodeName, snap.positionMs, snap.durationMs,
        snap.finished ? 1 : 0, Date.now()]);
  }

  static async get(cmsSourceId: number, vodId: number): Promise<WatchHistoryRow | null> {
    const resultSet = await DatabaseHelper.get().querySql(
      'SELECT * FROM watch_history WHERE cms_source_id = ? AND vod_id = ?', [cmsSourceId, vodId]);
    let row: WatchHistoryRow | null = null;
    if (resultSet.goToNextRow()) {
      row = WatchHistoryDao.readRow(resultSet);
    }
    resultSet.close();
    return row;
  }

  static async listRecent(limit: number = 50): Promise<WatchHistoryRow[]> {
    const resultSet = await DatabaseHelper.get().querySql(
      'SELECT * FROM watch_history ORDER BY updated_at DESC LIMIT ?', [limit]);
    const rows: WatchHistoryRow[] = [];
    while (resultSet.goToNextRow()) {
      rows.push(WatchHistoryDao.readRow(resultSet));
    }
    resultSet.close();
    return rows;
  }

  static async remove(cmsSourceId: number, vodId: number): Promise<void> {
    await DatabaseHelper.get().executeSql(
      'DELETE FROM watch_history WHERE cms_source_id = ? AND vod_id = ?', [cmsSourceId, vodId]);
  }

  private static readRow(resultSet: relationalStore.ResultSet): WatchHistoryRow {
    return {
      id: resultSet.getLong(resultSet.getColumnIndex('id')),
      cmsSourceId: resultSet.getLong(resultSet.getColumnIndex('cms_source_id')),
      vodId: resultSet.getLong(resultSet.getColumnIndex('vod_id')),
      title: resultSet.getString(resultSet.getColumnIndex('title')),
      cover: resultSet.getString(resultSet.getColumnIndex('cover')),
      routeIndex: resultSet.getLong(resultSet.getColumnIndex('route_index')),
      routeName: resultSet.getString(resultSet.getColumnIndex('route_name')),
      episodeIndex: resultSet.getLong(resultSet.getColumnIndex('episode_index')),
      episodeName: resultSet.getString(resultSet.getColumnIndex('episode_name')),
      positionMs: resultSet.getLong(resultSet.getColumnIndex('position_ms')),
      durationMs: resultSet.getLong(resultSet.getColumnIndex('duration_ms')),
      finished: resultSet.getLong(resultSet.getColumnIndex('finished')) === 1,
      updatedAt: resultSet.getLong(resultSet.getColumnIndex('updated_at'))
    };
  }
}
