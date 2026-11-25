/** AnimeGarden 资源模型 */

export interface GardenResource {
  id: number;
  provider: string; // dmhy / moe / mikan / ani
  title: string;
  type: string;
  magnet: string;
  size: number; // 字节
  fansub: string;
  publisher: string;
  createdAt: string;
}
