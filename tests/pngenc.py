"""A small PNG encoder for the decoder tests: every colour type and bit depth, all five row filters, Adam7
interlacing, tRNS, palettes - plus the pixels the decoder is expected to produce (BGRA, as bytes)."""
import random
import struct
import zlib

CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def pack_row(samples, depth):
    """samples: list of ints (already per-channel), packed MSB first at the given depth."""
    if depth == 8:
        return bytes(samples)
    if depth == 16:
        return b"".join(struct.pack(">H", s) for s in samples)
    out = bytearray()
    acc, nb = 0, 0
    for s in samples:
        acc = (acc << depth) | s
        nb += depth
        if nb == 8:
            out.append(acc)
            acc, nb = 0, 0
    if nb:
        out.append(acc << (8 - nb))
    return bytes(out)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def filter_row(ftype, row, prev, bpp):
    out = bytearray()
    for i, x in enumerate(row):
        a = row[i - bpp] if i >= bpp else 0
        b = prev[i]
        c = prev[i - bpp] if i >= bpp else 0
        if ftype == 0:
            v = x
        elif ftype == 1:
            v = x - a
        elif ftype == 2:
            v = x - b
        elif ftype == 3:
            v = x - ((a + b) >> 1)
        else:
            v = x - paeth(a, b, c)
        out.append(v & 255)
    return bytes([ftype]) + bytes(out)


ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def encode(w, h, ctype, depth, pixels, palette=None, trns=None, interlace=False, filters=None, rnd=None, level=6):
    """pixels[y][x] = tuple of samples (CHANNELS[ctype] ints in 0 .. 2^depth-1).  Returns PNG bytes."""
    rnd = rnd or random.Random(1)
    ch = CHANNELS[ctype]
    bpp = max(1, ch * depth // 8)
    ihdr = struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, 1 if interlace else 0)
    raw = bytearray()
    passes = ADAM7 if interlace else [(0, 0, 1, 1)]
    for (x0, y0, dx, dy) in passes:
        xs = list(range(x0, w, dx))
        ys = list(range(y0, h, dy))
        if not xs or not ys:
            continue
        prev = bytes(len(pack_row([0] * (ch * len(xs)), depth)))
        for y in ys:
            row = pack_row([s for x in xs for s in pixels[y][x]], depth)
            ft = rnd.choice(filters) if filters else rnd.randrange(5)
            raw += filter_row(ft, row, prev, bpp)
            prev = row
    data = zlib.compress(bytes(raw), level)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
    if palette:
        png += chunk(b"PLTE", b"".join(bytes(c) for c in palette))
    if trns is not None:
        png += chunk(b"tRNS", trns)
    # split the data over several IDAT chunks
    for i in range(0, len(data), 997):
        png += chunk(b"IDAT", data[i:i + 997])
    png += chunk(b"IEND", b"")
    return png


def expected_bgra(w, h, ctype, depth, pixels, palette=None, trns=None):
    """What a correct decoder returns: bytes of B, G, R, A per pixel."""
    out = bytearray()
    maxv = (1 << depth) - 1
    for y in range(h):
        for x in range(w):
            s = pixels[y][x]
            a = 255
            if ctype == 0:
                g = s[0] * 255 // maxv if depth < 8 else (s[0] if depth == 8 else s[0] >> 8)
                r = gg = b = g
                if trns is not None and s[0] == struct.unpack(">H", trns)[0]:
                    a = 0
            elif ctype == 2:
                if depth == 16:
                    r, gg, b = s[0] >> 8, s[1] >> 8, s[2] >> 8
                else:
                    r, gg, b = s
                if trns is not None and tuple(s) == struct.unpack(">HHH", trns):
                    a = 0
            elif ctype == 3:
                r, gg, b = palette[s[0]]
                if trns is not None and s[0] < len(trns):
                    a = trns[s[0]]
            elif ctype == 4:
                v = s[0] >> 8 if depth == 16 else s[0]
                r = gg = b = v
                a = s[1] >> 8 if depth == 16 else s[1]
            else:
                if depth == 16:
                    r, gg, b, a = (v >> 8 for v in s)
                else:
                    r, gg, b, a = s
            out += bytes([b, gg, r, a])
    return bytes(out)


def random_image(w, h, ctype, depth, rnd, smooth=False):
    ch = CHANNELS[ctype]
    maxv = (1 << depth) - 1
    px = []
    for y in range(h):
        row = []
        for x in range(w):
            if smooth:
                row.append(tuple(min(maxv, ((x * 5 + y * 3 + c * 40) * maxv // 255) % (maxv + 1)) for c in range(ch)))
            else:
                row.append(tuple(rnd.randrange(maxv + 1) for _ in range(ch)))
        px.append(row)
    return px
