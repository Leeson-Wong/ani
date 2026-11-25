#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成鸿蒙分层应用图标（纯标准库，无第三方依赖）。

按 HarmonyOS 分层图标规范输出：
  - background.png  1024x1024 不透明背景
  - foreground.png  1024x1024 透明前景，主体居中且留出安全区
  - startIcon.png    144x144  合成启动图
图形：深红到亮橙渐变底 + 白色外焰 / 金黄内焰的分层火焰，主体居中留足安全边距。
"""
import math
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 应用图标（app.json5 -> $media:layered_image）与模块图标（module.json5）两处都要替换
ENTRY_BASE = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media')
APPSCOPE_BASE = os.path.join(ROOT, 'AppScope', 'resources', 'base', 'media')


def clamp(v, lo=0.0, hi=1.0):
    return max(lo, min(hi, v))


def coverage(d):
    """有符号距离(像素) -> 抗锯齿覆盖率"""
    return clamp(0.5 - d)


def dist_seg(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    t = 0.0 if l2 == 0 else clamp(((px - ax) * dx + (py - ay) * dy) / l2)
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def sd_triangle(px, py, a, b, c):
    """有向面积自动纠正顶点顺序；内部返回负距离"""
    area = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    if area < 0:
        b, c = c, b

    def edge(x1, y1, x2, y2):
        return (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)

    inside = edge(*a, *b) >= 0 and edge(*b, *c) >= 0 and edge(*c, *a) >= 0
    d = min(dist_seg(px, py, *a, *b),
            dist_seg(px, py, *b, *c),
            dist_seg(px, py, *c, *a))
    return -d if inside else d


# 火焰几何（1024 画布，中心为原点，y 向上）
# 外焰：圆润火基 + 向右上的主火舌 + 左火舌 + 右侧小火舌
OUTER_BASE = (0.0, -118.0, 168.0)
OUTER_TRIS = (
    ((-150.0, -150.0), (150.0, -150.0), (78.0, 272.0)),    # 主尖
    ((-168.0, -130.0), (-28.0, -140.0), (-150.0, 158.0)),  # 左火舌
    ((40.0, -140.0), (162.0, -110.0), (150.0, 120.0)),     # 右火舌
)
# 内焰：缩小一圈，同向但不顶到外焰尖端
INNER_BASE = (0.0, -122.0, 86.0)
INNER_TRIS = (
    ((-78.0, -140.0), (78.0, -140.0), (36.0, 96.0)),
    ((-96.0, -120.0), (-16.0, -125.0), (-82.0, 72.0)),
)
INNER_RGB = (255, 205, 72)  # 金黄内焰


def flame_sdf(px, py, base, tris):
    bx, by, br = base
    d = math.hypot(px - bx, py - by) - br
    for tri in tris:
        d = min(d, sd_triangle(px, py, *tri))
    return d


def foreground_pixel(px, py):
    """返回 (r, g, b, a)：白色外焰 + 金黄内焰，其余全透明"""
    a_out = coverage(flame_sdf(px, py, OUTER_BASE, OUTER_TRIS))
    if a_out <= 0:
        return (255, 255, 255, 0)
    a_in = coverage(flame_sdf(px, py, INNER_BASE, INNER_TRIS)) * a_out
    r = int(round(255 * (1 - a_in) + INNER_RGB[0] * a_in))
    g = int(round(255 * (1 - a_in) + INNER_RGB[1] * a_in))
    b = int(round(255 * (1 - a_in) + INNER_RGB[2] * a_in))
    return (r, g, b, int(round(255 * a_out)))


def background_color(nx, ny, size):
    """深红 -> 亮橙 对角渐变 + 中心暖光"""
    t = clamp((nx + ny) / (2.0 * size))
    r = 126 + (237 - 126) * t
    g = 24 + (108 - 24) * t
    b = 28 + (16 - 28) * t
    cx, cy = size / 2.0, size / 2.0
    glow = clamp(1.0 - math.hypot(nx - cx, ny - cy) / (size * 0.75)) ** 2
    r += 20 * glow
    g += 12 * glow
    b += 6 * glow
    return (int(clamp(r, 0, 255)), int(clamp(g, 0, 255)), int(clamp(b, 0, 255)))


def write_png(path, width, height, rows):
    """rows: list[bytes]，每行已含 filter byte + RGB/RGBA 像素"""
    raw = b''.join(rows)
    color_type = 6  # RGBA

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data +
                struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, color_type, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw, 9))
           + chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)


def render(size, fg_only=False, bg_only=False, composite=False):
    scale = size / 1024.0
    rows = []
    for y in range(size):
        row = bytearray()
        row.append(0)  # filter: none
        for x in range(size):
            cx = x + 0.5 - size / 2.0
            cy = size / 2.0 - (y + 0.5)
            px, py = cx / scale, cy / scale
            br, bg, bb = background_color(x + 0.5, y + 0.5, size)
            if fg_only:
                row += bytes(foreground_pixel(px, py))
            elif bg_only:
                row += bytes((br, bg, bb, 255))
            else:
                fr, fg, fb, fa = foreground_pixel(px, py)
                a = fa / 255.0
                r = int(round(fr * a + br * (1 - a)))
                g = int(round(fg * a + bg * (1 - a)))
                b = int(round(fb * a + bb * (1 - a)))
                row += bytes((r, g, b, 255))
        rows.append(bytes(row))
    return rows


def main():
    print('rendering background / foreground / startIcon ...')
    bg_rows = render(1024, bg_only=True)
    fg_rows = render(1024, fg_only=True)
    si_rows = render(144, composite=True)
    for base in (ENTRY_BASE, APPSCOPE_BASE):
        os.makedirs(base, exist_ok=True)
        write_png(os.path.join(base, 'background.png'), 1024, 1024, bg_rows)
        write_png(os.path.join(base, 'foreground.png'), 1024, 1024, fg_rows)
        print('written ->', base)
    # startIcon 仅模块侧需要（AppScope 原有资源中没有此文件）
    write_png(os.path.join(ENTRY_BASE, 'startIcon.png'), 144, 144, si_rows)
    print('written ->', os.path.join(ENTRY_BASE, 'startIcon.png'))


if __name__ == '__main__':
    main()
