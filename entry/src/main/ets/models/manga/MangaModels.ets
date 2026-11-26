/** copymanga(拷贝漫画)领域模型 */

export interface MangaBrief {
  pathWord: string;
  name: string;
  cover: string;
  author: string;
  popular: number;
  updatedAt: string;
}

/** 分类筛选 chip(label 中文,value 传 comicsList 的 theme;各源自备一份) */
export interface MangaTheme {
  label: string;
  value: string;
}

export interface MangaRankItem extends MangaBrief {
  sort: number;
}

export interface MangaHome {
  dayRank: MangaRankItem[];
  weekRank: MangaRankItem[];
  monthRank: MangaRankItem[];
  newComics: MangaBrief[];
  finishComics: MangaBrief[];
}

export interface MangaDetail {
  pathWord: string;
  name: string;
  cover: string;
  author: string;
  description: string;
  themes: string[];
  popular: number;
  updatedAt: string;
  groups: string[]; // 分组(默认 default)
}

export interface MangaChapter {
  uuid: string;
  name: string;
  index: number; // 0 = 最新(copymanga 章节列表倒序)
  size: number; // 页数
}

/** 阅读一话:已按真实页码排序的图片 URL 列表 */
export interface MangaChapterImages {
  chapterUuid: string;
  chapterName: string;
  images: string[];
  prevUuid: string;
  nextUuid: string;
}

/** 整部漫画的离线快照:详情+完整章节列表(详情页/阅读器离线兜底的数据源) */
export interface ComicSnapshot {
  detail: MangaDetail;
  chapters: MangaChapter[];
  savedAt: number; // epoch ms,判断快照新旧
}
