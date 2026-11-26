/** AnimeGarden 资源模型 */

export interface GardenResource {
  id: number;
  provider: string; // dmhy / moe / mikan / ani
  title: string;
  type: string;
  magnet: string;
  tracker: string; // 资源自带的 tracker 追加串(tr=...,拼接在 magnet 后即完整磁力)
  size: number; // 字节
  fansub: string;
  publisher: string;
  createdAt: string;
}
