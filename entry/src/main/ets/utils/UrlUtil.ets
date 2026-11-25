/** 相对 URL 解析:HLS 子播放表/媒体段地址拼接 */
export function resolveUrl(base: string, ref: string): string {
  if (ref.startsWith('http://') || ref.startsWith('https://')) {
    return ref;
  }
  try {
    const proto = base.indexOf('://');
    if (proto < 0) {
      return ref;
    }
    const hostEnd = base.indexOf('/', proto + 3);
    const host = hostEnd > 0 ? base.substring(0, hostEnd) : base;
    if (ref.startsWith('//')) {
      return `${base.substring(0, proto)}:${ref}`;
    }
    if (ref.startsWith('/')) {
      return `${host}${ref}`;
    }
    // 相对路径:取 base 目录
    const q = base.indexOf('?');
    let dir = q > 0 ? base.substring(0, q) : base;
    const slash = dir.lastIndexOf('/');
    dir = slash > proto + 2 ? dir.substring(0, slash + 1) : `${host}/`;
    return `${dir}${ref}`;
  } catch (e) {
    return ref;
  }
}
