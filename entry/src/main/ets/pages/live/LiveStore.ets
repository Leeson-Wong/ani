import { LivePlaylist } from '../../models/live/LiveModels';

/** 直播频道表缓存(进程级):tab 拉取,播放页复用 */
export class LiveStore {
  static playlist: LivePlaylist | null = null;
}
