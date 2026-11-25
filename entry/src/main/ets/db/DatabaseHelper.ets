import { relationalStore } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { Log } from '../common/Logger';

export interface CmsSourceRow {
  id: number;
  name: string;
  apiBase: string;
  format: string; // 'json' | 'xml'
  enabled: boolean;
  sort: number;
}

export interface ShelfBookRow {
  id: number;
  source: string;
  bookId: string;
  title: string;
  author: string;
  cover: string;
  addedAt: number;
  lastReadAt: number;
}

export interface ReadProgressRow {
  id: number;
  source: string;
  bookId: string;
  chapterId: string;
  chapterIndex: number;
  pageInChapter: number;
  percent: number;
  updatedAt: number;
}

export interface WatchHistoryRow {
  id: number;
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
  updatedAt: number;
}

interface DbSchema {
  version: number;
  statements: string[];
}

const SCHEMAS: DbSchema[] = [
  {
    version: 1,
    statements: [
      `CREATE TABLE IF NOT EXISTS shelf_books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source TEXT NOT NULL,
        book_id TEXT NOT NULL,
        title TEXT NOT NULL,
        author TEXT,
        cover TEXT,
        added_at INTEGER,
        last_read_at INTEGER,
        UNIQUE(source, book_id))`,
      `CREATE TABLE IF NOT EXISTS read_progress (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source TEXT NOT NULL,
        book_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        chapter_index INTEGER NOT NULL,
        page_in_chapter INTEGER,
        percent REAL,
        updated_at INTEGER,
        UNIQUE(source, book_id))`,
      `CREATE TABLE IF NOT EXISTS watch_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cms_source_id INTEGER NOT NULL,
        vod_id INTEGER NOT NULL,
        title TEXT,
        cover TEXT,
        route_index INTEGER,
        route_name TEXT,
        episode_index INTEGER,
        episode_name TEXT,
        position_ms INTEGER,
        duration_ms INTEGER,
        finished INTEGER DEFAULT 0,
        updated_at INTEGER,
        UNIQUE(cms_source_id, vod_id))`,
      `CREATE TABLE IF NOT EXISTS cms_sources (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        api_base TEXT NOT NULL,
        format TEXT NOT NULL DEFAULT 'json',
        enabled INTEGER NOT NULL DEFAULT 1,
        sort INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER)`
    ]
  },
  {
    // v2(2026-10):量子/暴风死链重灾区,换成实测可用的 360/速播
    version: 2,
    statements: [
      `DELETE FROM cms_sources WHERE api_base IN
        ('https://cj.lziapi.com/api.php/provide/vod',
         'https://by.bfzyapi.com/api.php/provide/vod')`,
      `DELETE FROM cms_sources WHERE api_base IN
        ('https://360zy.com/api.php/provide/vod',
         'https://subocaiji.com/api.php/provide/vod')`,
      `INSERT INTO cms_sources (name, api_base, format, enabled, sort, created_at) VALUES
        ('360资源', 'https://360zy.com/api.php/provide/vod', 'json', 1, 0, 0)`,
      `INSERT INTO cms_sources (name, api_base, format, enabled, sort, created_at) VALUES
        ('速播', 'https://subocaiji.com/api.php/provide/vod', 'json', 1, 1, 0)`
    ]
  },
  {
    // v3(2026-11-25):速播 CDN 全网络不可达,剔除;金鹰(jyzyapi)实测 API+CDN+AES-128 播放可用,加入
    version: 3,
    statements: [
      `DELETE FROM cms_sources WHERE api_base IN
        ('https://subocaiji.com/api.php/provide/vod',
         'https://jyzyapi.com/api.php/provide/vod')`,
      `INSERT INTO cms_sources (name, api_base, format, enabled, sort, created_at) VALUES
        ('金鹰', 'https://jyzyapi.com/api.php/provide/vod', 'json', 1, 2, 0)`
    ]
  }
];

/** 内置 CMS 源(新装机用;已装机走迁移):2026-11-25 实测 API+CDN 播放均可用 */
const BUILTIN_SOURCES: string[][] = [
  ['360资源', 'https://360zy.com/api.php/provide/vod'],
  ['金鹰', 'https://jyzyapi.com/api.php/provide/vod']
];

export class DatabaseHelper {
  private static store: relationalStore.RdbStore | null = null;

  static async init(context: Context): Promise<relationalStore.RdbStore> {
    if (DatabaseHelper.store !== null) {
      return DatabaseHelper.store;
    }
    const config: relationalStore.StoreConfig = {
      name: 'entry_db.db',
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store = await relationalStore.getRdbStore(context, config);
    await DatabaseHelper.migrate(store);
    await DatabaseHelper.seedBuiltinSources(store);
    DatabaseHelper.store = store;
    Log.info('database ready, version', `${store.version}`);
    return store;
  }

  static get(): relationalStore.RdbStore {
    if (DatabaseHelper.store === null) {
      throw new Error('database not initialized');
    }
    return DatabaseHelper.store;
  }

  private static async migrate(store: relationalStore.RdbStore): Promise<void> {
    let current = store.version;
    for (const schema of SCHEMAS) {
      if (current < schema.version) {
        for (const sql of schema.statements) {
          await store.executeSql(sql);
        }
        current = schema.version;
      }
    }
    store.version = current;
  }

  private static async seedBuiltinSources(store: relationalStore.RdbStore): Promise<void> {
    const resultSet = await store.querySql('SELECT COUNT(*) AS c FROM cms_sources');
    let count = 0;
    if (resultSet.goToNextRow()) {
      count = resultSet.getLong(resultSet.getColumnIndex('c'));
    }
    resultSet.close();
    if (count > 0) {
      return;
    }
    const now = Date.now();
    for (let i = 0; i < BUILTIN_SOURCES.length; i++) {
      const item = BUILTIN_SOURCES[i];
      const values: relationalStore.ValuesBucket = {
        'name': item[0],
        'api_base': item[1],
        'format': 'json',
        'enabled': 1,
        'sort': i,
        'created_at': now
      };
      await store.insert('cms_sources', values);
    }
    Log.info('seeded builtin cms sources');
  }
}
