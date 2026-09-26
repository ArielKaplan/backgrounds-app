#!/usr/bin/env python3
"""Draws the Backgrounds app icon (32x32 pixel art: dusk sky, sun, hills, a tree) and writes
icon-1024.png (macOS, rounded square with the standard margin) and Backgrounds.ico (Windows).
Standard library only. Run: python3 app/icons/make_icons.py"""
import struct, zlib, pathlib, math

HERE = pathlib.Path(__file__).resolve().parent
N = 32

def hexc(s): return tuple(int(s[i:i + 2], 16) for i in (1, 3, 5))
def mix(a, b, t): return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

def art():
    top, mid, low = hexc('#2b1d5c'), hexc('#8e3e7e'), hexc('#f4a261')
    px = [[None] * N for _ in range(N)]
    for y in range(N):
        t = y / (N - 1)
        c = mix(top, mid, t / 0.55) if t < 0.55 else mix(mid, low, (t - 0.55) / 0.45)
        # banded like a pixel-art sky
        for x in range(N): px[y][x] = c
    for (x, y) in [(4, 4), (9, 2), (14, 6), (22, 3), (27, 7), (6, 10), (25, 11)]:
        px[y][x] = hexc('#fff4d6')
    # sun
    cx, cy, r = 21, 17, 5.2
    for y in range(N):
        for x in range(N):
            d = math.hypot(x + .5 - cx, y + .5 - cy)
            if d < r: px[y][x] = hexc('#ffd166') if d < r - 1.2 else hexc('#ffb347')
    # hills (back, front)
    for x in range(N):
        hb = 20.5 + 2.8 * math.sin(x * 0.24 + 1.0)
        hf = 24.5 + 1.8 * math.sin(x * 0.2 + 3.4)
        for y in range(N):
            if y >= round(hf): px[y][x] = hexc('#2f7f5f') if y > round(hf) else hexc('#58b36a')
            elif y >= round(hb): px[y][x] = hexc('#3a5a8c') if y > round(hb) else hexc('#5a7fb0')
    # tree
    for y in range(18, 23): px[y][8] = hexc('#5a3a22')
    for (dx, dy) in [(-2, 0), (-1, 0), (0, 0), (1, 0), (2, 0), (-1, -1), (0, -1), (1, -1), (-2, 1), (-1, 1), (0, 1), (1, 1), (2, 1), (-1, 2), (0, 2), (1, 2), (0, -2)]:
        px[16 + dy][8 + dx] = hexc('#1f6b4a') if dy < 1 else hexc('#185a3e')
    px[15][8] = hexc('#2f8f5f'); px[16][7] = hexc('#2f8f5f')
    return px

def render(size, inset, radius, px):
    """RGBA rows: the art scaled (nearest) into an inset rounded square, anti-aliased corners."""
    inner = size - 2 * inset
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            ix, iy = x - inset, y - inset
            if not (0 <= ix < inner and 0 <= iy < inner):
                row += b'\0\0\0\0'; continue
            # rounded-corner coverage (4x4 supersampling)
            cov = 0
            for sy in range(4):
                for sx in range(4):
                    fx, fy = ix + (sx + .5) / 4, iy + (sy + .5) / 4
                    qx = min(fx, inner - fx); qy = min(fy, inner - fy)
                    if qx < radius and qy < radius:
                        cov += math.hypot(radius - qx, radius - qy) <= radius
                    else:
                        cov += 1
            c = px[min(N - 1, iy * N // inner)][min(N - 1, ix * N // inner)]
            row += bytes(c) + bytes([round(255 * cov / 16)])
        rows.append(bytes(row))
    return rows

def png(rows):
    w, h = len(rows[0]) // 4, len(rows)
    raw = b''.join(b'\0' + r for r in rows)
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')

def ico(images):
    head = struct.pack('<HHH', 0, 1, len(images))
    off = 6 + 16 * len(images)
    dirs, blobs = b'', b''
    for size, data in images:
        dirs += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), off + len(blobs))
        blobs += data
    return head + dirs + blobs

if __name__ == '__main__':
    px = art()
    # macOS: 1024 canvas, 832 content (26 px per art pixel), 96 margin, ~22% corner radius
    (HERE / 'icon-1024.png').write_bytes(png(render(1024, 96, 186, px)))
    images = [(s, png(render(s, 0, max(2, s * 0.18), px))) for s in (16, 24, 32, 48, 64, 128, 256)]
    (HERE / 'Backgrounds.ico').write_bytes(ico(images))
    print('wrote icon-1024.png and Backgrounds.ico')
