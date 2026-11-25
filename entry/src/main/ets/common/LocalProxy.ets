import { socket } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Log } from './Logger';

/** 一个可播放的本地文件注册项 */
interface ServeEntry {
  path: string;
  durationMs: number;
}

/** 解析出的一次 HTTP 请求 */
interface HttpReq {
  path: string;
  rangeStart: number; // -1 = 无 Range
  rangeEnd: number; // -1 = 到末尾
}

/** 伪 HLS 分片大小:把整部 .ts 按字节数切成 4MB 一片,时长按占比摊 */
const SEG_BYTES = 4 * 1024 * 1024;
const SEND_CHUNK = 256 * 1024;
const BASE_PORT = 17821;
const PORT_TRIES = 20;

/**
 * 本地播放代理(路线 B 基建,BT 边下边播复用):
 * 在 127.0.0.1 起 TCP HTTP 服务,把已下载的合并 .ts 伪装成 HLS 点播
 * (伪分片播放列表 + Range 取段)。AVPlayer 的 HLS 引擎因此拿到时长/拖动/倍速,
 * 这是 fdSrc 直读 TS 给不了的(-1 时长、801 不支持)。
 */
export class LocalProxy {
  private static inst: LocalProxy | null = null;

  static get(): LocalProxy {
    if (LocalProxy.inst === null) {
      LocalProxy.inst = new LocalProxy();
    }
    return LocalProxy.inst;
  }

  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;
  private starting: Promise<void> | null = null;
  private entries: Map<string, ServeEntry> = new Map();

  /** 注册一个本地文件,返回给 AVPlayer 的 HLS 地址。同 key 重复注册直接覆盖 */
  async serve(key: string, path: string, durationMs: number): Promise<string> {
    this.entries.set(key, { path: path, durationMs: durationMs });
    await this.ensureServer();
    const url = `http://127.0.0.1:${this.port}/p/${key}/index.m3u8`;
    Log.info('local proxy serve', key, url);
    return url;
  }

  private ensureServer(): Promise<void> {
    if (this.port > 0) {
      return Promise.resolve();
    }
    if (this.starting !== null) {
      return this.starting;
    }
    this.starting = this.listenOn(BASE_PORT);
    return this.starting;
  }

  private listenOn(port: number): Promise<void> {
    return new Promise<void>((resolve: (v: void) => void, reject: (e: Object) => void) => {
      const server = socket.constructTCPSocketServerInstance();
      server.on('connect', (client: socket.TCPSocketConnection) => {
        LocalProxy.bindClient(client);
      });
      server.listen({ address: '127.0.0.1', port: port, family: 1 }).then(() => {
        this.server = server;
        this.port = port;
        Log.info('local proxy listening', `${port}`);
        resolve();
      }).catch((e: Object) => {
        if (port < BASE_PORT + PORT_TRIES) {
          this.listenOn(port + 1).then(() => {
            resolve();
          }).catch((e2: Object) => {
            reject(e2);
          });
        } else {
          Log.warn('local proxy listen failed', `${e}`);
          reject(e);
        }
      });
    });
  }

  /** 每个客户端连接:闭包里持有半包缓冲,循环解析完整请求 */
  private static bindClient(client: socket.TCPSocketConnection): void {
    let leftover: string = '';
    client.on('message', (value: socket.SocketMessageInfo) => {
      leftover += LocalProxy.decoder.decodeToString(new Uint8Array(value.message));
      for (;;) {
        const sep = leftover.indexOf('\r\n\r\n');
        if (sep < 0) {
          return;
        }
        const raw = leftover.substring(0, sep);
        leftover = leftover.substring(sep + 4);
        const req = LocalProxy.parseRequest(raw);
        if (req === null) {
          continue;
        }
        LocalProxy.respond(client, req).catch((e: Object) => {
          Log.warn('proxy respond failed', `${e}`);
        });
      }
    });
    client.on('error', (_e: Object) => {
      // 客户端断开是常态(AVPlayer 换段/关页),静默
    });
  }

  private static parseRequest(raw: string): HttpReq | null {
    const lines = raw.split('\r\n');
    if (lines.length === 0) {
      return null;
    }
    const first = lines[0];
    const parts = first.split(' ');
    if (parts.length < 2 || parts[0] !== 'GET') {
      return null;
    }
    const path = parts[1];
    let rangeStart = -1;
    let rangeEnd = -1;
    for (const line of lines) {
      const low = line.toLowerCase();
      if (low.startsWith('range:')) {
        const spec = line.substring(line.indexOf(':') + 1).trim();
        const m = /bytes=(\d*)-(\d*)/.exec(spec);
        if (m !== null) {
          rangeStart = m[1].length > 0 ? Number(m[1]) : -1;
          rangeEnd = m[2].length > 0 ? Number(m[2]) : -1;
          // bytes=-N 形式 = 末尾 N 字节
          if (m[1].length === 0 && rangeEnd >= 0) {
            rangeStart = -2; // 标记尾部模式,响应时换算
          }
        }
      }
    }
    const req: HttpReq = { path: path, rangeStart: rangeStart, rangeEnd: rangeEnd };
    return req;
  }

  private static async respond(client: socket.TCPSocketConnection, req: HttpReq): Promise<void> {
    // /p/{key}/index.m3u8 | /p/{key}/seg{i}.ts
    const m = /^\/p\/([A-Za-z0-9_]+)\/(index\.m3u8|seg(\d+)\.ts)$/.exec(req.path);
    if (m === null) {
      await LocalProxy.sendText(client, 404, 'text/plain', 'not found');
      return;
    }
    const key = m[1];
    const entry = LocalProxy.get().entries.get(key);
    if (entry === undefined) {
      await LocalProxy.sendText(client, 404, 'text/plain', 'gone');
      return;
    }
    if (m[2] === 'index.m3u8') {
      await LocalProxy.sendText(client, 200, 'application/vnd.apple.mpegurl', LocalProxy.playlist(entry));
      return;
    }
    const segIdx = Number(m[3]);
    let size = 0;
    try {
      size = fileIo.statSync(entry.path).size;
    } catch (e) {
      await LocalProxy.sendText(client, 404, 'text/plain', 'file missing');
      return;
    }
    // 该伪分片在本文件中的字节区间
    let start = segIdx * SEG_BYTES;
    let end = Math.min((segIdx + 1) * SEG_BYTES, size) - 1; // 闭区间
    if (start >= size) {
      await LocalProxy.sendText(client, 404, 'text/plain', 'bad segment');
      return;
    }
    // 引擎在分片内再发 Range:取交集
    if (req.rangeStart >= 0) {
      const rs = req.rangeStart;
      const re = req.rangeEnd >= 0 ? req.rangeEnd : end;
      start = start + rs;
      end = Math.min(end, start + (re - rs));
    } else if (req.rangeStart === -2) {
      // bytes=-N:末尾 N 字节(极少出现,取分片末尾)
      const n = req.rangeEnd > 0 ? req.rangeEnd : 1;
      start = Math.max(start, end - n + 1);
    }
    await LocalProxy.sendFileRange(client, entry.path, start, end);
  }

  /** 伪 HLS 播放列表:按字节占比把总时长摊到 4MB 分片上 */
  private static playlist(entry: ServeEntry): string {
    let size = 0;
    try {
      size = fileIo.statSync(entry.path).size;
    } catch (e) {
      size = 0;
    }
    if (size <= 0) {
      size = SEG_BYTES;
    }
    const n = Math.max(1, Math.ceil(size / SEG_BYTES));
    const durSec = entry.durationMs > 0 ? entry.durationMs / 1000 : 1500;
    const perSeg = durSec / n;
    let out = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-MEDIA-SEQUENCE:0\n';
    out += `#EXT-X-TARGETDURATION:${Math.max(1, Math.ceil(perSeg))}\n`;
    for (let i = 0; i < n; i++) {
      out += `#EXTINF:${perSeg.toFixed(3)},\nseg${i}.ts\n`;
    }
    out += '#EXT-X-ENDLIST\n';
    return out;
  }

  private static async sendText(client: socket.TCPSocketConnection, code: number,
    contentType: string, body: string): Promise<void> {
    const head = `HTTP/1.1 ${code} ${code === 200 ? 'OK' : 'ERR'}\r\nContent-Type: ${contentType}\r\n` +
      `Content-Length: ${new Uint8Array(LocalProxy.encoder.encodeInto(body)).byteLength}\r\nConnection: keep-alive\r\n\r\n`;
    await LocalProxy.sendAll(client, LocalProxy.encoder.encodeInto(head));
    await LocalProxy.sendAll(client, LocalProxy.encoder.encodeInto(body));
  }

  /** 206/200 输出文件闭区间 [start,end] */
  private static async sendFileRange(client: socket.TCPSocketConnection, path: string,
    start: number, end: number): Promise<void> {
    let size = 0;
    try {
      size = fileIo.statSync(path).size;
    } catch (e) {
      size = 0;
    }
    end = Math.min(end, size - 1);
    const len = end - start + 1;
    const head = `HTTP/1.1 206 Partial Content\r\nContent-Type: video/MP2T\r\n` +
      `Content-Range: bytes ${start}-${end}/${size}\r\nContent-Length: ${len}\r\nConnection: keep-alive\r\n\r\n`;
    await LocalProxy.sendAll(client, LocalProxy.encoder.encodeInto(head));
    const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(SEND_CHUNK);
    try {
      let pos = start;
      while (pos <= end) {
        const want = Math.min(SEND_CHUNK, end - pos + 1);
        const got = fileIo.readSync(f.fd, buf, { offset: pos, length: want });
        if (got <= 0) {
          break;
        }
        await client.send({ data: buf.slice(0, got) });
        pos += got;
      }
    } finally {
      fileIo.closeSync(f);
    }
  }

  private static async sendAll(client: socket.TCPSocketConnection, bytes: Uint8Array): Promise<void> {
    let off = 0;
    while (off < bytes.byteLength) {
      const end = Math.min(off + SEND_CHUNK, bytes.byteLength);
      await client.send({ data: bytes.slice(off, end) });
      off = end;
    }
  }

  private static readonly encoder: util.TextEncoder = new util.TextEncoder();
  private static readonly decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
}
