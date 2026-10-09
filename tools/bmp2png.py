#!/usr/bin/env python3
"""Convert the app's top-down 32-bit BMP screenshot to PNG (no third-party deps)."""
import struct, sys, zlib

src, dst = sys.argv[1], sys.argv[2]
d = open(src, "rb").read()
off = struct.unpack_from("<I", d, 10)[0]
w, h = struct.unpack_from("<ii", d, 18)
bpp = struct.unpack_from("<H", d, 28)[0]
assert bpp == 32
top_down = h < 0
h = abs(h)
rows = []
for y in range(h):
    sy = y if top_down else h - 1 - y
    row = d[off + sy * w * 4: off + (sy + 1) * w * 4]
    out = bytearray(b"\x00")
    for x in range(w):
        b, g, r, a = row[x * 4: x * 4 + 4]
        out += bytes((r, g, b))
    rows.append(bytes(out))
raw = b"".join(rows)


def chunk(t, c):
    body = t + c
    return struct.pack(">I", len(c)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
      + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
open(dst, "wb").write(png)
print(dst, w, h)
