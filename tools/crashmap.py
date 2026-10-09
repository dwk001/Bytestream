#!/usr/bin/env python3
"""Turn RVAs from a ByteStream crash report into function names using the linker map.

    python tools/crashmap.py build/bytestream.map 0x2a1f 0x3b00 ...
    python tools/crashmap.py build/bytestream.map --log path/to/bytestream.log   # resolves every rva=0x...

Functions are the global labels of the single assembly unit; an RVA inside a function resolves to
"name+offset".  Use the map saved with the SAME build that crashed (CI uploads it with the exe).
"""
import re, sys


def load(map_path):
    syms = []
    base = 0x140000000
    for line in open(map_path, encoding="utf-8", errors="replace"):
        m = re.match(r"\s*Preferred load address is ([0-9a-fA-F]+)", line)
        if m:
            base = int(m.group(1), 16)
        m = re.match(r"\s*0001:[0-9a-fA-F]+\s+(\S+)\s+([0-9a-fA-F]{16})\s+(\S+)", line)
        if m and m.group(3).startswith("main.obj"):
            syms.append((int(m.group(2), 16) - base, m.group(1)))
    syms.sort()
    return syms


def resolve(syms, rva):
    best = None
    for addr, name in syms:
        if addr <= rva:
            best = (addr, name)
        else:
            break
    return "%s+0x%x" % (best[1], rva - best[0]) if best else "?"


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    syms = load(sys.argv[1])
    if sys.argv[2] == "--log":
        for line in open(sys.argv[3], encoding="utf-8", errors="replace"):
            if "rva=0x" in line:
                m = re.search(r"rva=0x([0-9a-fA-F]+)", line)
                print(line.rstrip(), "  =>", resolve(syms, int(m.group(1), 16)))
        return
    for a in sys.argv[2:]:
        print(a, "=>", resolve(syms, int(a, 16)))


if __name__ == "__main__":
    main()
