#!/usr/bin/env python3
"""End-to-end tests for bytestream.exe.

Runs the Windows binary (under Wine + Xvfb on Linux, natively on Windows) and checks:
  * --selftest: pure-logic unit checks (JSON, base64url, URL encoding, model parsers ...)
  * scripted UI flows: `--act ID,ARG` activates a hit target that must really exist on screen,
    `--dump` prints the resulting state, `--screenshot` saves the rendered frame.
"""
import http.client, json, os, queue, shutil, socket, struct, subprocess, sys, tempfile, threading, time, urllib.error, urllib.parse, urllib.request

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
H_OPEN_LOG, H_COPY_DIAG, H_CANCEL_SIGNIN = 32, 33, 34
H_TEST_AUDIO, H_LIKE, H_MENU_ITEM, H_MENU_BG = 36, 37, 38, 39
H_NEW_PL, H_DET_EDIT, H_DET_DELETE, H_DLG_BG, H_DLG_OK, H_DLG_CANCEL, H_DLG_PUBLIC = 40, 41, 42, 43, 44, 45, 46
SRC_SEARCH_R = 9
H_QUEUE_ROW = 22
H_SIGNOUT = 18
SRC_RECENT, SRC_LIKED, SRC_PLAYLISTS, SRC_ALBUMS = 1, 2, 5, 6
SRC_DETAIL = 4
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
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, **kw)
    proc.q = queue.Queue()                       # stdout lines, filled by a reader thread (None = process closed stdout)

    def pump():
        for raw in iter(proc.stdout.readline, b""):
            proc.q.put(raw.decode("utf-8", "replace").rstrip("\r\n"))
        proc.q.put(None)
    threading.Thread(target=pump, daemon=True).start()
    return proc


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def read_until(proc, prefix, timeout=40):
    """Reads the app's stdout until a line starts with `prefix`; returns (that line or None, all lines read)."""
    seen, end = [], time.time() + timeout
    while True:
        left = end - time.time()
        if left <= 0:
            return None, seen
        try:
            line = proc.q.get(timeout=left)
        except queue.Empty:
            return None, seen
        if line is None:
            return None, seen
        seen.append(line)
        if line.startswith(prefix):
            return line, seen


def finish(proc, timeout=90):
    """Waits for the app to exit and returns the rest of its output lines."""
    lines, end = [], time.time() + timeout
    while time.time() < end:
        try:
            line = proc.q.get(timeout=max(0.1, end - time.time()))
        except queue.Empty:
            break
        if line is None:
            break
        lines.append(line)
    else:
        stop(proc)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        stop(proc)
    return lines


def signin(base, d, port=None, browser="ok", act_signin=True, extra=None, client="client-abc", auth_base=None):
    """Runs the app through a sign-in with a simulated browser; returns (state dict, browser result, stdout lines)."""
    port = port or free_port()
    args = ["--dump", "--no-browser", "--wait-auth", "--api-base", base, "--auth-base", auth_base or base,
            "--type-client", client, "--type-port", str(port)]
    if act_signin:
        args += ["--act", f"{H_SIGNIN},0"]
    args += extra or []
    proc = spawn(args, d)
    seen, landed = [], None
    if act_signin and browser != "none":
        line, seen = read_until(proc, "open:")
        if line:
            try:
                r = urllib.request.urlopen(line[5:], timeout=20)
                landed = (r.status, r.geturl())
            except urllib.error.HTTPError as e:
                landed = (e.code, e.geturl())
            except Exception as e:  # noqa: BLE001
                landed = (0, str(e))
    lines = seen + finish(proc)
    state = {}
    for l in lines:
        l = l.rstrip("\r")
        if "=" in l and not l.startswith(("open:", "player-url:", "clipboard:")):
            k, v = l.split("=", 1)
            state[k.strip()] = v.strip()
    return state, landed, lines


class FakePage:
    """Plays the part of the Edge helper page: talks to the app's /bridge/* routes like web/player.js does."""

    def __init__(self, url):
        u = urllib.parse.urlparse(url)
        self.port = u.port
        self.k = urllib.parse.parse_qs(u.query)["k"][0]
        self.sse = None

    def get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        c.request("GET", path + ("&" if "?" in path else "?") + "k=" + self.k)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, data

    def post(self, obj):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        c.request("POST", f"/bridge/event?k={self.k}", body=json.dumps(obj), headers={"Content-Type": "application/json"})
        r = c.getresponse()
        r.read()
        c.close()
        return r.status

    def open_commands(self):
        self.sse = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        self.sse.request("GET", f"/bridge/cmds?k={self.k}")
        r = self.sse.getresponse()
        self.sse_resp = r
        return r.status, r.fp.readline().decode()

    def next_command(self):
        """Blocks (up to the socket timeout) for the next 'data:' line of the command stream; returns the parsed JSON."""
        try:
            while True:
                line = self.sse_resp.fp.readline().decode()
                if not line:
                    return None
                if line.startswith("data:"):
                    return json.loads(line[5:])
        except OSError:
            return None

    def close(self):
        if self.sse:
            self.sse.close()


def wait_for(pred, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.1)
    return False


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
    x = min(x, w - 1)          # a smaller-than-requested window must not crash the sampler
    y = min(y, h - 1)
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


ONLY = sys.argv[1] if len(sys.argv) > 1 else None   # e.g. `python tests/run_tests.py m2` runs one group


def main():
    ensure_display()
    if not os.path.exists(EXE):
        print("build/bytestream.exe missing: run `make` first")
        return 2

    if ONLY is None:
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

        flow("theme: dark background is #0A0A0A", ["--theme", "0"], {"theme": 0}, shot=True, extra_check=bg((10, 10, 10)))
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

    if ONLY in (None, 'm1'):

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
            # the banner strip (theme danger colour, #8b1a1a in the dark theme) spans the top when present
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
        check("CRASH code=0xc0000005" in text, "crash: report names the exception", "rc=%s stdout=%r log tail=%r" % (rc, out[:200], text[-500:]))
        names = resolve_rvas(text[text.index("CRASH"):]) if "CRASH" in text else []
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


    if ONLY in (None, 'm2'):
        # ---- milestone 2: loopback server + OAuth PKCE sign-in (against the fake accounts service)
        S = fake_spotify.STATE

        LIBRARY = ("/v1/me/playlists", "/v1/me/tracks", "/v1/me/albums", "/v1/me/player/recently-played", "/v1/me/library/contains",
                   "/v1/me/player/queue")

        def reqs(*paths):
            """Paths requested so far, without the library loads and cover downloads that follow every sign-in."""
            return [e["path"].split("?")[0] for e in S.log
                    if (not paths or e["path"].split("?")[0] in paths)
                    and e["path"].split("?")[0] not in LIBRARY and not e["path"].startswith("/img/")]

        S.reset()
        d = tempfile.mkdtemp(prefix="bs-data-")
        port = free_port()
        st, landed, lines = signin(base, d, port=port)
        check(st.get("auth_state") == "3" and st.get("signed_in") == "1" and st.get("user") == "Demo Listener" and st.get("page") == "0",
              "sign-in: full PKCE flow signs in and lands on Home", str(st) + str(landed))
        check(reqs() == ["/authorize", "/api/token", "/v1/me"], "sign-in: authorize, token exchange, profile - in that order", str(reqs()))
        tokreq = next((e for e in S.log if e["path"] == "/api/token"), {"body": ""})["body"]
        check("grant_type=authorization_code" in tokreq and "client_id=client-abc" in tokreq and "code_verifier=" in tokreq
              and f"redirect_uri=http%3A%2F%2F127.0.0.1%3A{port}%2Fcallback" in tokreq and "client_secret" not in tokreq,
              "sign-in: token request is a PKCE public-client exchange (no secret)", tokreq[:200])
        check(next((e for e in S.log if e["path"] == "/v1/me"), {"headers": {}})["headers"].get("Authorization") == "Bearer access-1",
              "sign-in: the access token is sent as a Bearer header")
        blob = open(os.path.join(d, "auth.bin"), "rb").read() if os.path.exists(os.path.join(d, "auth.bin")) else b""
        check(len(blob) > 50 and b"refresh-" not in blob, "sign-in: the refresh token is stored encrypted (DPAPI), not as plain text")
        logtxt = open(os.path.join(d, "bytestream.log"), encoding="utf-8").read()
        check("access-1" not in logtxt and "refresh-" not in logtxt and "code_verifier" not in logtxt, "sign-in: no tokens or verifier in the log")

        S.log.clear()
        st, _, _ = signin(base, d, act_signin=False)
        check(st.get("auth_state") == "3" and st.get("user") == "Demo Listener" and reqs() == ["/api/token", "/v1/me"],
              "restore: a stored session signs in with no browser (one refresh, one profile call)", str(st) + str(reqs()))
        check("grant_type=refresh_token" in next((e for e in S.log if e["path"] == "/api/token"), {"body": ""})["body"],
              "restore: uses the refresh_token grant")

        S.log.clear()
        S.fail_next["/v1/me"] = (401, None)
        st, _, _ = signin(base, d, act_signin=False)
        check(st.get("signed_in") == "1" and reqs() == ["/api/token", "/v1/me", "/api/token", "/v1/me"],
              "401 handling: an expired token is refreshed and the request retried once", str(reqs()))
        shutil.rmtree(d, ignore_errors=True)

        S.reset(); S.expires_in = 60
        d = tempfile.mkdtemp(prefix="bs-data-")
        st, _, _ = signin(base, d)
        check(st.get("signed_in") == "1" and reqs()[:4] == ["/authorize", "/api/token", "/api/token", "/v1/me"],
              "refresh: a token about to expire is renewed before the next request", str(reqs()))
        shutil.rmtree(d, ignore_errors=True)

        S.reset(); S.deny = True
        d = tempfile.mkdtemp(prefix="bs-data-")
        st, landed, _ = signin(base, d)
        check(st.get("auth_state") == "0" and st.get("banner") == "1" and st.get("signed_in") == "0" and "/api/token" not in reqs(),
              "denied: cancelling in the browser shows a banner and requests no tokens", str(st) + str(reqs()))
        shutil.rmtree(d, ignore_errors=True)

        S.reset(); S.forbid_me = True
        d = tempfile.mkdtemp(prefix="bs-data-")
        st, _, _ = signin(base, d)
        check(st.get("auth_state") == "0" and st.get("banner") == "1" and st.get("signed_in") == "0"
              and not os.path.exists(os.path.join(d, "auth.bin")),
              "403: an account not on the app's allow-list shows a banner and forgets the credentials", str(st))
        shutil.rmtree(d, ignore_errors=True)

        S.reset()
        d = tempfile.mkdtemp(prefix="bs-data-")
        signin(base, d)
        S.log.clear()
        st, _, _ = signin(base, d, act_signin=False, extra=["--act", "1,4", "--act", f"{H_SIGNOUT},0"])
        check(st.get("auth_state") == "0" and st.get("signed_in") == "0" and st.get("page") == "5"
              and not os.path.exists(os.path.join(d, "auth.bin")),
              "sign-out: returns to the sign-in screen and deletes the stored credentials", str(st))

        S.refresh.clear()
        d2 = tempfile.mkdtemp(prefix="bs-data-")
        S.reset(); signin(base, d2)
        S.refresh.clear()                                        # the server revokes the stored session
        st, _, _ = signin(base, d2, act_signin=False)
        check(st.get("auth_state") == "0" and st.get("banner") == "1" and not os.path.exists(os.path.join(d2, "auth.bin")),
              "expired session: a revoked refresh token shows a banner and is deleted", str(st))

        S.reset()
        d3 = tempfile.mkdtemp(prefix="bs-data-")
        signin(base, d3)
        st, _, _ = signin(base, d3, act_signin=False, auth_base="http://127.0.0.1:1")
        check(st.get("auth_state") == "0" and st.get("banner") == "1" and os.path.exists(os.path.join(d3, "auth.bin")),
              "offline: failing to reach Spotify keeps the stored credentials", str(st))
        for x in (d, d2, d3):
            shutil.rmtree(x, ignore_errors=True)

        S.reset()
        d = tempfile.mkdtemp(prefix="bs-data-")
        st, _, _ = signin(base, d, browser="none", extra=["--act", f"{H_CANCEL_SIGNIN},0"])
        check(st.get("auth_state") == "0" and st.get("banner") == "0" and "/api/token" not in reqs(), "cancel: stops waiting for the browser", str(st))
        shutil.rmtree(d, ignore_errors=True)

        blocker = socket.socket()
        blocker.bind(("127.0.0.1", 0))
        blocker.listen(1)
        busy = blocker.getsockname()[1]
        d = tempfile.mkdtemp(prefix="bs-data-")
        st, _, _ = signin(base, d, port=busy, browser="none")
        logtxt = open(os.path.join(d, "bytestream.log"), encoding="utf-8").read()
        blocker.close()
        check(st.get("auth_state") == "0" and st.get("banner") == "1" and "could not listen" in logtxt,
              "port in use: shows a banner instead of hanging", str(st) + logtxt[-200:])
        shutil.rmtree(d, ignore_errors=True)

        # ---- the loopback server's security rules, against a running app
        S.reset()
        d = tempfile.mkdtemp(prefix="bs-data-")
        sport = free_port()
        app = spawn(["--no-browser", "--api-base", base, "--auth-base", base, "--type-client", "client-abc",
                     "--type-port", str(sport), "--act", f"{H_SIGNIN},0"], d)
        try:
            opened, seen = read_until(app, "open:")
            purl, seen2 = read_until(app, "player-url:") if opened else (None, [])
            if not purl:
                purl = next((l for l in seen if l.startswith("player-url:")), None)
            check(opened is not None and purl is not None, "server: started and announced its URL", str(seen + seen2))
            state_val = urllib.parse.parse_qs(urllib.parse.urlparse(opened[5:]).query)["state"][0] if opened else ""
            secret = urllib.parse.parse_qs(urllib.parse.urlparse(purl[11:]).query)["k"][0] if purl else ""

            def hit(method, path, host=None, body=None, headers=None):
                c = http.client.HTTPConnection("127.0.0.1", sport, timeout=10)
                h = dict(headers or {})
                if host:
                    h["Host"] = host
                c.request(method, path, body=body, headers=h)
                r = c.getresponse()
                data = r.read()
                hdrs = {k.lower(): v for k, v in r.getheaders()}
                c.close()
                return r.status, hdrs, data

            s, h, b = hit("GET", f"/callback?code=x&state=WRONGWRONGWRONGWRONGWR")
            check(s == 403, "server: a callback with the wrong state is refused", str(s))
            s, h, b = hit("GET", f"/callback?code=x&state={state_val}", host="evil.example")
            check(s == 403, "server: a request with a foreign Host header is refused (DNS rebinding)", str(s))
            s, h, b = hit("GET", "/player")
            check(s == 403, "server: the player page needs the secret", str(s))
            s, h, b = hit("GET", "/player?k=wrongwrongwrongwrongwr")
            check(s == 403, "server: a wrong secret is refused", str(s))
            s, h, b = hit("GET", f"/player?k={secret}")
            check(s == 200 and b"ByteStream player" in b and "frame-ancestors 'none'" in h.get("content-security-policy", ""),
                  "server: the player page is served with a CSP that forbids framing", str((s, h)))
            s, h, b = hit("GET", "/player.js")
            check(s == 200 and "javascript" in h.get("content-type", "") and b"/bridge/event" in b, "server: the player script is served (it holds no secret)", str(s))
            s, h, b = hit("GET", "/player.js", host="evil.example")
            check(s == 403, "server: even the script obeys the Host check", str(s))
            s, h, b = hit("GET", f"/bridge/token?k={secret}")
            check(s == 401, "server: the bridge refuses to hand out a token while signed out", str(s))
            s, h, b = hit("GET", "/bridge/token")
            check(s == 403, "server: the token route needs the secret too", str(s))
            s, h, b = hit("POST", f"/bridge/event?k={secret}", body=b'{"type":"ready","device_id":"dev1"}',
                          headers={"Content-Type": "application/json"})
            check(s == 204, "server: the page can post events", str(s))
            s, h, b = hit("POST", "/bridge/event", body=b"{}")
            check(s == 403, "server: events without the secret are refused", str(s))
            s, h, b = hit("OPTIONS", f"/player?k={secret}")
            check(s == 405 and "access-control-allow-origin" not in h, "server: no CORS - OPTIONS is refused", str(s))
            s, h, b = hit("GET", "/nope")
            check(s == 404, "server: unknown paths are 404", str(s))
            s, h, b = hit("POST", "/callback")
            check(s == 405, "server: the callback accepts GET only", str(s))
            s, h, b = hit("GET", "/", headers={"X-Pad": "a" * 20000})
            check(s in (413, 400), "server: an oversized request head is refused", str(s))
            c = http.client.HTTPConnection("127.0.0.1", sport, timeout=10)
            c.request("GET", f"/bridge/cmds?k={secret}")
            r = c.getresponse()
            first = r.fp.readline().decode()
            check(r.status == 200 and "text/event-stream" in (r.getheader("Content-Type") or "") and first.startswith(": connected"),
                  "server: the command stream opens as text/event-stream", str((r.status, first)))
            c.close()
            s, h, b = hit("GET", f"/callback?code=thecode&state={state_val}")
            check(s == 200 and "access-control-allow-origin" not in h and h.get("cache-control") == "no-store",
                  "server: the right state is accepted (no CORS, not cached)", str((s, h)))
            s, h, b = hit("GET", f"/callback?code=thecode&state={state_val}")
            check(s == 403, "server: a state value can be used only once", str(s))
        finally:
            stop(app)
        logtxt = open(os.path.join(d, "bytestream.log"), encoding="utf-8").read()
        check("audio: player ready, device dev1" in logtxt, "server: a posted event reaches the UI thread", logtxt[-300:])
        check("wrong sign-in state" in logtxt and "wrong Host header" in logtxt and "missing or wrong secret" in logtxt,
              "server: every rejection is logged with its reason")
        shutil.rmtree(d, ignore_errors=True)


    # ---- milestone 3: in-app audio.  Python plays the part of the Edge page; the app is the real binary.
    if ONLY in (None, 'm3'):
        S = fake_spotify.STATE
        S.reset()
        d = tempfile.mkdtemp(prefix="bs-data-")
        sport = free_port()
        st, _, _ = signin(base, d, port=sport)
        check(st.get("signed_in") == "1", "audio: setup - a signed-in session exists", str(st))

        def plays():
            return [e for e in S.log if e["method"] == "PUT" and e["path"].startswith("/v1/me/player/play")]

        # no browser installed: Test audio explains it instead of failing silently
        S.log.clear()
        st, _, lines = signin(base, d, port=sport, act_signin=False, extra=[
            "--size", "1280x1300", "--edge-path", "", "--act", f"{H_NAV},{PAGE_SETTINGS}", "--act", f"{H_TEST_AUDIO},0"])
        check(st.get("banner") == "1" and not any(l.startswith("edge-launch:") for l in lines) and not plays(),
              "audio: without Edge a banner appears and nothing is launched", str(st))
        logtxt = open(os.path.join(d, "bytestream.log"), encoding="utf-8").read()
        check("audio: no Edge or Chrome found" in logtxt, "audio: the missing browser is logged")

        # the full conversation with a fake page (its tokens last 45 s, so the player page's token fetch must refresh)
        S.log.clear()
        S.play_reply = None
        S.play_404 = 1                         # the first play request meets "device not found" (Spotify does not list it yet)
        S.expires_in = 45
        app = spawn(["--dump", "--hold", "--no-browser", "--wait-auth", "--api-base", base, "--auth-base", base,
                     "--type-client", "client-abc", "--type-port", str(sport), "--size", "1280x1300",
                     "--edge-path", "x:\\fake\\msedge.exe",
                     "--act", f"{H_NAV},{PAGE_SETTINGS}", "--act", f"{H_TEST_AUDIO},0",
                     "--act-late", f"{H_PLAY},0", "--act-late", f"{H_NEXT},0", "--act-late", f"{H_PREV},0",
                     "--act-late", f"{H_SHUFFLE},0", "--act-late", f"{H_REPEAT},0", "--act-late", f"{H_TEST_AUDIO},0",
                     "--act-late", f"{H_NAV},{PAGE_HOME}", "--act-late", f"{H_CARD},{arg(SRC_PLAYLISTS, 0)}",
                     "--act-late", f"{H_DETAIL_PLAY},0"], d)
        page = None
        try:
            line, seen = read_until(app, "edge-launch:")
            check(line is not None, "audio: Test audio launches the helper (announced in test mode)", str(seen))
            if line:
                page = FakePage(line[len("edge-launch:"):])
                status, body = page.get("/player")
                check(status == 200, "audio: the helper page loads with the launch secret", str(status))
                n_tok = len([e for e in S.log if e["path"] == "/api/token"])
                status, body = page.get("/bridge/token")
                tok = json.loads(body).get("token", "") if status == 200 else ""
                check(status == 200 and tok.startswith("access-"), "audio: the page can fetch the access token", str((status, body[:80])))
                check(len([e for e in S.log if e["path"] == "/api/token"]) > n_tok,
                      "audio: a token about to expire is refreshed when the page asks for it (the SDK may ask long after the last API call)")
                status, first = page.open_commands()
                check(status == 200 and first.startswith(": connected"), "audio: the command stream opens", first)
                check(page.post({"type": "hello"}) == 204, "audio: hello is accepted")
                check(not plays(), "audio: nothing is played before the page reports its device")
                check(page.post({"type": "ready", "device_id": "dev-test-1"}) == 204, "audio: ready is accepted")
                cmd = page.next_command()
                check(cmd is not None and cmd.get("cmd") == "volume" and 0 <= cmd.get("pct", -1) <= 100,
                      "audio: the app pushes its volume to the page when it is ready", str(cmd))
                check(wait_for(lambda: len(plays()) == 2, 10), "audio: a 404 right after 'ready' is retried once instead of failing",
                      str([(e['method'], e['path']) for e in S.log[-4:]]))
                if plays():
                    e = plays()[-1]
                    check(e["path"].endswith("device_id=dev-test-1") and json.loads(e["body"]) == {"uris": ["spotify:track:4cOdK2wGLETKBW3PvgPWqT"]},
                          "audio: PUT /me/player/play targets the Connect device with the track", str(e))
                    check(e["headers"].get("Authorization", "").startswith("Bearer access-") and e["headers"].get("Content-Type") == "application/json",
                          "audio: the play request carries the bearer token and a JSON content type")
                check(page.post({"type": "state", "paused": False, "position": 1234, "duration": 215000, "shuffle": True, "repeat": 1,
                                 "track": {"uri": "spotify:track:4cOdK2wGLETKBW3PvgPWqT", "name": "Test Track",
                                           "artists": ["Artist One", "Artist Two"], "album": "Test Album",
                                           "images": ["https://i.scdn.co/image/large", "https://i.scdn.co/image/mid", "https://i.scdn.co/image/small"]}}) == 204,
                      "audio: a state event is accepted")
                time.sleep(0.5)
                page.post({"type": "go"})
                cmd = page.next_command()
                check(cmd == {"cmd": "toggle"}, "audio: the play/pause button sends a toggle command", str(cmd))
                page.post({"type": "go"})
                cmd = page.next_command()
                check(cmd == {"cmd": "next"}, "audio: the next button sends a next command", str(cmd))
                page.post({"type": "go"})
                cmd = page.next_command()
                check(cmd == {"cmd": "prev"}, "audio: the previous button sends a prev command", str(cmd))
                page.post({"type": "go"})
                check(wait_for(lambda: any(e["path"] == "/v1/me/player/shuffle?state=false&device_id=dev-test-1" for e in S.log)),
                      "audio: the shuffle button turns shuffle off on our device through the Web API", str([e["path"] for e in S.log[-4:]]))
                page.post({"type": "go"})
                check(wait_for(lambda: any(e["path"] == "/v1/me/player/repeat?state=track&device_id=dev-test-1" for e in S.log)),
                      "audio: the repeat button cycles context -> track through the Web API", str([e["path"] for e in S.log[-4:]]))
                S.play_reply = (403, {"error": {"status": 403, "reason": "PREMIUM_REQUIRED", "message": "Player command failed: Premium required"}})
                n_plays = len(plays())
                page.post({"type": "go"})
                check(wait_for(lambda: len(plays()) == n_plays + 1), "audio: pressing play again sends another request straight away")
                time.sleep(0.8)
                S.play_reply = None
                S.log.clear()
                for _ in range(3):                    # open a playlist page, press its Play button
                    page.post({"type": "go"})
                    time.sleep(0.5)
                ctx_plays = lambda: [e for e in S.log if e["method"] == "PUT" and e["path"].startswith("/v1/me/player/play")]
                check(wait_for(lambda: len(ctx_plays()) == 1), "audio: a page's Play button sends the whole playlist as a context", str([(e['method'], e['path']) for e in S.log]))
                if ctx_plays():
                    check(json.loads(ctx_plays()[0]["body"]) == {"context_uri": "spotify:playlist:pl000"},
                          "audio: the play request names the playlist (Spotify keeps its order and length)", ctx_plays()[0]["body"])
                page.post({"type": "state", "paused": True, "position": 99000, "duration": 215000, "shuffle": False, "repeat": 0,
                           "track": {"uri": "spotify:track:2222222222222222222222", "name": "Second \u00e9", "artists": ["Solo"], "album": "Other",
                                     "images": []}})
                time.sleep(0.3)
                page.post({"type": "quit"})
        finally:
            if page:
                page.close()
        lines = finish(app)
        st3 = {}
        for l in lines:
            if "=" in l and not l.startswith(("open:", "player-url:", "clipboard:", "edge-launch:")):
                k, v = l.split("=", 1)
                st3[k.strip()] = v.strip()
        check(st3.get("sdk_ready") == "1" and st3.get("device") == "dev-test-1", "audio: the dump shows the connected device", str(st3))
        check(st3.get("title") == "Second \u00e9" and st3.get("artist") == "Solo" and st3.get("album") == "Other"
              and st3.get("track_uri") == "spotify:track:2222222222222222222222",
              "audio: a state event replaces the now-playing track (UTF-8 survives)", str(st3))
        check(st3.get("paused") == "1" and st3.get("shuffle") == "0" and st3.get("repeat") == "0" and st3.get("duration_ms") == "215000",
              "audio: paused, shuffle, repeat and duration follow the page", str(st3))
        check(st3.get("banner") == "1", "audio: Premium required (403) shows a banner", str(st3))
        logtxt = open(os.path.join(d, "bytestream.log"), encoding="utf-8").read()
        check("audio: player ready, device dev-test-1" in logtxt and "audio: now playing Test Track" in logtxt
              and "audio: play request failed, status 403" in logtxt, "audio: the conversation is in the log", logtxt[-600:])
        check("access-" not in logtxt, "audio: no access token in the log")
        S.expires_in = 3600
        shutil.rmtree(d, ignore_errors=True)

        # the page script itself, in a real browser engine against a mocked SDK
        node = shutil.which("node")
        if node:
            p = subprocess.run([node, os.path.join(os.path.dirname(os.path.abspath(__file__)), "player_page.js")],
                               capture_output=True, text=True, timeout=180)
            rows = [l for l in p.stdout.splitlines() if l.startswith(("ok ", "FAIL "))]
            if p.stdout.startswith("SKIP") or not rows:
                print("skip player.js tests:", (p.stdout + p.stderr).strip()[:200])
            for l in rows:
                check(l.startswith("ok "), l[3:] if l.startswith("ok ") else l[5:])
        else:
            print("skip player.js tests: node is not installed")


    # ---- milestone 4: the live library (lists, paging, playlist/album pages, search, covers) against the fake API
    if ONLY in (None, 'm4'):
        S = fake_spotify.STATE
        S.reset()
        d = tempfile.mkdtemp(prefix="bs-data-")
        sport = free_port()
        st, _, _ = signin(base, d, port=sport)
        check(st.get("signed_in") == "1", "library: setup - a signed-in session exists", str(st))

        def live(extra, reset=True):
            """Restores the stored session against the fake API, runs the extras, returns (state, requests)."""
            if reset:
                S.log.clear()
                S.page_limit = None
                S.real_images = False
                S.forbidden_playlists = set()
                S.empty_playlists = set()
                S.fail_next.clear()
            st, _, lines = signin(base, d, port=sport, act_signin=False, extra=["--size", "1280x1300"] + extra)
            paths = [e["path"] for e in S.log]
            if not st:
                print("   (no state dumped; output was: %s)" % lines[-12:])
                try:
                    print("   log tail:", open(os.path.join(d, "bytestream.log"), encoding="utf-8").read()[-1500:])
                except OSError:
                    pass
            return st, paths

        st, paths = live([])
        check(st.get("playlists") == "10" and st.get("liked") == "20" and st.get("albums") == "8" and st.get("recent") == "10",
              "library: every list is filled from its endpoint after sign-in", str(st))
        for want in ("/v1/me/playlists?limit=50", "/v1/me/tracks?limit=50", "/v1/me/albums?limit=50", "/v1/me/player/recently-played?limit=50"):
            check(want in paths, "library: requests " + want, str(paths))
        e = next((e for e in S.log if e["path"].startswith("/v1/me/tracks")), {"headers": {}})
        check(e["headers"].get("Authorization", "").startswith("Bearer access-"), "library: API calls carry the bearer token")

        st, paths = live([])
        S.page_limit = 4
        S.log.clear()
        st, paths = live(["--act", f"{H_NAV},{PAGE_LIBRARY}", "--act", f"{H_TAB},1"], reset=False)
        check(st.get("playlists") == "10" and st.get("albums") == "8",
              "library: playlists and albums follow 'next' until everything is loaded", str(st))
        pl_pages = [p for p in paths if p.startswith("/v1/me/playlists")][-3:]
        check(len(pl_pages) == 3 and "offset=8" in pl_pages[-1] and "offset=4" in pl_pages[1], "library: three playlist pages of 4 were requested", str(pl_pages))
        check(st.get("liked") == "20", "library: the liked-songs tab pulls further pages while the list is short", str(st) + str([p for p in paths if "tracks" in p]))

        st, paths = live([], reset=True)
        S.page_limit = 4
        st, paths = live([], reset=False)
        check(st.get("liked") == "4", "library: liked songs wait for the user to reach them (one page)", str(st))

        st, paths = live(["--act", f"{H_CARD},{arg(SRC_PLAYLISTS, 0)}"])
        check(st.get("page") == str(PAGE_DETAIL) and st.get("detail_tracks") == "24" and "/v1/playlists/pl000/items?limit=100" in paths,
              "playlist page: loads /items and lists the tracks", str(st) + str(paths))
        S.page_limit = 10
        st, paths = live(["--act", f"{H_CARD},{arg(SRC_PLAYLISTS, 0)}"], reset=False)
        check(st.get("detail_tracks") == "24", "playlist page: long playlists load their later pages as well", str(st) + str(paths))

        S.forbidden_playlists = {"pl001"}
        st, paths = live(["--act", f"{H_CARD},{arg(SRC_PLAYLISTS, 1)}"], reset=False)
        check(st.get("detail_tracks") == "0" and st.get("detail_msg") == "1", "playlist page: a 403 explains that Spotify does not share the tracks", str(st))
        S.forbidden_playlists = set()
        S.empty_playlists = {"pl002"}
        st, paths = live(["--act", f"{H_CARD},{arg(SRC_PLAYLISTS, 2)}"], reset=False)
        check(st.get("detail_tracks") == "0" and st.get("detail_msg") == "1", "playlist page: tracks announced but not sent also explain themselves", str(st))

        st, paths = live(["--act", f"{H_NAV},{PAGE_LIBRARY}", "--act", f"{H_TAB},2", "--act", f"{H_CARD},{arg(SRC_ALBUMS, 0)}"])
        check(st.get("page") == str(PAGE_DETAIL) and st.get("detail_tracks") == "9" and any(p.startswith("/v1/albums/") and "/tracks?limit=50" in p for p in paths),
              "album page: loads /albums/{id}/tracks", str(st) + str(paths))

        st, paths = live(["--page", str(PAGE_SEARCH), "--search", "tide"])
        check(st.get("search_tracks") == "10" and st.get("search_albums") == "4" and st.get("search_playlists") == "3" and st.get("search_artists") == "4",
              "search: results fill all four lists (a null playlist entry is skipped)", str(st))
        check("/v1/search?q=tide&type=track,album,playlist,artist&limit=10" in paths, "search: query, types and the limit of 10", str(paths))
        st, paths = live(["--page", str(PAGE_SEARCH), "--search", "a&b \u00e9"])
        check(any(p.startswith("/v1/search?q=a%26b%20%C3%A9&") for p in paths), "search: the query is percent-encoded as UTF-8", str(paths))

        st, paths = live(["--size", "1280x2400", "--search", "tide", "--act", f"{H_NAV},{PAGE_SEARCH}", "--act", f"{H_CARD},{arg(SRC_SEARCH_R, 0)}"])
        check(st.get("page") == str(PAGE_DETAIL) and st.get("artist_albums") == "8" and any(p.startswith("/v1/artists/ar0/albums?include_groups=album,single") for p in paths),
              "artist page: lists the artist's albums (GET /artists/{id}/albums)", str(st) + str(paths[-3:]))
        S.real_images = True
        st, paths = live([], reset=False)
        imgs = [e for e in S.log if e["path"].startswith("/img/")]
        check(len(imgs) > 0 and all("Authorization" not in e["headers"] for e in imgs),
              "covers: images are downloaded without the Spotify token", str(len(imgs)))
        check(int(st.get("images_ready", "0")) > 0, "covers: downloaded PNGs decode into the cache", str(st))

        S.log.clear()
        st, paths = live(["--img-budget", "20", "--act", f"{H_NAV},{PAGE_SETTINGS}"], reset=False)
        distinct = len({e["path"] for e in S.log if e["path"].startswith("/img/")})
        n_ready = int(st.get("images_ready", "999"))
        check(st.get("albums") == "8" and 0 < n_ready <= distinct and len([e for e in S.log if e["path"].startswith("/img/")]) <= 2 * distinct,
              "covers: a tiny byte budget never makes the app loop re-downloading covers that are on screen",
              f"{n_ready} kept of {distinct} downloaded; {st}")

        # efficiency: playback progress repaints only the player bar, and an idle app repaints nothing
        rc, out, st0, _ = run(["--demo", "--play", "--dump"])
        rc, out, st, _ = run(["--demo", "--play", "--dump", "--run-ms", "1800"])
        check(rc == 0 and int(st.get("paints_bar", "0")) >= 3 and int(st.get("paints_full", "99")) <= 6,
              "paint: playback ticks redraw only the player bar", str(st))
        check(st.get("hits") == st0.get("hits"), "paint: bar-only frames do not add duplicate hit targets", f"{st.get('hits')} vs {st0.get('hits')}")
        rc, out, st, _ = run(["--demo", "--dump", "--run-ms", "1200"])
        check(rc == 0 and st.get("paints_bar") == "0" and int(st.get("paints_full", "99")) <= 3, "paint: an idle app does not repaint", str(st))

        S.fail_next["/v1/me/tracks"] = (500, None)
        st, paths = live([], reset=False)
        check(st.get("liked") == "0" and st.get("banner") == "1" and st.get("playlists") == "10",
              "library: one failing list shows a banner and leaves the others alone", str(st))

        st, paths = live(["--act", f"{H_NAV},{PAGE_SETTINGS}", "--act", f"{H_SIGNOUT},0"])
        check(st.get("playlists") == "0" and st.get("liked") == "0" and st.get("signed_in") == "0", "library: signing out clears every list", str(st))
        shutil.rmtree(d, ignore_errors=True)


    # ---- milestone 5: saved-state hearts (and, below, the queue and the context menu)
    if ONLY in (None, 'm5'):
        S = fake_spotify.STATE
        rc, out, st, _ = run(["--demo", "--dump", "--page", str(PAGE_LIBRARY), "--tab", "1"])
        check(st.get("saved_count") and int(st["saved_count"]) >= 20, "hearts (demo): liked songs and saved albums start out saved", str(st))
        n0 = int(st.get("saved_count", "0"))
        rc, out, st, _ = run(["--demo", "--dump", "--page", str(PAGE_LIBRARY), "--tab", "1", "--act", f"{H_LIKE},{arg(SRC_LIKED, 0)}"])
        check(rc == 0 and int(st.get("saved_count", "0")) == n0 - 1 and int(st.get("not_saved_count", "0")) >= 1,
              "hearts (demo): clicking a saved heart un-saves that track", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--page", str(PAGE_LIBRARY), "--tab", "1", "--act", f"{H_LIKE},{arg(SRC_LIKED, 0)}",
                              "--act", f"{H_LIKE},{arg(SRC_LIKED, 0)}"])
        check(int(st.get("saved_count", "0")) == n0, "hearts (demo): clicking again saves it back", str(st))

        # ---- the right-click menu and queue editing (demo data)
        row0 = arg(SRC_LIKED, 0)
        rc, out, st, _ = run(["--demo", "--dump", "--page", str(PAGE_LIBRARY), "--tab", "1", "--ctx", f"{H_TRACK},{row0}"])
        check(st.get("menu_open") == "1" and st.get("menu_n") == "7", "menu: a right click on a track row opens the seven-item menu", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--page", str(PAGE_LIBRARY), "--tab", "1", "--ctx", f"{H_TRACK},{row0}", "--act", f"{H_MENU_BG},0"])
        check(st.get("menu_open") == "0", "menu: a click outside dismisses it", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--page", str(PAGE_HOME), "--ctx", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act", f"{H_MENU_ITEM},1"])
        check(st.get("menu_open") == "0" and st.get("queued") == "1", "menu: Add to queue appends the track to the queue", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--page", str(PAGE_HOME), "--ctx", f"{H_TRACK},{arg(SRC_RECENT, 3)}", "--act", f"{H_MENU_ITEM},2"])
        check(st.get("queued") == "1" and st.get("queue_first"), "menu: Play next puts the track at the front", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--no-browser", "--page", str(PAGE_HOME), "--ctx", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act", f"{H_MENU_ITEM},5"])
        check(any(l.startswith("clipboard:https://open.spotify.com/track/") for l in out.splitlines()), "menu: Copy link copies the open.spotify.com address", out[-300:])
        rc, out, st, _ = run(["--demo", "--dump", "--no-browser", "--page", str(PAGE_HOME), "--ctx", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act", f"{H_MENU_ITEM},6"])
        check(any(l.startswith("open:https://open.spotify.com/track/") for l in out.splitlines()), "menu: Open in Spotify opens the web page for the track", out[-300:])
        rc, out, st0, _ = run(["--demo", "--dump", "--play", "--queue"])
        nq = int(st0.get("queued", "0"))
        first = st0.get("queue_first")
        rc, out, st, _ = run(["--demo", "--dump", "--play", "--queue", "--ctx", f"{H_QUEUE_ROW},0"])
        check(st.get("menu_open") == "1" and st.get("menu_n") == "6", "menu: a queue row offers play / remove / move down / clear / copy / open", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--play", "--queue", "--ctx", f"{H_QUEUE_ROW},0", "--act", f"{H_MENU_ITEM},1"])
        check(int(st.get("queued", "0")) == nq - 1 and st.get("queue_first") != first, "menu: Remove from queue drops that row", f"{nq} -> {st.get('queued')}, {first} -> {st.get('queue_first')}")
        rc, out, st, _ = run(["--demo", "--dump", "--play", "--queue", "--ctx", f"{H_QUEUE_ROW},0", "--act", f"{H_MENU_ITEM},2"])
        check(int(st.get("queued", "0")) == nq and st.get("queue_first") != first, "menu: Move down swaps it with the next row", f"{first} -> {st.get('queue_first')}")
        rc, out, st, _ = run(["--demo", "--dump", "--play", "--queue", "--ctx", f"{H_QUEUE_ROW},0", "--act", f"{H_MENU_ITEM},3"])
        check(st.get("queued") == "0", "menu: Clear queue empties it", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--play", "--queue", "--ctx", f"{H_QUEUE_ROW},1"])
        check(st.get("menu_n") == "7", "menu: a middle queue row also offers Move up", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--page", str(PAGE_LIBRARY), "--tab", "2", "--ctx", f"{H_CARD},{arg(SRC_ALBUMS, 0)}"])
        check(st.get("menu_open") == "1" and st.get("menu_n") == "4", "menu: an album card offers open / save / copy / open in Spotify", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--page", str(PAGE_LIBRARY), "--tab", "0", "--ctx", f"{H_CARD},{arg(SRC_PLAYLISTS, 0)}"])
        check(st.get("menu_n") == "5", "menu: a playlist card offers edit / delete instead of save (a heart would delete it)", str(st))

        S.reset()
        d = tempfile.mkdtemp(prefix="bs-data-")
        sport = free_port()
        st, _, _ = signin(base, d, port=sport)
        S.log.clear()
        st, _, _ = signin(base, d, port=sport, act_signin=False, extra=["--size", "1280x1300"])
        n_lib = int(st.get("saved_count", "0"))
        check(n_lib >= 38, "hearts: everything in the library (liked songs, albums, playlists) counts as saved without asking", str(st))
        asks = [e["path"] for e in S.log if e["path"].startswith("/v1/me/library/contains")]
        recent = fake_spotify.fixture("recent.json")["items"]
        rec_uris = [x["track"]["uri"] for x in recent]
        saved_fx = {t["track"]["uri"] for t in fake_spotify.fixture("saved_tracks.json")["items"]}
        unknown = [u for u in rec_uris if u not in saved_fx]
        check(len(asks) >= 1 and all("uris=spotify%3Atrack%3A" in a for a in asks),
              "hearts: tracks of unknown state are asked about in a batch (URIs percent-encoded)", str(asks))
        check(st.get("asked_count") == "0" and (not unknown or int(st.get("not_saved_count", "0")) >= 1),
              "hearts: the answers are applied (nothing left pending)", str(st))
        first = rec_uris[0]
        was_saved = first in fake_spotify.STATE._saved_for_test() if hasattr(fake_spotify.STATE, "_saved_for_test") else first in saved_fx
        S.log.clear()
        st, _, _ = signin(base, d, port=sport, act_signin=False, extra=["--size", "1280x1300", "--act", f"{H_LIKE},{arg(SRC_RECENT, 0)}"])
        puts = [e for e in S.log if e["path"].startswith("/v1/me/library?")]
        want_method = "DELETE" if was_saved else "PUT"
        check(len(puts) == 1 and puts[0]["method"] == want_method and puts[0]["path"].endswith("uris=" + first.replace(":", "%3A")),
              f"hearts: clicking a heart sends {want_method} /me/library with the URI", str([(e['method'], e['path']) for e in S.log][-4:]))
        S.log.clear()
        S.library_status = 500
        n_before = int(st.get("saved_count", "0"))
        st, _, lines = signin(base, d, port=sport, act_signin=False, extra=["--size", "1280x1300", "--act", f"{H_LIKE},{arg(SRC_RECENT, 1)}"])
        check(any(e["path"].startswith("/v1/me/library?") for e in S.log) and int(st.get("saved_count", "0")) == n_before,
              "hearts: a refused save flips the heart back", str(st) + f" (before: {n_before})")
        S.library_status = None
        shutil.rmtree(d, ignore_errors=True)

        # ---- the queue against the fake API: add (POST), play next (re-issued PUT), read back (GET)
        S.reset()
        d = tempfile.mkdtemp(prefix="bs-data-")
        sport = free_port()
        st, _, _ = signin(base, d, port=sport)
        S.log.clear()
        recent = fake_spotify.fixture("recent.json")["items"]
        r0, r1 = recent[0]["track"]["uri"], recent[1]["track"]["uri"]
        app = spawn(["--dump", "--hold", "--no-browser", "--wait-auth", "--api-base", base, "--auth-base", base,
                     "--type-client", "client-abc", "--type-port", str(sport), "--size", "1280x1300",
                     "--edge-path", "x:\\fake\\msedge.exe",
                     "--act", f"{H_NAV},{PAGE_SETTINGS}", "--act", f"{H_TEST_AUDIO},0",
                     "--act-late", f"{H_NAV},{PAGE_HOME}",
                     "--ctx-late", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act-late", f"{H_MENU_ITEM},1",
                     "--ctx-late", f"{H_TRACK},{arg(SRC_RECENT, 1)}", "--act-late", f"{H_MENU_ITEM},2"], d)
        page = None
        try:
            line, seen = read_until(app, "edge-launch:")
            page = FakePage(line[len("edge-launch:"):]) if line else None
            if page:
                page.open_commands()
                page.post({"type": "hello"})
                page.post({"type": "ready", "device_id": "dev-q"})
                page.next_command()
                wait_for(lambda: any(e["method"] == "PUT" and "/player/play" in e["path"] for e in S.log))
                page.post({"type": "state", "paused": False, "position": 42000, "duration": 215000, "shuffle": False, "repeat": 0,
                           "track": {"uri": "spotify:track:4cOdK2wGLETKBW3PvgPWqT", "name": "Test Track", "artists": ["A"], "album": "B", "images": []}})
                time.sleep(0.4)
                for _ in range(3):                     # home, right-click row 0, "Add to queue"
                    page.post({"type": "go"})
                    time.sleep(0.4)
                posts = lambda: [e for e in S.log if e["method"] == "POST" and e["path"].startswith("/v1/me/player/queue")]
                check(wait_for(lambda: len(posts()) == 1), "queue: Add to queue sends POST /me/player/queue", str([(e['method'], e['path']) for e in S.log][-5:]))
                if posts():
                    check(posts()[0]["path"] == "/v1/me/player/queue?uri=" + r0.replace(":", "%3A") + "&device_id=dev-q",
                          "queue: the POST names the track and our Connect device", posts()[0]["path"])
                check(wait_for(lambda: any(e["method"] == "GET" and e["path"].startswith("/v1/me/player/queue") for e in S.log), 8),
                      "queue: the queue is read back from Spotify a moment later")
                S.log.clear()
                for _ in range(2):                     # right-click row 1, "Play next"
                    page.post({"type": "go"})
                    time.sleep(0.4)
                plays = lambda: [e for e in S.log if e["method"] == "PUT" and e["path"].startswith("/v1/me/player/play")]
                check(wait_for(lambda: len(plays()) == 1), "queue: Play next re-issues play to our device", str([(e['method'], e['path']) for e in S.log]))
                if plays():
                    body = json.loads(plays()[0]["body"])
                    check(body["uris"][0] == "spotify:track:4cOdK2wGLETKBW3PvgPWqT" and body["uris"][1] == r1 and 30000 <= body["position_ms"] <= 120000,
                          "queue: the re-issued play is [current, chosen, queue...] and resumes in place", str(body)[:300])
                time.sleep(2.0)
                page.post({"type": "quit"})
        finally:
            if page:
                page.close()
        lines = finish(app)
        stq = {}
        for l in lines:
            if "=" in l and not l.startswith(("open:", "player-url:", "clipboard:", "edge-launch:")):
                k, v = l.split("=", 1)
                stq[k.strip()] = v.strip()
        check(int(stq.get("queued", "0")) >= 12, "queue: the panel shows the queue Spotify reported", str(stq.get("queued")))
        shutil.rmtree(d, ignore_errors=True)


    # ---- milestone 6: playlist management (dialogs, create / rename / delete, add / remove tracks)
    if ONLY in (None, 'm6'):
        S = fake_spotify.STATE
        rc, out, st, _ = run(["--demo", "--dump", "--act", f"{H_NEW_PL},0"])
        check(st.get("dialog") == "1", "dialog: the + button opens the New playlist dialog", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--act", f"{H_NEW_PL},0", "--act", f"{H_DLG_CANCEL},0"])
        check(st.get("dialog") == "0", "dialog: Cancel closes it", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--act", f"{H_NEW_PL},0", "--act", f"{H_DLG_PUBLIC},0"])
        check(st.get("dialog_public") == "1", "dialog: the Public / Private toggle flips", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--act", f"{H_NEW_PL},0", "--act", f"{H_DLG_BG},0"])
        check(st.get("dialog") == "1", "dialog: it is modal - a click outside the panel does nothing", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--detail", "0", "--act", f"{H_DET_EDIT},0"])
        check(st.get("dialog") == "2", "dialog: Edit on our own playlist opens the edit dialog", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--detail", "0", "--act", f"{H_DET_DELETE},0"])
        check(st.get("dialog") == "3", "dialog: Delete asks for confirmation", str(st))
        rc, out, st, _ = run(["--demo", "--dump", "--detail", "0", "--ctx", f"{H_TRACK},{arg(SRC_DETAIL, 1)}"])
        check(st.get("menu_n") == "7" or st.get("menu_n") == "8", "menu: a track of our own playlist also offers Add to playlist and Remove from this playlist", str(st))

        S.reset()
        d = tempfile.mkdtemp(prefix="bs-data-")
        sport = free_port()
        st, _, _ = signin(base, d, port=sport)

        def live6(extra, reset_state=True):
            if reset_state:
                S.playlists = None
                S.playlist_status = None
            S.log.clear()
            st, _, lines = signin(base, d, port=sport, act_signin=False, extra=["--size", "1280x1300"] + extra)
            reqs = [e for e in S.log if e["method"] != "GET" and e["path"].startswith("/v1/")]
            return st, reqs

        st, reqs = live6([])
        check(st.get("playlists") == "10", "playlists: ten to start with", str(st))
        st, reqs = live6(["--act", f"{H_NEW_PL},0", "--dlg-name", 'Road "trip" \\ caf\u00e9', "--dlg-desc", "for the car", "--act", f"{H_DLG_PUBLIC},0", "--act", f"{H_DLG_OK},0"])
        posts = [e for e in reqs if e["method"] == "POST" and e["path"] == "/v1/me/playlists"]
        check(len(posts) == 1, "create: POST /me/playlists", str([(e['method'], e['path']) for e in reqs]))
        if posts:
            b = json.loads(posts[0]["body"])
            check(b == {"name": 'Road "trip" \\ caf\u00e9', "description": "for the car", "public": True},
                  "create: name, description and public arrive intact (quotes, backslash and accents escaped)", str(b))
            check(posts[0]["headers"].get("Content-Type") == "application/json", "create: JSON content type")
        check(st.get("playlists") == "11" and st.get("dialog") == "0", "create: the new playlist appears and the dialog closes", str(st))
        st, reqs = live6(["--act", f"{H_NEW_PL},0", "--dlg-name", "Enter key", "--act", "61440,13"])
        check(len([e for e in reqs if e["method"] == "POST" and e["path"] == "/v1/me/playlists"]) == 1 and st.get("dialog") == "0",
              "dialog: Enter in the name field creates the playlist", str(st))
        st, reqs = live6(["--act", f"{H_NEW_PL},0", "--dlg-name", "Escaped", "--act", "61440,27"])
        check(not [e for e in reqs if e["method"] == "POST"] and st.get("dialog") == "0", "dialog: Esc in the name field cancels it", str(st))
        st, reqs = live6(["--act", f"{H_NEW_PL},0", "--dlg-name", "   ", "--act", f"{H_DLG_OK},0"])
        check(not [e for e in reqs if e["method"] == "POST"] and st.get("dialog") == "1", "create: a blank name is refused and the dialog stays open", str(st))

        st, reqs = live6(["--act", f"{H_CARD},{arg(SRC_PLAYLISTS, 0)}", "--act", f"{H_DET_EDIT},0", "--dlg-name", "Renamed mix", "--act", f"{H_DLG_OK},0"])
        puts = [e for e in reqs if e["method"] == "PUT" and e["path"] == "/v1/playlists/pl000"]
        check(len(puts) == 1 and json.loads(puts[0]["body"]) == {"name": "Renamed mix", "public": False},
              "edit: PUT /playlists/{id} with the new name (an empty description is left alone)", str([(e['method'], e['path'], e['body']) for e in reqs]))
        check(st.get("detail") == "Renamed mix", "edit: the open page shows the new name at once", str(st.get("detail")))

        st, reqs = live6(["--act", f"{H_CARD},{arg(SRC_PLAYLISTS, 0)}", "--act", f"{H_DET_DELETE},0", "--act", f"{H_DLG_OK},0"])
        dels = [e for e in reqs if e["method"] == "DELETE"]
        check(len(dels) == 1 and dels[0]["path"] == "/v1/me/library?uris=spotify%3Aplaylist%3Apl000",
              "delete: DELETE /me/library with the playlist URI", str([(e['method'], e['path']) for e in reqs]))
        check(st.get("playlists") == "9" and st.get("page") == str(PAGE_LIBRARY), "delete: it disappears and its page closes", str(st))
        st, reqs = live6(["--act", f"{H_CARD},{arg(SRC_PLAYLISTS, 0)}", "--act", f"{H_DET_DELETE},0", "--act", f"{H_DLG_CANCEL},0"])
        check(not [e for e in reqs if e["method"] == "DELETE"] and st.get("playlists") == "10", "delete: Cancel sends nothing", str(st))

        # adding a track from a row's menu: the picker lists the playlists we own
        st, reqs = live6(["--page", str(PAGE_HOME), "--ctx", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act", f"{H_MENU_ITEM},4"])
        check(st.get("menu_open") == "1" and st.get("menu_n") == "10", "picker: Add to playlist lists our ten playlists", str(st))
        recent = fake_spotify.fixture("recent.json")["items"]
        st, reqs = live6(["--page", str(PAGE_HOME), "--ctx", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act", f"{H_MENU_ITEM},4", "--act", f"{H_MENU_ITEM},2"])
        posts = [e for e in reqs if e["method"] == "POST" and e["path"].endswith("/items")]
        check(len(posts) == 1 and posts[0]["path"] == "/v1/playlists/pl002/items" and json.loads(posts[0]["body"]) == {"uris": [recent[0]["track"]["uri"]]},
              "picker: choosing a playlist POSTs the track to /playlists/{id}/items", str([(e['method'], e['path'], e['body']) for e in reqs]))
        S.playlist_status = 403
        st, reqs = live6(["--page", str(PAGE_HOME), "--ctx", f"{H_TRACK},{arg(SRC_RECENT, 0)}", "--act", f"{H_MENU_ITEM},4", "--act", f"{H_MENU_ITEM},2"], reset_state=False)
        check(len([e for e in reqs if e["method"] == "POST"]) == 1 and st.get("menu_open") == "0",
              "picker: a refusal (403) is reported without breaking anything", str(st))
        S.playlist_status = None

        # removing a track of the open own playlist
        items = fake_spotify.fixture("playlist_items.json")["items"]
        st, reqs = live6(["--act", f"{H_CARD},{arg(SRC_PLAYLISTS, 0)}", "--ctx", f"{H_TRACK},{arg(SRC_DETAIL, 1)}", "--act", f"{H_MENU_ITEM},5"])
        dels = [e for e in reqs if e["method"] == "DELETE" and e["path"] == "/v1/playlists/pl000/items"]
        check(len(dels) == 1 and json.loads(dels[0]["body"]) == {"items": [{"uri": items[1]["item"]["uri"]}]},
              "remove: DELETE /playlists/{id}/items with the track URI", str([(e['method'], e['path'], e['body']) for e in reqs]))
        check(st.get("detail_tracks") == "24", "remove: the page is reloaded afterwards", str(st))
        # playlist card menu
        st, reqs = live6(["--page", str(PAGE_LIBRARY), "--ctx", f"{H_CARD},{arg(SRC_PLAYLISTS, 0)}"])
        check(st.get("menu_n") == "5", "menu: our playlist card offers open / edit / delete / copy / open in Spotify", str(st))
        shutil.rmtree(d, ignore_errors=True)


    # ---- milestone 7: polish
    if ONLY in (None, 'm7'):
        S = fake_spotify.STATE
        # unplayable tracks are muted and refused locally instead of failing at Spotify
        S.reset()
        d = tempfile.mkdtemp(prefix="bs-data-")
        sport = free_port()
        st, _, _ = signin(base, d, port=sport)
        recent = fake_spotify.fixture("recent.json")["items"]
        S.unplayable = {recent[0]["track"]["uri"]}
        S.log.clear()
        st, _, lines = signin(base, d, port=sport, act_signin=False, extra=["--size", "1280x1300", "--edge-path", "x:\\fake\\msedge.exe",
                                                                           "--act", f"{H_TRACK},{arg(SRC_RECENT, 0)}"])
        check(not any(l.startswith("edge-launch:") for l in lines) and not [e for e in S.log if "/player/play" in e["path"]],
              "unplayable: clicking a greyed-out track starts nothing", str(lines[-5:]))
        S.log.clear()
        st, _, lines = signin(base, d, port=sport, act_signin=False, extra=["--size", "1280x1300", "--edge-path", "x:\\fake\\msedge.exe",
                                                                           "--act", f"{H_TRACK},{arg(SRC_RECENT, 1)}"])
        logt = open(os.path.join(d, "bytestream.log"), encoding="utf-8").read()
        check(any(l.startswith("edge-launch:") for l in lines), "unplayable: the next row still plays", "LOG:" + repr(logt[-900:]))
        S.unplayable = set()
        shutil.rmtree(d, ignore_errors=True)

        # the window comes back at the size it had last time
        d = tempfile.mkdtemp(prefix="bs-data-")
        rc, out, st, path = run(["--demo", "--size", "900x700"], shot=True, data_dir=d)
        w1 = struct.unpack("<i", open(path, "rb").read()[18:22])[0] if path and os.path.exists(path) else 0
        if path and os.path.exists(path):
            os.remove(path)
        rc, out, st, path = run(["--demo"], shot=True, data_dir=d)
        w2 = struct.unpack("<i", open(path, "rb").read()[18:22])[0] if path and os.path.exists(path) else 0
        if path and os.path.exists(path):
            os.remove(path)
        check(w1 == 900 and w2 == 900, "window: the size is remembered between runs", f"{w1} then {w2}")
        ini = open(os.path.join(d, "settings.ini"), encoding="utf-8").read() if os.path.exists(os.path.join(d, "settings.ini")) else ""
        check("winw=900" in ini and "winh=700" in ini, "window: saved as winw / winh in settings.ini", ini)
        shutil.rmtree(d, ignore_errors=True)


    if ONLY in (None, 'm8'):
        # ---- M8a: animation clock, hover fades, smooth scrolling, sliding panels
        W = 61441                    # pseudo --act targets: mouse wheel over the page (+1 sidebar, +2 queue); n = notches down, 256 + n = up
        base = ["--demo", "--dump", "--page", str(PAGE_LIBRARY), "--tab", "1", "--size", "1100x500"]
        rc, out, st, _ = run(base + ["--act", f"{W},3"])
        check(st.get("scroll_main") == "180" and st.get("scroll_side") == "0",
              "wheel: three notches with the pointer over the page scroll the page, not the sidebar", str(st.get("scroll_main")))
        rc, out, st, _ = run(base + ["--act", f"{W},5", "--act", f"{W},258"])
        check(st.get("scroll_main") == "180", "wheel: scrolling back up by two notches", str(st.get("scroll_main")))
        rc, out, st, _ = run(base + ["--act", f"{W + 1},3"])
        check(st.get("scroll_side") == "180" and st.get("scroll_main") == "0", "wheel: over the sidebar it scrolls the sidebar", str((st.get("scroll_side"), st.get("scroll_main"))))
        rc, out, st, _ = run(base + ["--act", f"{W},3"])
        check(st.get("anim_on") == "0", "animations are off in --dump runs (tests see final states)")

        rc, out, st, _ = run(base + ["--anim", "--act", f"{W},3", "--run-ms", "700"])
        check(st.get("scroll_main") == "180" and st.get("anim_busy") == "0" and int(st.get("anim_frames", "0")) >= 5,
              "smooth scroll: ends exactly on the target after several frames", str((st.get("scroll_main"), st.get("anim_frames"), st.get("anim_busy"))))
        rc, out, st, _ = run(base + ["--anim", "--act", f"{W},3", "--act", f"{W},259", "--run-ms", "700"])
        check(st.get("scroll_main") == "0", "smooth scroll: down three then up three lands back at the top", str(st.get("scroll_main")))

        rc, out, st, _ = run(["--demo", "--dump", "--anim", "--run-ms", "800"])
        check(st.get("anim_busy") == "0" and int(st.get("anim_frames", "99")) <= 4,
              "idle: nothing animating means no frames are drawn", str((st.get("anim_frames"), st.get("anim_busy"))))

        rc, out, st, _ = run(["--demo", "--dump", "--anim", "--hover", "100,100", "--run-ms", "700"])
        check(st.get("anim_hover") == "256" and st.get("anim_busy") == "0" and int(st.get("anim_frames", "0")) >= 4,
              "hover: the highlight fades in over several frames and settles at full strength", str((st.get("anim_hover"), st.get("anim_frames"))))
        rc, out, st, _ = run(["--demo", "--dump", "--hover", "100,100", "--run-ms", "400"])
        check(st.get("anim_hover") == "256" and st.get("anim_frames") is not None and int(st["anim_frames"]) <= 4,
              "hover: without animations it is at full strength at once", str((st.get("anim_hover"), st.get("anim_frames"))))

        rc, out, st, _ = run(["--demo", "--dump", "--play", "--queue", "--anim", "--run-ms", "800"])
        check(st.get("anim_queue") == "256" and st.get("queue_open") == "1" and int(st.get("anim_frames", "0")) >= 4,
              "queue panel: slides in over several frames", str((st.get("anim_queue"), st.get("anim_frames"))))
        rc, out, st, _ = run(["--demo", "--dump", "--play", "--queue", "--run-ms", "300"])
        check(st.get("anim_queue") == "256" and int(st.get("anim_frames", "99")) <= 4, "queue panel: no animation, no extra frames", str((st.get("anim_queue"), st.get("anim_frames"))))
        rc, out, st, _ = run(["--demo", "--dump", "--play", "--queue", "--anim", "--act", f"{H_QUEUE},0", "--run-ms", "900"])
        check(st.get("anim_queue") == "0" and st.get("queue_open") == "0", "queue panel: slides out again when closed", str((st.get("anim_queue"), st.get("queue_open"))))
        rc, out, st, _ = run(["--demo", "--dump", "--play", "--queue", "--anim", "--anim-hold", "25", "--run-ms", "300"])
        check(0 < int(st.get("anim_queue", "0")) < 256, "queue panel: --anim-hold freezes it part of the way", str(st.get("anim_queue")))
        rc, out, st, _ = run(["--demo", "--dump", "--play", "--fullscreen", "--anim", "--run-ms", "900"])
        check(st.get("anim_full") == "256" and st.get("fullscreen") == "1" and int(st.get("anim_frames", "0")) >= 4,
              "full screen: slides up over several frames", str((st.get("anim_full"), st.get("anim_frames"))))
        rc, out, st, _ = run(["--demo", "--dump", "--play", "--fullscreen", "--anim", "--act", f"{H_FS_CLOSE},0", "--run-ms", "900"])
        check(st.get("anim_full") == "0" and st.get("fullscreen") == "0", "full screen: slides back down when closed", str((st.get("anim_full"), st.get("fullscreen"))))
        rc, out, st, path = run(["--demo", "--dump", "--play", "--fullscreen", "--anim", "--anim-hold", "50"], shot=True)
        if path and os.path.exists(path):
            top = pixel(path, 700, 20)          # the page behind the half-way sheet is still visible at the top
            sheet = pixel(path, 700, 700)       # and the sheet covers the bottom
            check(top != sheet, "full screen: half-way, the page shows above the sheet", str((top, sheet)))
            os.remove(path)
        else:
            check(False, "full screen: half-way screenshot taken")

    # ---- the harness itself must fail loudly when a target is absent
    rc, out, st, _ = run(["--demo", "--act", "99,0"])
    check(rc == 3 and "not on screen" in out, "an --act with no matching on-screen target fails (exit 3)")

    print(f"\n{passed} passed, {len(failed)} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
