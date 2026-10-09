#!/usr/bin/env python3
"""Drive ./sonora through a pty with real keystrokes and check the screen."""
import os, pty, re, select, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "sonora")
GEN = os.path.join(ROOT, "tools", "gen_wav.py")


def gen(path, *args):
    subprocess.check_call([sys.executable, GEN, path, *map(str, args)])


def run(args, keys, wait=0.4):
    master, slave = pty.openpty()
    p = subprocess.Popen([BIN, *args], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
    os.close(slave)
    buf = b""

    def drain(t):
        nonlocal buf
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([master], [], [], 0.05)
            if r:
                try:
                    d = os.read(master, 65536)
                except OSError:
                    return
                if not d:
                    return
                buf += d

    drain(wait)
    for k in keys:
        os.write(master, k.encode())
        drain(wait)
    try:
        p.wait(timeout=3)
    except subprocess.TimeoutExpired:
        p.kill()
        raise AssertionError("sonora did not exit on 'q'")
    drain(0.1)
    os.close(master)
    return p.returncode, buf.decode("utf8", "replace")


def last_frame(out):
    return out.split("\x1b[2J")[-1]


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        check.failed = True


check.failed = False

with tempfile.TemporaryDirectory() as d:
    gen(os.path.join(d, "b_second.wav"), 660, 1.0, 8000, 16, 1)
    gen(os.path.join(d, "a_first.wav"), 440, 3.0, 8000, 16, 2)
    gen(os.path.join(d, "c_eight.WAV"), 880, 1.0, 8000, 8, 1)
    open(os.path.join(d, "junk.wav"), "wb").write(b"not a wav at all")
    open(os.path.join(d, "notes.txt"), "w").write("ignored")

    # listing + sort + quit
    rc, out = run([d], ["q"])
    f = last_frame(out) if "\x1b[2J" in out else out
    first = out.split("\x1b[2J")[1] if "\x1b[2J" in out else out
    check(rc == 0, "exits 0 on q")
    check("S O N O R A" in first, "draws title")
    names = re.findall(r"[abc]_\w+\.(?:wav|WAV)|junk\.wav", first)
    check(names == ["a_first.wav", "b_second.wav", "c_eight.WAV", "junk.wav"], f"sorted .wav list ({names})")
    check("notes.txt" not in first, "ignores non-wav files")

    # play first track, let clock advance, pause, resume, stop
    rc, out = run([d], ["\n", "", "", " ", " ", "s", "q"], wait=1.1)
    check("playing:" in out and "a_first.wav" in out, "Enter starts playback")
    check("0:00 / 3:00".replace("3:00", "0:03") in out, "reports track length 0:03")
    check(re.search(r"0:0[12] / 0:03", out) is not None, "clock advances in real time")
    check("paused:" in out, "space pauses")
    check("silent timing mode" in out, "falls back to silent mode without /dev/dsp")
    check("stopped" in last_frame(out), "s stops")

    # navigation, next/prev, volume, auto-advance
    rc, out = run([d], ["j", "\n", "n", "p", "-", "-", "+", "q"], wait=0.5)
    check("playing: " in out and "b_second.wav" in out, "j + Enter plays 2nd track")
    check("c_eight.WAV" in out, "n advances to 8-bit track")
    check("volume: 7/10" in out, "volume control (8 -1 -1 +1 = 7)")

    # track 2 (1s) ends by itself -> auto-advance to track 3
    rc, out = run([d], ["j", "\n", "", "", "q"], wait=0.6)
    check("c_eight.WAV" in last_frame(out) and "playing:" in last_frame(out), "auto-advances at end of track")

    # arrow keys
    rc, out = run([d], ["\x1b[B", "\x1b[B", "\x1b[A", "\n", "q"], wait=0.4)
    check("playing: " in out and "b_second.wav" in out, "arrow keys navigate")

    # bad file reports error instead of crashing
    rc, out = run([d], ["j", "j", "j", "\n", "q"], wait=0.4)
    check("unsupported file" in last_frame(out) or "unsupported file" in out, "junk.wav rejected gracefully")

    # empty dir and bad dir
    with tempfile.TemporaryDirectory() as e:
        rc, out = run([e], ["q"])
        check("no .wav files" in out, "empty directory message")
    rc, out = run(["/nonexistent-dir"], [])
    check(rc == 1 and "cannot open directory" in out, "bad directory exits 1")

sys.exit(1 if check.failed else 0)
