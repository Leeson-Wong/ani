import { BDecodeResult, Bencode, BNode, BK_BYTES, BK_DICT, BK_INT, BK_LIST } from './Bencode';
import { bytesToHex } from './Magnet';
import { sha1Async, sha1Equal } from './Sha1';
import { AppError } from '../../common/AppError';

/** 种子里的一个文件(含它在整包字节流中的偏移) */
export interface TorrentFileEntry {
  path: string;
  length: number;
  offset: number;
}

/** 种子元数据:.torrent 或 ut_metadata 的 info 字典解析结果 */
export class TorrentMeta {
  infoHash: Uint8Array = new Uint8Array(0);
  infoHashHex: string = '';
  name: string = '';
  pieceLength: number = 0;
  pieceCount: number = 0;
  /** 原始 piece 哈希表(20 × pieceCount) */
  pieces: Uint8Array = new Uint8Array(0);
  totalLength: number = 0;
  files: TorrentFileEntry[] = [];
  /** 来自 .torrent 根字典(announce + announce-list 去重);ut_metadata 路径为空 */
  trackers: string[] = [];
  isPrivate: boolean = false;
  /** info 含 'meta version' 字段(v2/hybrid);v1 哈希仍可用 */
  isV2: boolean = false;
}

/**
 * .torrent 解析。两条路径:
 *  - parse(buf):完整 .torrent 文件 —— 同时提取 info 字典原始字节算 infoHash,与 expectHash 比对
 *  - fromInfo(infoBuf):ut_metadata 拿回的裸 info 字典 —— 同样算 SHA1 校验
 * info 字典的原始字节区间靠逐 key decodePrefix 扫出,不做字符串猜测。
 */
export class TorrentFile {
  static async parse(buf: Uint8Array, expectHash: Uint8Array | null): Promise<TorrentMeta> {
    if (buf.length === 0 || buf[0] !== 0x64) {
      throw new AppError('.torrent 顶层不是字典');
    }
    let pos = 1;
    let infoStart = -1;
    let infoEnd = -1;
    const trackers: string[] = [];
    while (pos < buf.length && buf[pos] !== 0x65) {
      const keyRes: BDecodeResult = Bencode.decodePrefix(buf, pos);
      if (keyRes.node.kind !== BK_BYTES) {
        throw new AppError('.torrent 字典 key 非字节串');
      }
      const key = keyRes.node.asString();
      pos = keyRes.end;
      const valueStart = pos;
      const valueRes: BDecodeResult = Bencode.decodePrefix(buf, pos);
      pos = valueRes.end;
      if (key === 'announce' && valueRes.node.kind === BK_BYTES) {
        TorrentFile.pushTracker(trackers, valueRes.node.asString());
      } else if (key === 'announce-list' && valueRes.node.kind === BK_LIST) {
        for (const tier of valueRes.node.list) {
          if (tier.kind !== BK_LIST) {
            continue;
          }
          for (const t of tier.list) {
            if (t.kind === BK_BYTES) {
              TorrentFile.pushTracker(trackers, t.asString());
            }
          }
        }
      } else if (key === 'info') {
        infoStart = valueStart;
        infoEnd = pos;
      }
    }
    if (infoStart < 0) {
      throw new AppError('.torrent 缺 info 字典');
    }
    const infoHash = await sha1Async(buf.slice(infoStart, infoEnd));
    if (expectHash !== null && !sha1Equal(infoHash, expectHash)) {
      throw new AppError('SHA1(info) 与磁力 infohash 不一致(元数据损坏或资源不符)');
    }
    const meta = TorrentFile.parseInfo(buf.slice(infoStart, infoEnd));
    meta.infoHash = infoHash;
    meta.infoHashHex = bytesToHex(infoHash);
    meta.trackers = trackers;
    return meta;
  }

  /** ut_metadata 路径:裸 info 字典字节(先做 SHA1 == infohash 校验再解析) */
  static async fromInfo(infoBuf: Uint8Array, expectHash: Uint8Array): Promise<TorrentMeta> {
    const infoHash = await sha1Async(infoBuf);
    if (!sha1Equal(infoHash, expectHash)) {
      throw new AppError('ut_metadata 校验失败:SHA1(info) 与 infohash 不一致');
    }
    const meta = TorrentFile.parseInfo(infoBuf);
    meta.infoHash = infoHash;
    meta.infoHashHex = bytesToHex(infoHash);
    return meta;
  }

  private static pushTracker(list: string[], u: string): void {
    const t = u.trim();
    if (t.length > 0 && list.indexOf(t) < 0) {
      list.push(t);
    }
  }

  private static parseInfo(info: Uint8Array): TorrentMeta {
    const meta = new TorrentMeta();
    let pos = 1;
    let name = '';
    let singleLength = -1;
    let filesNode: BNode | undefined = undefined;
    while (pos < info.length && info[pos] !== 0x65) {
      const keyRes: BDecodeResult = Bencode.decodePrefix(info, pos);
      if (keyRes.node.kind !== BK_BYTES) {
        throw new AppError('info 字典 key 非字节串');
      }
      const key = keyRes.node.asString();
      pos = keyRes.end;
      const valueRes: BDecodeResult = Bencode.decodePrefix(info, pos);
      pos = valueRes.end;
      const node = valueRes.node;
      if (key === 'name' && node.kind === BK_BYTES) {
        name = node.asString();
      } else if (key === 'piece length' && node.kind === BK_INT) {
        meta.pieceLength = node.intVal;
      } else if (key === 'pieces' && node.kind === BK_BYTES) {
        meta.pieces = node.bytes;
      } else if (key === 'length' && node.kind === BK_INT) {
        singleLength = node.intVal;
      } else if (key === 'files') {
        filesNode = node;
      } else if (key === 'private' && node.kind === BK_INT && node.intVal === 1) {
        meta.isPrivate = true;
      } else if (key === 'meta version') {
        meta.isV2 = true;
      }
    }
    if (name.length === 0) {
      name = 'unknown';
    }
    if (meta.pieceLength <= 0 || meta.pieces.length === 0 || meta.pieces.length % 20 !== 0) {
      throw new AppError('info 缺 piece 哈希表或 piece length 非法');
    }
    meta.name = name;
    meta.pieceCount = Math.floor(meta.pieces.length / 20);
    let offset = 0;
    if (filesNode !== undefined && filesNode.kind === BK_LIST) {
      for (const raw of filesNode.list) {
        if (raw.kind !== BK_DICT) {
          continue;
        }
        const lenNode = raw.get('length');
        const pathNode = raw.get('path');
        if (lenNode === undefined || lenNode.kind !== BK_INT || pathNode === undefined || pathNode.kind !== BK_LIST) {
          continue;
        }
        const segs: string[] = [];
        for (const seg of pathNode.list) {
          if (seg.kind === BK_BYTES) {
            segs.push(seg.asString());
          }
        }
        const entry: TorrentFileEntry = {
          path: segs.length > 0 ? segs.join('/') : name,
          length: lenNode.intVal,
          offset: offset
        };
        offset += entry.length;
        meta.files.push(entry);
      }
    }
    if (meta.files.length === 0) {
      if (singleLength < 0) {
        throw new AppError('info 既无文件表也无单文件 length');
      }
      const entry: TorrentFileEntry = { path: name, length: singleLength, offset: 0 };
      meta.files.push(entry);
      offset = singleLength;
    }
    meta.totalLength = offset;
    return meta;
  }
}
