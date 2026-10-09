#!/usr/bin/env python3
"""End-to-end tests for bytestream.exe.

Runs the Windows binary (under Wine + Xvfb on Linux, natively on Windows) and checks:
  * --selftest: pure-logic unit checks (JSON, base64url, URL encoding, model parsers ...)
  * scripted UI flows: `--act ID,ARG` activates a hit target that must really exist on screen,
    `--dump` prints the resulting state, `--screenshot` saves the rendered frame.
"""
import os, shutil, struct, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "build", "bytestream.exe")
ON_WINDOWS = os.name == "nt"

# hit ids (ui_core.asm)
H_NAV, H_SIDE_PL, H_CARD, H_TRACK, H_PLAY, H_PREV, H_NEXT, H_SHUFFLE, H_REPEAT = 1, 2, 3, 4, 5, 6, 7, 8, 9
H_QUEUE, H_FULL, H_TAB, H_THEME, H_BACK, H_FS_CLOSE, H_DETAIL_PLAY = 12, 13, 14, 17, 19, 20, 21
SRC_RECENT, SRC_LIKED, SRC_PLAYLISTS, SRC_ALBUMS = 1, 2, 5, 6
PAGE_HOME, PAGE_SEARCH, PAGE_LIBRARY, PAGE_DETAIL, PAGE_SETTINGS, PAGE_LOGIN = range(6)


def cmd_prefix():
    if ON_WINDOWS:
        return []
    wine = shutil.which("wine64") or "/usr/lib/wine/wine64"
    return ["timeout", "120", wine]


def ensure_display():
    """On Linux, run the whole suite under a single Xvfb instead of one per test."""
    if ON_WINDOWS or os.environ.get("BYTESTREAM_TEST_XVFB"):
        return
    os.environ["BYTESTREAM_TEST_XVFB"] = "1"
    os.execvp("xvfb-run", ["xvfb-run", "-a", "-s", "-screen 0 1920x1080x24", sys.executable] + sys.argv)


def run(args, shot=False, timeout=180):
    env = dict(os.environ, WINEDEBUG="-all")
    env.setdefault("WINEPREFIX", "/tmp/wineprefix")
    path = None
    argv = cmd_prefix() + [EXE] + args
    if shot:
        path = tempfile.mktemp(suffix=".bmp")
        argv += ["--screenshot", path]
    p = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=timeout)
    state = {}
    for line in p.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            state[k.strip()] = v.strip()
    return p.returncode, p.stdout, state, path


def pixel(path, x, y):
    d = open(path, "rb").read()
    off = struct.unpack_from("<I", d, 10)[0]
    w, h = struct.unpack_from("<ii", d, 18)
    top_down = h < 0
    h = abs(h)
    row = y if top_down else h - 1 - y
    b, g, r, _ = d[off + (row * w + x) * 4: off + (row * w + x) * 4 + 4]
    return r, g, b


failed = []
passed = 0


def check(cond, name, extra=""):
    global passed
    if cond:
        passed += 1
        print("ok   " + name)
    else:
        failed.append(name)
        print("FAIL " + name + ((" -- " + extra) if extra else ""))


def arg(src, idx):
    return (src << 16) | idx


def flow(name, args, expect, shot=False, extra_check=None):
    rc, out, st, path = run(["--demo", "--dump"] + args, shot=shot)
    ok = rc == 0
    bad = []
    for k, v in expect.items():
        if st.get(k) != str(v):
            ok = False
            bad.append(f"{k}: want {v!r} got {st.get(k)!r}")
    if rc != 0:
        bad.append(f"exit code {rc}")
    if extra_check and path and os.path.exists(path):
        r = extra_check(path)
        if r is not True:
            ok = False
            bad.append(str(r))
    check(ok, name, "; ".join(bad))
    if path and os.path.exists(path):
        os.remove(path)


def main():
    ensure_display()
    if not os.path.exists(EXE):
        print("build/bytestream.exe missing: run `make` first")
        return 2

    # ---- unit-level selftest
    rc, out, _, _ = run(["--selftest"])
    nok = sum(1 for l in out.splitlines() if l.startswith("ok"))
    nbad = [l for l in out.splitlines() if l.startswith("FAIL")]
    check(rc == 0 and not nbad and nok >= 40, f"selftest: {nok} checks pass", "; ".join(nbad))

    # ---- startup state
    flow("startup: home page, 10 playlists loaded, nothing playing", [], {"page": PAGE_HOME, "playlists": 10, "playing_loaded": 0})

    # ---- navigation
    flow("nav: library", ["--act", f"{H_NAV},{PAGE_LIBRARY}"], {"page": PAGE_LIBRARY})
    flow("nav: search", ["--act", f"{H_NAV},{PAGE_SEARCH}"], {"page": PAGE_SEARCH})
    flow("nav: settings", ["--act", f"{H_NAV},{PAGE_SETTINGS}"], {"page": PAGE_SETTINGS})
    flow("library: liked songs tab", ["--act", f"{H_NAV},{PAGE_LIBRARY}", "--act", f"{H_TAB},1"], {"page": PAGE_LIBRARY, "tab": 1})
    flow("library: albums tab", ["--act", f"{H_NAV},{PAGE_LIBRARY}", "--act", f"{H_TAB},2"], {"tab": 2})

    # ---- opening playlists / albums
    flow("sidebar playlist opens detail page",
         ["--act", f"{H_SIDE_PL},1"], {"page": PAGE_DETAIL, "detail": "Late Night Drive", "detail_tracks": 24})
    flow("playlist card opens detail page",
         ["--act", f"{H_CARD},{arg(SRC_PLAYLISTS, 3)}"], {"page": PAGE_DETAIL, "detail": "Sunday Morning"})
    flow("album card opens album tracks",
         ["--page", str(PAGE_LIBRARY), "--tab", "2", "--act", f"{H_CARD},{arg(SRC_ALBUMS, 0)}"],
         {"page": PAGE_DETAIL, "detail": "Afterglow Season", "detail_tracks": 9})
    flow("back returns to the previous page",
         ["--act", f"{H_SIDE_PL},0", "--act", f"{H_BACK},0"], {"page": PAGE_HOME})

    # ---- playback
    flow("click a track: it plays", ["--act", f"{H_TRACK},{arg(SRC_RECENT, 0)}"],
         {"playing_loaded": 1, "paused": 0, "title": "Daylight Lanterns", "queued": 9})
    flow("play button pauses", ["--act", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act", f"{H_PLAY},0"], {"paused": 1})
    flow("play button resumes", ["--act", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act", f"{H_PLAY},0", "--act", f"{H_PLAY},0"], {"paused": 0})
    flow("next advances the queue", ["--act", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act", f"{H_NEXT},0"],
         {"title": "Ember Honey", "queued": 8})
    flow("play from the middle of a list", ["--act", f"{H_TRACK},{arg(SRC_RECENT, 4)}"], {"queued": 5})
    flow("liked songs track plays", ["--page", "2", "--tab", "1", "--act", f"{H_TRACK},{arg(SRC_LIKED, 0)}"],
         {"playing_loaded": 1, "queued": 19})
    flow("detail Play button starts the playlist",
         ["--act", f"{H_SIDE_PL},0", "--act", f"{H_DETAIL_PLAY},0"], {"playing_loaded": 1, "title": "Midnight Lanterns", "queued": 23})
    flow("shuffle and repeat toggle", ["--act", f"{H_SHUFFLE},0", "--act", f"{H_REPEAT},0"], {"shuffle": 1, "repeat": 1})
    flow("repeat cycles back to off", ["--act", f"{H_REPEAT},0", "--act", f"{H_REPEAT},0", "--act", f"{H_REPEAT},0"], {"repeat": 0})
    flow("--volume sets the level", ["--volume", "35"], {"volume": 35})

    # ---- panels
    flow("queue panel toggles", ["--act", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act", f"{H_QUEUE},0"], {"queue_open": 1})
    flow("full-screen opens and closes", ["--act", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act", f"{H_FULL},0",
                                          "--act", f"{H_FS_CLOSE},0"], {"fullscreen": 0})
    flow("full-screen stays open", ["--act", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act", f"{H_FULL},0"], {"fullscreen": 1})

    # ---- search
    flow("demo search fills result lists", ["--page", "1", "--search", "tide"], {"search_tracks": 10})

    # ---- themes and rendering
    def bg(expect):
        def chk(path):
            got = pixel(path, 700, 20)       # empty main-area background above the page title
            return True if got == expect else f"bg pixel {got} != {expect}"
        return chk

    flow("theme: dark background", ["--theme", "0"], {"theme": 0}, shot=True, extra_check=bg((10, 10, 10)))
    flow("theme: midnight background", ["--theme", "1"], {"theme": 1}, shot=True, extra_check=bg((7, 17, 31)))
    flow("theme: light background", ["--theme", "2"], {"theme": 2}, shot=True, extra_check=bg((250, 250, 250)))
    flow("settings page switches the theme", ["--act", f"{H_NAV},{PAGE_SETTINGS}", "--act", f"{H_THEME},1"], {"theme": 1})

    def not_blank(path):
        colours = {pixel(path, x, y) for x in range(0, 1280, 61) for y in range(0, 800, 47)}
        return True if len(colours) > 20 else f"only {len(colours)} distinct colours sampled"
    flow("rendered frame has real content", ["--act", f"{H_TRACK},{arg(SRC_RECENT, 0)}"], {"playing_loaded": 1}, shot=True, extra_check=not_blank)

    def high_dpi(path):
        w = struct.unpack_from("<i", open(path, "rb").read(), 18)[0]
        return True if w == 1500 else f"width {w}"
    flow("scale override renders at the requested size", ["--scale", "150", "--size", "1000x600"], {"page": PAGE_HOME},
         shot=True, extra_check=high_dpi)

    # ---- the harness itself must fail loudly when a target is absent
    rc, out, st, _ = run(["--demo", "--act", "99,0"])
    check(rc == 3 and "not on screen" in out, "an --act with no matching on-screen target fails (exit 3)")

    print(f"\n{passed} passed, {len(failed)} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
