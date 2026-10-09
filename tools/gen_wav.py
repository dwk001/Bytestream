#!/usr/bin/env python3
"""Write a sine-wave .wav: gen_wav.py out.wav [freq_hz] [seconds] [rate] [bits] [channels]"""
import math, struct, sys

out = sys.argv[1]
freq = float(sys.argv[2]) if len(sys.argv) > 2 else 440.0
secs = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
rate = int(sys.argv[4]) if len(sys.argv) > 4 else 44100
bits = int(sys.argv[5]) if len(sys.argv) > 5 else 16
ch = int(sys.argv[6]) if len(sys.argv) > 6 else 2

frames = bytearray()
for i in range(int(rate * secs)):
    v = math.sin(2 * math.pi * freq * i / rate)
    for _ in range(ch):
        frames += struct.pack("<h", int(v * 12000)) if bits == 16 else bytes([int(128 + v * 100)])

hdr = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVE"
hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, ch, rate, rate * ch * bits // 8, ch * bits // 8, bits)
hdr += b"data" + struct.pack("<I", len(frames))
open(out, "wb").write(hdr + frames)
