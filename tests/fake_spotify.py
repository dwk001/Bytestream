#!/usr/bin/env python3
"""A small stateful fake of the Spotify Accounts + Web API, for testing ByteStream end to end.

    python3 tests/fake_spotify.py [--port 0]      prints "PORT=<n>" and serves until killed

Every request is appended to the in-memory log, readable at  GET /__log  (JSON list), and cleared with
POST /__reset.  Responses for the data endpoints come from tests/fixtures/*.json.
"""
import json, os, sys, threading, time, urllib.parse
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
        self.codes = {}           # code -> verifier challenge
        self.tokens = {"access-1": time.time() + 3600}
        self.refresh_ok = True
        self.fail_next = {}       # path-prefix -> (status, retry_after)


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
