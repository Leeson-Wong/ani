import { media } from '@kit.MediaKit';
import { LocalProxy } from '../../common/LocalProxy';
import { Log } from '../../common/Logger';

export type PlayerState = 'idle' | 'init' | 'prepared' | 'playing' | 'paused' | 'stopped' | 'error';

/** AVPlayer 状态机封装(m3u8/mp4 直链 / 本地文件经 LocalProxy 伪装 HLS) */
export class PlayerController {
  private player: media.AVPlayer | null = null;
  private surfaceId: string = '';
  private pendingUrl: string = '';
  onState: (s: PlayerState) => void = () => {
  };
  onTime: (currentMs: number, durationMs: number) => void = () => {
  };
  onError: (msg: string) => void = () => {
  };
  /** 视频原始宽高(API 26 经 videoSizeChange 事件提供;折叠屏近方屏不拉伸) */
  onVideoSize: (videoWidth: number, videoHeight: number) => void = () => {
  };
  state: PlayerState = 'idle';

  async prepare(url: string, surfaceId: string): Promise<void> {
    this.pendingUrl = url;
    this.surfaceId = surfaceId;
    await this.release();
    const player = await media.createAVPlayer();
    this.player = player;
    this.hook(player);
    player.url = url; // idle → initialized
  }

  /**
   * 本地离线文件:不直接 fdSrc(TS 裸流没有时长/seek/倍速,全变 -1/801),
   * 而是经 LocalProxy 伪装成 HLS 点播,AVPlayer 的 HLS 引擎提供完整进度能力。
   */
  async prepareLocal(key: string, path: string, durationMs: number, surfaceId: string): Promise<void> {
    this.surfaceId = surfaceId;
    await this.release();
    const url = await LocalProxy.get().serve(key, path, durationMs);
    const player = await media.createAVPlayer();
    this.player = player;
    this.hook(player);
    player.url = url; // idle → initialized
  }

  private hook(player: media.AVPlayer): void {
    player.on('stateChange', async (s: string) => {
      Log.info('player state', s);
      if (s === 'initialized') {
        if (this.surfaceId.length > 0) {
          player.surfaceId = this.surfaceId;
        }
        player.prepare().catch((e: Object) => this.onError(`${e}`));
      } else if (s === 'prepared') {
        this.state = 'prepared';
        this.onState('prepared');
        player.play().catch((e: Object) => this.onError(`${e}`));
      } else if (s === 'playing') {
        this.state = 'playing';
        this.onState('playing');
      } else if (s === 'paused') {
        this.state = 'paused';
        this.onState('paused');
      } else if (s === 'stopped') {
        this.state = 'stopped';
        this.onState('stopped');
      } else if (s === 'error') {
        this.state = 'error';
        this.onState('error');
      }
    });
    player.on('timeUpdate', (timeMs: number) => {
      this.onTime(timeMs, player.duration);
    });
    player.on('videoSizeChange', (w: number, h: number) => {
      if (w > 0 && h > 0) {
        this.onVideoSize(w, h);
      }
    });
    player.on('error', (err) => {
      this.onError(`播放器错误:${JSON.stringify(err)}`);
    });
  }

  play(): void {
    this.player?.play();
  }

  pause(): void {
    this.player?.pause();
  }

  seek(ms: number, mode: media.SeekMode = media.SeekMode.SEEK_CLOSEST): void {
    this.player?.seek(ms, mode);
  }

  setSpeed(speed: number): void {
    const palette = PlayerController.speedPalette(speed);
    this.player?.setSpeed(palette);
  }

  /** App 内音量(0~1);系统音量不受影响 */
  setVolume(v: number): void {
    this.player?.setVolume(v);
  }

  static speedPalette(speed: number): media.PlaybackSpeed {
    switch (speed) {
      case 0.5:
        return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
      case 0.75:
        return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
      case 1.25:
        return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
      case 1.5:
        return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
      case 2.0:
        return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
      case 3.0:
        return media.PlaybackSpeed.SPEED_FORWARD_3_00_X;
      default:
        return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    }
  }

  async release(): Promise<void> {
    const p = this.player;
    this.player = null;
    if (p !== null) {
      try {
        p.release();
      } catch (e) {
        Log.warn('player release failed', `${e}`);
      }
    }
    this.state = 'idle';
  }
}
