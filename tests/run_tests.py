#!/usr/bin/env python3
"""End-to-end tests for bytestream.exe.

Runs the Windows binary (under Wine + Xvfb on Linux, natively on Windows) and checks:
  * --selftest: pure-logic unit checks (JSON, base64url, URL encoding, model parsers ...)
  * scripted UI flows: `--act ID,ARG` activates a hit target that must really exist on screen,
    `--dump` prints the resulting state, `--screenshot` saves the rendered frame.
"""
import os, shutil, struct, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "build", "bytestream.exe")
ON_WINDOWS = os.name == "nt"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fake_spotify  # noqa: E402

# hit ids (ui_core.asm)
H_NAV, H_SIDE_PL, H_CARD, H_TRACK, H_PLAY, H_PREV, H_NEXT, H_SHUFFLE, H_REPEAT = 1, 2, 3, 4, 5, 6, 7, 8, 9
H_QUEUE, H_FULL, H_TAB, H_THEME, H_BACK, H_FS_CLOSE, H_DETAIL_PLAY = 12, 13, 14, 17, 19, 20, 21
H_SIGNIN, H_DEMO = 16, 24
H_COPY_URI, H_OPEN_DASH, H_BANNER_X = 28, 29, 30
H_OPEN_LOG, H_COPY_DIAG = 32, 33
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


def start_fake_server():
    srv = fake_spotify.ThreadingHTTPServer(("127.0.0.1", 0), fake_spotify.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1]


def win_path(p):
    return p if ON_WINDOWS else "Z:" + p


def run(args, shot=False, timeout=180, data_dir=None):
    env = dict(os.environ, WINEDEBUG="-all")
    env.setdefault("WINEPREFIX", "/tmp/wineprefix")
    path = None
    own_dir = None
    if "--data-dir" not in args and "--selftest" not in args and "--http-test" not in args:
        own_dir = data_dir or tempfile.mkdtemp(prefix="bs-data-")
        args = args + ["--data-dir", win_path(own_dir)]
    argv = cmd_prefix() + [EXE] + args
    if shot:
        path = tempfile.mktemp(suffix=".bmp")
        argv += ["--screenshot", path]
    p = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=timeout)
    if own_dir and not data_dir:
        shutil.rmtree(own_dir, ignore_errors=True)
    state = {}
    for line in p.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            state[k.strip()] = v.strip()
    return p.returncode, p.stdout, state, path


def spawn(args, data_dir):
    """Starts a long-running instance (no --dump) and returns the Popen."""
    env = dict(os.environ, WINEDEBUG="-all")
    env.setdefault("WINEPREFIX", "/tmp/wineprefix")
    argv = cmd_prefix() + [EXE] + args + ["--data-dir", win_path(data_dir)]
    kw = {} if ON_WINDOWS else {"start_new_session": True}
    return subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, **kw)


def stop(proc):
    try:
        if ON_WINDOWS:
            proc.terminate()
        else:
            import signal
            os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=15)
    except Exception:
        proc.kill()


def resolve_rvas(log_text):
    """Maps every rva=0x... in a crash report to a function name using build/bytestream.map."""
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import crashmap
    syms = crashmap.load(os.path.join(ROOT, "build", "bytestream.map"))
    import re
    return [crashmap.resolve(syms, int(m, 16)) for m in re.findall(r"rva=0x([0-9a-fA-F]+)", log_text)]


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


_last = [time.time()]


def check(cond, name, extra=""):
    global passed
    now = time.time()
    took = now - _last[0]
    _last[0] = now
    slow = f"  ({took:.1f}s)" if took >= 3 else ""
    if cond:
        passed += 1
        print("ok   " + name + slow)
    else:
        failed.append(name)
        print("FAIL " + name + ((" -- " + extra) if extra else ""))


def arg(src, idx):
    return (src << 16) | idx


def flow(name, args, expect, shot=False, extra_check=None, demo=True):
    rc, out, st, path = run((["--demo"] if demo else []) + ["--dump"] + args, shot=shot)
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


    # ---- milestone 1: HTTP client, job queue, settings, setup controls
    port = start_fake_server()
    base = f"http://127.0.0.1:{port}"
    log = fake_spotify.STATE.log

    rc, out, _, _ = run(["--http-test", f"{base}/echo", "--http-method", "POST", "--http-body", '{"a":1}'])
    check(rc == 0 and "status=200" in out and '"body": "{\\"a\\":1}"' in out, "http: POST body reaches the server")
    check('"Authorization": "Bearer probe-token"' in out and '"Content-Type": "application/json"' in out,
          "http: each header arrives as its own header")
    rc, out, _, _ = run(["--http-test", "http://127.0.0.1:1/echo"])
    check(rc == 1 and "status=0" in out, "http: closed port reports a transport failure")
    rc, out, _, _ = run(["--http-test", "ftp://example.test/x"])
    check(rc == 1 and "status=0" in out, "http: unsupported URL scheme is rejected")

    log.clear()
    rc, out, st, _ = run(["--demo", "--dump", "--api-base", base, "--net-get", "/echo", "--net-get", "/status?code=404",
                          "--net-get", "/status?code=429&retry=1", "--net-get", "/big"])
    check(rc == 0 and st.get("net_n") == "4" and [st.get("net_%d" % i) for i in range(4)] == ["200", "404", "429", "200"],
          "queue: four jobs complete in submit order with the right statuses", str(st))
    check(st.get("net_pending") == "0", "queue: nothing left in flight")
    paths = [e["path"] for e in log]
    check(paths.count("/status?code=429&retry=1") == 2, "queue: a 429 with a short Retry-After is retried exactly once",
          str(paths))
    check(paths[:2] == ["/echo", "/status?code=404"], "queue: requests were sent in order")

    d = tempfile.mkdtemp(prefix="bs-data-")
    rc, out, st, _ = run(["--dump", "--no-browser", "--type-client", "  abc123def456  ", "--type-port", "9001"], data_dir=d)
    ini = open(os.path.join(d, "settings.ini"), encoding="utf-8").read()
    check("client_id=abc123def456\n" in ini and "port=9001\n" in ini, "settings: typed values are trimmed and saved", ini)
    rc, out, st, _ = run(["--dump", "--no-browser"], data_dir=d)
    check(st.get("port") == "9001" and st.get("client_id") == "abc123def456", "settings: values survive a restart")
    rc, out, st, _ = run(["--dump", "--no-browser", "--act", f"{H_COPY_URI},0", "--act", f"{H_OPEN_DASH},0"], data_dir=d)
    check(rc == 0, "setup: the scripted run exits by itself (no timeout)")
    check("clipboard:http://127.0.0.1:9001/callback" in out, "setup: Copy puts the redirect URI (with the typed port) on the clipboard")
    check("open:https://developer.spotify.com/dashboard" in out, "setup: Open dashboard opens the Spotify dashboard")
    shutil.rmtree(d, ignore_errors=True)

    flow("settings: a port below 1024 is ignored", ["--type-port", "80"], {"port": 8989}, demo=False)
    flow("settings: a port above 65535 is ignored", ["--type-port", "70000"], {"port": 8989}, demo=False)
    flow("sign-in with no client ID shows a banner and stays on setup", ["--act", f"{H_SIGNIN},0"],
         {"page": PAGE_LOGIN, "banner": 1}, demo=False)
    flow("banner can be dismissed", ["--act", f"{H_SIGNIN},0", "--act", f"{H_BANNER_X},0"], {"banner": 0}, demo=False)
    flow("login screen shows setup with no banner at first", [], {"page": PAGE_LOGIN, "banner": 0}, demo=False)

    def login_screen(path):
        # banner strip is dark red (#7f1d1d) across the top when present; the setup column must still be centred
        top = pixel(path, 640, 5)
        return True if top == (127, 29, 29) else f"banner colour not found at the top: {top}"
    flow("banner is painted above the login screen", ["--act", f"{H_SIGNIN},0"], {"banner": 1}, shot=True,
         demo=False, extra_check=login_screen)

    flow("banner with an action button shows on any page", ["--page", "2", "--banner", "Test message", "--banner-button", "Fix it"],
         {"banner": 1, "page": PAGE_LIBRARY})


    # ---- diagnostics: log file, crash report, settings buttons, single instance
    d = tempfile.mkdtemp(prefix="bs-data-")
    run(["--demo", "--dump", "--api-base", base, "--net-get", "/echo", "--net-get", "/status?code=404"], data_dir=d)
    text = open(os.path.join(d, "bytestream.log"), encoding="utf-8").read()
    import re
    check(re.search(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} start ByteStream 0\.1 build \S+, Windows \d+\.\d+\.\d+$", text, re.M) is not None,
          "log: timestamped start line with version, build id and Windows version", text[:200])
    check(f"http GET {base}/echo -> 200" in text and f"http GET {base}/status?code=404 -> 404" in text,
          "log: every HTTP request is recorded with its status")
    check("Bearer" not in text and "probe-token" not in text, "log: no credentials are written")

    rc, out, _, _ = run(["--demo", "--no-browser", "--crash-test"], data_dir=d, timeout=60)
    text = open(os.path.join(d, "bytestream.log"), encoding="utf-8").read()
    check(rc != 0, "crash: the process exits non-zero after a fault", "rc=%s" % rc)
    check("CRASH code=0xc0000005" in text, "crash: report names the exception")
    names = resolve_rvas(text[text.index("CRASH"):])
    check(names and names[0].startswith("crash_test_fn+"), "crash: the faulting address resolves to crash_test_fn via the linker map", str(names))
    check(any(n.startswith("start") for n in names[1:]), "crash: the stack walk reaches the caller (start)", str(names))
    check("rax=0x" in text and "r15=0x" in text, "crash: all sixteen registers are recorded")
    shutil.rmtree(d, ignore_errors=True)

    rc, out, st, _ = run(["--demo", "--dump", "--no-browser", "--page", "4", "--size", "1280x1300", "--act", f"{H_COPY_DIAG},0", "--act", f"{H_OPEN_LOG},0"])
    check("clipboard:start ByteStream 0.1 build" in out and "Windows " in out, "settings: Copy diagnostics puts version + OS (+ log tail) on the clipboard")
    check("open:" in out and "bs-data" in out, "settings: Open log folder opens the data directory")

    d = tempfile.mkdtemp(prefix="bs-data-")
    first = spawn(["--demo", "--no-browser"], d)
    deadline = time.time() + 30
    while time.time() < deadline and not os.path.exists(os.path.join(d, "bytestream.log")):
        time.sleep(0.3)
    t0 = time.time()
    rc, out, st, _ = run(["--demo", "--dump", "--no-browser"], data_dir=d, timeout=30)
    took = time.time() - t0
    check(rc == 0 and "page" not in st, "single instance: a second launch with the same data dir exits without starting", out[:100])
    check(took < 10, "single instance: the second launch returns immediately", "%.1fs" % took)
    d2 = tempfile.mkdtemp(prefix="bs-data-")
    rc, out, st, _ = run(["--demo", "--dump", "--no-browser"], data_dir=d2)
    check(st.get("page") == "0", "single instance: a different data dir is a separate instance")
    stop(first)
    shutil.rmtree(d, ignore_errors=True)
    shutil.rmtree(d2, ignore_errors=True)

    # ---- the harness itself must fail loudly when a target is absent
    rc, out, st, _ = run(["--demo", "--act", "99,0"])
    check(rc == 3 and "not on screen" in out, "an --act with no matching on-screen target fails (exit 3)")

    print(f"\n{passed} passed, {len(failed)} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
