import { MangaClient } from './MangaClient';
import { MkzhanClient } from './MkzhanClient';
import { Prefs } from '../../db/Prefs';
import {
  MangaBrief, MangaChapter, MangaChapterImages, MangaDetail, MangaHome, MangaTheme
} from '../../models/manga/MangaModels';

/**
 * 漫画数据源抽象(多源切换的地基):
 *  - 模型(MangaBrief/MangaDetail/MangaChapter/MangaChapterImages)全源共用;
 *  - pathWord 即各源自有 id(copymanga slug / mkzhan 数字串),不同源不冲突,缓存 key 无需加源前缀;
 *  - themes() 返回各源自己的分类 chips(label 中文,value 传 comicsList 的 theme)。
 */
export interface MangaSource {
  /** 稳定 id(存 Prefs / 后续导航参数) */
  id: string;
  /** 展示名(源切换菜单) */
  name: string;
  /** 分类筛选 chips */
  themes(): MangaTheme[];
  home(): Promise<MangaHome>;
  comicsList(theme: string, ordering: string, offset: number, limit?: number): Promise<MangaBrief[]>;
  search(q: string, offset?: number, limit?: number): Promise<MangaBrief[]>;
  detail(pathWord: string): Promise<MangaDetail>;
  chapters(pathWord: string, group?: string): Promise<MangaChapter[]>;
  chapterImages(pathWord: string, chapterUuid: string): Promise<MangaChapterImages>;
}

/** copymanga 分类筛选:与原 MangaTabPage 内置列表一致(服务端主题列表接口不稳定,固定一份) */
const COPYMANGA_THEMES: MangaTheme[] = [
  { label: '全部', value: '' },
  { label: '恋爱', value: 'aiqing' },
  { label: '冒险', value: 'maoxian' },
  { label: '搞笑', value: 'gaoxiao' },
  { label: '奇幻', value: 'qihuan' },
  { label: '校园', value: 'xiaoyuan' },
  { label: '科幻', value: 'kehuan' },
  { label: '悬疑', value: 'xuanyi' },
  { label: '治愈', value: 'zhiyu' },
  { label: '热血', value: 'rexue' },
  { label: '少女', value: 'shaonv' },
  { label: '少年', value: 'shaonian' },
  { label: '百合', value: 'baihe' },
  { label: '耽美', value: 'danmei' },
  { label: '职场', value: 'zhichang' },
  { label: '恐怖', value: 'kongbu' }
];

/** copymanga(拷贝漫画)实现:薄包装,逐方法委托 MangaClient 静态实现,行为零变化 */
export class CopymangaSource implements MangaSource {
  readonly id: string = 'copymanga';
  readonly name: string = '拷贝漫画';

  themes(): MangaTheme[] {
    return COPYMANGA_THEMES;
  }

  home(): Promise<MangaHome> {
    return MangaClient.home();
  }

  comicsList(theme: string, ordering: string, offset: number, limit: number = 24): Promise<MangaBrief[]> {
    return MangaClient.comicsList(theme, ordering, offset, limit);
  }

  search(q: string, offset: number = 0, limit: number = 20): Promise<MangaBrief[]> {
    return MangaClient.search(q, offset, limit);
  }

  detail(pathWord: string): Promise<MangaDetail> {
    return MangaClient.detail(pathWord);
  }

  chapters(pathWord: string, group: string = 'default'): Promise<MangaChapter[]> {
    return MangaClient.chapters(pathWord, group);
  }

  chapterImages(pathWord: string, chapterUuid: string): Promise<MangaChapterImages> {
    return MangaClient.chapterImages(pathWord, chapterUuid);
  }
}

/** 漫客栈分类 chips(主题 id 见 MkzhanClient.THEME_NAMES;2026-11-26 实测) */
const MKZHAN_THEMES: MangaTheme[] = [
  { label: '全部', value: '' },
  { label: '霸总', value: '1' },
  { label: '修真', value: '2' },
  { label: '恋爱', value: '3' },
  { label: '校园', value: '4' },
  { label: '冒险', value: '5' },
  { label: '搞笑', value: '6' },
  { label: '生活', value: '7' },
  { label: '热血', value: '8' },
  { label: '架空', value: '9' },
  { label: '后宫', value: '10' },
  { label: '玄幻', value: '12' }
];

/** 漫客栈(mkzhan.com)实现:端点与结构见 MkzhanClient 头注释 */
export class MkzhanSource implements MangaSource {
  readonly id: string = 'mkzhan';
  readonly name: string = '漫客栈';

  themes(): MangaTheme[] {
    return MKZHAN_THEMES;
  }

  home(): Promise<MangaHome> {
    return MkzhanClient.home();
  }

  comicsList(theme: string, ordering: string, offset: number, limit: number = 30): Promise<MangaBrief[]> {
    return MkzhanClient.comicsList(theme, ordering, offset, limit);
  }

  search(q: string, offset: number = 0, limit: number = 20): Promise<MangaBrief[]> {
    return MkzhanClient.search(q, offset, limit);
  }

  detail(pathWord: string): Promise<MangaDetail> {
    return MkzhanClient.detail(pathWord);
  }

  chapters(pathWord: string, group: string = 'default'): Promise<MangaChapter[]> {
    return MkzhanClient.chapters(pathWord, group);
  }

  chapterImages(pathWord: string, chapterUuid: string): Promise<MangaChapterImages> {
    return MkzhanClient.chapterImages(pathWord, chapterUuid);
  }
}

/**
 * 漫画源注册表:页面一律经 MangaSources.current() 取源,不直接 import 具体客户端。
 * 当前源 id 存 Prefs(mangaSourceId),默认 copymanga。
 * 注册表惰性构建(首次访问才 new),不依赖类静态字段初始化顺序。
 */
export class MangaSources {
  private static registry: MangaSource[] | null = null;

  private static all(): MangaSource[] {
    if (MangaSources.registry === null) {
      const list: MangaSource[] = [];
      list.push(new CopymangaSource());
      list.push(new MkzhanSource());
      MangaSources.registry = list;
    }
    return MangaSources.registry;
  }

  static list(): MangaSource[] {
    return MangaSources.all();
  }

  static byId(id: string): MangaSource | undefined {
    return MangaSources.all().find((s: MangaSource) => s.id === id);
  }

  /** 当前源:Prefs 记录的 id;记录值已不在注册表(如源被移除)时回退第一个 */
  static current(): MangaSource {
    const id = Prefs.getMangaSourceId();
    const hit = MangaSources.byId(id);
    return hit !== undefined ? hit : MangaSources.all()[0];
  }
}
