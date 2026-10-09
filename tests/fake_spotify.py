#!/usr/bin/env python3
"""A small stateful fake of the Spotify Accounts + Web API, for testing ByteStream end to end.

    python3 tests/fake_spotify.py [--port 0]      prints "PORT=<n>" and serves until killed

Every request is appended to the in-memory log, readable at  GET /__log  (JSON list), and cleared with
POST /__reset.  Responses for the data endpoints come from tests/fixtures/*.json.
"""
import base64, hashlib, json, os, secrets, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def fixture(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as f:
        return json.load(f)


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
                code = "code-" + secrets.token_hex(8)
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

    def _play(self, q):
        auth = self.headers.get("Authorization", "")
        with STATE.lock:
            tok = auth[7:] if auth.startswith("Bearer ") else ""
            if STATE.access.get(tok, 0) < time.time():
                return self._send(401, {"error": {"status": 401, "message": "The access token expired"}})
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
