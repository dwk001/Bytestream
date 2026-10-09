#!/usr/bin/env python3
"""A small stateful fake of the Spotify Accounts + Web API, for testing ByteStream end to end.

    python3 tests/fake_spotify.py [--port 0]      prints "PORT=<n>" and serves until killed

Every request is appended to the in-memory log, readable at  GET /__log  (JSON list), and cleared with
POST /__reset.  Responses for the data endpoints come from tests/fixtures/*.json.
"""
import base64, hashlib, json, os, re, secrets, struct, sys, threading, time, urllib.parse, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def fixture(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as f:
        return json.load(f)


def png_for(n):
    """A small solid-colour PNG whose colour depends on n (so different covers differ)."""
    w = h = 48
    r, g, b = (37 * n + 60) % 200 + 40, (91 * n + 30) % 200 + 40, (53 * n + 90) % 200 + 40
    raw = b"".join(b"\x00" + bytes((r, g, b)) * w for _ in range(h))

    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.log = []
        self.reset()

    def reset(self):
        self.log.clear()
        self.codes = {}           # authorization code -> {challenge, redirect_uri, client_id}
        self.access = {}          # access token -> expiry (epoch seconds)
        self.refresh = {}         # refresh token -> client_id (revoked tokens are removed)
        self.counter = 0
        self.valid_clients = None  # None = accept any client id, else a set
        self.deny = False         # /authorize answers access_denied
        self.expires_in = 3600
        self.forbid_me = False    # /v1/me answers 403 (account not on the allow-list)
        self.rotate_refresh = False
        self.fail_next = {}       # path-prefix -> (status, retry_after)
        self.play_reply = None    # (status, json) answer for PUT /v1/me/player/play instead of 204
        self.page_limit = None    # cap on the page size of paged endpoints (None = honour the request's limit)
        self.real_images = False  # rewrite "demo:N" cover URLs to http://<this server>/img/N.png (or N.jpg when set to "jpg")
        self.forbidden_playlists = set()   # playlist ids whose /items answer 403
        self.empty_playlists = set()       # playlist ids whose /items answer 200 with no items but a total
        self.delay = {}           # path prefix -> seconds to wait before answering
        self.saved = None         # set of saved URIs (None = start from the fixtures: liked tracks, saved albums, playlists)
        self.library_status = None  # force this status for PUT/DELETE /v1/me/library
        self.queue_added = []     # URIs POSTed to /v1/me/player/queue
        self.queue_status = None
        self.play_404 = 0         # answer this many PUT /me/player/play requests with 404 (device not known yet)
        self.unplayable = set()   # track URIs reported with is_playable: false in recently played
        self.playlists = None     # the user's playlists (None = start from the fixture); create/rename/delete change it
        self.playlist_status = None  # force this status for playlist-changing requests


STATE = State()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # silence
        pass

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _send(self, status, obj=None, raw=None, ctype="application/json", extra=None):
        data = raw if raw is not None else (json.dumps(obj).encode() if obj is not None else b"")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _record(self, body):
        entry = {
            "method": self.command,
            "path": self.path,
            "headers": {k: v for k, v in self.headers.items()},
            "body": body.decode("utf-8", "replace"),
        }
        with STATE.lock:
            STATE.log.append(entry)
        return entry

    def _handle(self):
        body = self._body()
        self._cached_body = body
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/__log":
            with STATE.lock:
                return self._send(200, STATE.log)
        if u.path == "/__reset":
            STATE.reset()
            return self._send(200, {"ok": True})
        entry = self._record(body)
        with STATE.lock:
            for prefix, (status, retry) in list(STATE.fail_next.items()):
                if u.path.startswith(prefix):
                    del STATE.fail_next[prefix]
                    return self._send(status, {"error": {"status": status}},
                                      extra={"Retry-After": str(retry)} if retry else None)
        if u.path == "/authorize":
            return self._authorize(q)
        if u.path == "/api/token" and self.command == "POST":
            return self._token(urllib.parse.parse_qs(body.decode()))
        if u.path == "/v1/me":
            return self._me()
        if self._library(u, q):
            return
        if u.path == "/v1/me/player/play" and self.command == "PUT":
            return self._play(q)
        if u.path == "/echo":
            return self._send(200, {"method": entry["method"], "path": entry["path"],
                                    "headers": entry["headers"], "body": entry["body"]})
        if u.path == "/status":                       # /status?code=429&retry=3
            code = int(q.get("code", ["200"])[0])
            retry = q.get("retry", [None])[0]
            return self._send(code, {"status": code}, extra={"Retry-After": retry} if retry else None)
        if u.path == "/big":                          # large body, exercises read looping
            return self._send(200, raw=(b"x" * 300000))
        self._send(404, {"error": {"status": 404, "message": "unknown fake endpoint " + u.path}})

    # ---- the Accounts service
    def _authorize(self, q):
        g = lambda k: (q.get(k) or [""])[0]
        with STATE.lock:
            bad = (g("response_type") != "code" or g("code_challenge_method") != "S256" or not g("code_challenge")
                   or not g("state") or not g("redirect_uri") or not g("client_id"))
            if bad:
                return self._send(400, {"error": "invalid_request"})
            if STATE.valid_clients is not None and g("client_id") not in STATE.valid_clients:
                return self._send(400, {"error": "invalid_client"})
            if STATE.deny:
                loc = g("redirect_uri") + "?" + urllib.parse.urlencode({"error": "access_denied", "state": g("state")})
            else:
                code = "code-" + secrets.token_urlsafe(600)         # real Spotify codes are 740+ characters long
                STATE.codes[code] = {"challenge": g("code_challenge"), "redirect_uri": g("redirect_uri"),
                                     "client_id": g("client_id"), "scope": g("scope")}
                loc = g("redirect_uri") + "?" + urllib.parse.urlencode({"code": code, "state": g("state")})
        self._send(302, raw=b"", extra={"Location": loc})

    def _issue(self, client_id, with_refresh):
        STATE.counter += 1
        access = "access-%d" % STATE.counter
        STATE.access[access] = time.time() + STATE.expires_in
        out = {"access_token": access, "token_type": "Bearer", "expires_in": STATE.expires_in,
               "scope": "streaming user-read-private"}
        if with_refresh:
            ref = "refresh-%d-%s" % (STATE.counter, secrets.token_hex(4))
            STATE.refresh[ref] = client_id
            out["refresh_token"] = ref
        return out

    def _token(self, form):
        g = lambda k: (form.get(k) or [""])[0]
        with STATE.lock:
            if STATE.valid_clients is not None and g("client_id") not in STATE.valid_clients:
                return self._send(401, {"error": "invalid_client"})
            if g("grant_type") == "authorization_code":
                info = STATE.codes.pop(g("code"), None)          # codes are single-use
                if not info or info["redirect_uri"] != g("redirect_uri") or info["client_id"] != g("client_id"):
                    return self._send(400, {"error": "invalid_grant", "error_description": "Invalid authorization code"})
                digest = base64.urlsafe_b64encode(hashlib.sha256(g("code_verifier").encode()).digest()).rstrip(b"=").decode()
                if digest != info["challenge"]:
                    return self._send(400, {"error": "invalid_grant", "error_description": "code_verifier was incorrect"})
                return self._send(200, self._issue(g("client_id"), True))
            if g("grant_type") == "refresh_token":
                if STATE.refresh.get(g("refresh_token")) != g("client_id"):
                    return self._send(400, {"error": "invalid_grant", "error_description": "Refresh token revoked"})
                out = self._issue(g("client_id"), STATE.rotate_refresh)
                if STATE.rotate_refresh:
                    STATE.refresh.pop(g("refresh_token"), None)
                return self._send(200, out)
            return self._send(400, {"error": "unsupported_grant_type"})

    def _me(self):
        auth = self.headers.get("Authorization", "")
        with STATE.lock:
            tok = auth[7:] if auth.startswith("Bearer ") else ""
            if STATE.access.get(tok, 0) < time.time():
                return self._send(401, {"error": {"status": 401, "message": "The access token expired"}})
            if STATE.forbid_me:
                return self._send(403, {"error": {"status": 403, "message": "User not registered in the Developer Dashboard"}})
        self._send(200, fixture("me.json"))

    # ---- the library endpoints, served from the fixtures with real paging
    def _authed(self):
        auth = self.headers.get("Authorization", "")
        tok = auth[7:] if auth.startswith("Bearer ") else ""
        with STATE.lock:
            return STATE.access.get(tok, 0) >= time.time()

    def _json_out(self, obj, status=200):
        text = json.dumps(obj)
        if STATE.real_images:
            host = self.headers.get("Host", "127.0.0.1")
            ext = "jpg" if STATE.real_images == "jpg" else "png"
            text = re.sub(r'"demo:(\d+)"', lambda m: '"http://%s/img/%s.%s"' % (host, m.group(1), ext), text)
        self._send(status, raw=text.encode())

    def _paged(self, u, q, items, wrap=None, key="items"):
        total = len(items)
        off = int((q.get("offset") or ["0"])[0])
        lim = int((q.get("limit") or ["50"])[0])
        if STATE.page_limit:
            lim = min(lim, STATE.page_limit)
        page = items[off:off + lim]
        nxt = None
        if off + lim < total:
            qs = dict((k, v[0]) for k, v in q.items())
            qs["offset"] = str(off + lim)
            qs["limit"] = str(lim)
            nxt = "http://%s%s?%s" % (self.headers.get("Host", "127.0.0.1"), u.path, urllib.parse.urlencode(qs))
        return {"href": "x", "limit": lim, "offset": off, "total": total, "next": nxt, key: page}

    def _pls(self):
        if STATE.playlists is None:
            STATE.playlists = list(fixture("me_playlists.json")["items"])
        return STATE.playlists

    def _playlist_change(self, u, q, m):
        body = self._cached_body
        if not self._authed():
            self._send(401, {"error": {"status": 401}})
            return True
        if STATE.playlist_status:
            self._send(STATE.playlist_status, {"error": {"status": STATE.playlist_status}})
            return True
        path = u.path
        if path == "/v1/me/playlists":
            obj = json.loads(body or b"{}")
            with STATE.lock:
                pls = self._pls()
                new = {"id": "newpl%d" % (len(pls) + 1), "uri": "spotify:playlist:newpl%d" % (len(pls) + 1), "name": obj.get("name", ""),
                       "description": obj.get("description", ""), "public": obj.get("public", True), "collaborative": False,
                       "images": [], "owner": {"id": "demo", "display_name": "Demo Listener"}, "items": {"total": 0}}
                pls.insert(0, new)
            self._send(201, new)
        elif path.endswith("/items"):
            self._send(201 if m == "POST" else 200, {"snapshot_id": "snap"})
        else:
            ident = path.rsplit("/", 1)[1]
            obj = json.loads(body or b"{}")
            with STATE.lock:
                for x in self._pls():
                    if x["id"] == ident:
                        x.update({k: v for k, v in obj.items() if k in ("name", "description", "public")})
            self._send(200, raw=b"")
        return True

    def _saved(self):
        with STATE.lock:
            if STATE.saved is None:
                STATE.saved = {t["track"]["uri"] for t in fixture("saved_tracks.json")["items"]}
                STATE.saved |= {a["album"]["uri"] for a in fixture("saved_albums.json")["items"]}
            return STATE.saved

    def _library(self, u, q):
        path, m = u.path, self.command
        if (m in ("PUT", "POST", "DELETE") and re.fullmatch(r"/v1/playlists/[^/]+(/items)?", path)) or (m == "POST" and path == "/v1/me/playlists"):
            return self._playlist_change(u, q, m)
        if m != "GET" and not path.startswith("/img/") and path not in ("/v1/me/library", "/v1/me/player/queue"):
            return False
        routes = ("/v1/me/playlists", "/v1/me/tracks", "/v1/me/albums", "/v1/me/player/recently-played", "/v1/search",
                  "/v1/me/library", "/v1/me/library/contains", "/v1/me/player/queue")
        is_lib = path in routes or re.fullmatch(r"/v1/artists/[^/]+/albums", path) or re.fullmatch(r"/v1/(playlists|albums)/[^/]+/(items|tracks)", path) or path.startswith("/img/")
        if not is_lib:
            return False
        for prefix, secs in list(STATE.delay.items()):
            if path.startswith(prefix):
                time.sleep(secs)
        if path.startswith("/img/"):
            n = int(re.sub(r"\D", "", path) or "0")
            if path.endswith(".jpg"):
                with open(os.path.join(FIX, "cover.jpg"), "rb") as f:
                    self._send(200, raw=f.read(), ctype="image/jpeg")
            else:
                self._send(200, raw=png_for(n), ctype="image/png")
            return True
        if not self._authed():
            self._send(401, {"error": {"status": 401, "message": "The access token expired"}})
            return True
        if path == "/v1/me/library/contains":
            uris = (q.get("uris") or [""])[0].split(",")
            saved = self._saved()
            self._send(200, [x in saved for x in uris])
        elif path == "/v1/me/library":
            if STATE.library_status:
                self._send(STATE.library_status, {"error": {"status": STATE.library_status}})
                return True
            uris = (q.get("uris") or [""])[0].split(",")
            saved = self._saved()
            if m == "PUT":
                saved.update(uris)
            elif m == "DELETE":
                saved.difference_update(uris)
                with STATE.lock:
                    pls = self._pls()
                    for u_ in uris:
                        if u_.startswith("spotify:playlist:"):
                            pls[:] = [x for x in pls if x["uri"] != u_]
            self._send(200, raw=b"")
        elif path == "/v1/me/player/queue":
            if m == "POST":
                if STATE.queue_status:
                    self._send(STATE.queue_status, {"error": {"status": STATE.queue_status}})
                else:
                    STATE.queue_added.append((q.get("uri") or [""])[0])
                    self._send(204)
            else:
                qd = fixture("queue.json")
                self._json_out(qd)
        elif path == "/v1/me/playlists":
            self._json_out(self._paged(u, q, list(self._pls())))
        elif path == "/v1/me/tracks":
            self._json_out(self._paged(u, q, fixture("saved_tracks.json")["items"]))
        elif path == "/v1/me/albums":
            self._json_out(self._paged(u, q, fixture("saved_albums.json")["items"]))
        elif path == "/v1/me/player/recently-played":
            items = fixture("recent.json")["items"]
            for it in items:
                if it["track"]["uri"] in STATE.unplayable:
                    it["track"]["is_playable"] = False
            self._json_out({"items": items, "next": None})
        elif path == "/v1/search":
            self._json_out(fixture("search.json"))
        elif path.startswith("/v1/artists/"):
            self._json_out(self._paged(u, q, [a["album"] for a in fixture("saved_albums.json")["items"]]))
        else:
            kind, ident = path.split("/")[2], path.split("/")[3]
            if kind == "playlists":
                if ident in STATE.forbidden_playlists:
                    self._send(403, {"error": {"status": 403, "message": "Forbidden"}})
                elif ident in STATE.empty_playlists:
                    self._json_out({"href": "x", "limit": 100, "offset": 0, "total": 7, "next": None, "items": []})
                else:
                    self._json_out(self._paged(u, q, fixture("playlist_items.json")["items"]))
            else:
                self._json_out(self._paged(u, q, fixture("album_tracks.json")["items"]))
        return True

    def _play(self, q):
        auth = self.headers.get("Authorization", "")
        with STATE.lock:
            tok = auth[7:] if auth.startswith("Bearer ") else ""
            if STATE.access.get(tok, 0) < time.time():
                return self._send(401, {"error": {"status": 401, "message": "The access token expired"}})
            if STATE.play_404 > 0:
                STATE.play_404 -= 1
                return self._send(404, {"error": {"status": 404, "reason": "NO_ACTIVE_DEVICE", "message": "Device not found"}})
            if STATE.play_reply:
                status, obj = STATE.play_reply
                return self._send(status, obj)
        if not q.get("device_id"):
            return self._send(404, {"error": {"status": 404, "reason": "NO_ACTIVE_DEVICE", "message": "No active device found"}})
        self._send(204)

    do_GET = do_POST = do_PUT = do_DELETE = _handle


def main():
    port = 0
    if "--port" in sys.argv:
        port = int(sys.argv[sys.argv.index("--port") + 1])
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("PORT=%d" % srv.server_address[1], flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
