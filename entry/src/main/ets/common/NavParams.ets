/** Navigation 路由参数(ArkTS 要求对象字面量对应显式接口) */

export interface NovelDetailNavParam {
  bookId: string;
  title: string;
  author: string;
  cover: string;
  intro: string;
}

export interface ReaderNavParam {
  bookId: string;
  bookTitle: string;
  startChapterIndex: number; // -1 = 从进度续读
  startPage: number;
}

export interface VideoDetailNavParam {
  sourceId: number;
  vodId: number;
  title: string;
  cover: string;
  remarks: string;
}

export interface PlayerNavParam {
  sourceId: number;
  vodId: number;
  title: string;
  cover: string;
  routesJson: string; // PlayRoute[] 序列化传递
  routeIndex: number;
  episodeIndex: number;
  resumePositionMs: number;
  localPath: string; // 非空 = 播本地离线文件(该集已下载);换集后即失效回到在线
}

export interface MangaDetailNavParam {
  pathWord: string;
  name: string;
  cover: string;
}

export interface MangaReaderNavParam {
  pathWord: string;
  comicName: string;
  startChapterUuid: string; // '' = 从进度/第一话
}

export interface LivePlayNavParam {
  channelsJson: string; // LiveChannel[] 序列化
  startIndex: number;
}
