/** 直播(IPTV)模型 */

export interface LiveChannel {
  name: string;
  group: string;
  urls: string[]; // 多源聚合,高清优先(名称含 1080 优先、720 次之)
}

export interface LivePlaylist {
  channels: LiveChannel[];
  groups: string[];
}
