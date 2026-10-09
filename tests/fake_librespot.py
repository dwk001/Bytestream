#!/usr/bin/env python3
"""A stand-in for go-librespot's local API (the part ByteStream uses), for tests.

Shapes follow go-librespot v0.10.3's api-spec.yml and a real run in CI:
  GET  /               {"playback_ready": bool}
  GET  /status         204 while it has no Spotify session, else the ApiStatus object
  GET  /auth/code      200 {"code","url","expires_at"} while waiting for the user to pair, else 204
  POST /player/{playpause,resume,pause,next,prev,stop}, /player/seek {"position"}, /player/volume {"volume"}
Every request is recorded in .log as (method, path, body-json).
"""
import http.server, json, threading


class FakeLibrespot:
    def __init__(self, port):
        self.port = port
        self.log = []
        self.logged_in = False          # False: /status answers 204 and /auth/code hands out a pairing code
        self.code = "ABCDEF"
        self.device_id = "eeed41dc06c89e497cfc0aa0ccbb7b74075aa3ae"
        self.track = None               # dict in go-librespot's track shape, or None
        self.paused = False
        self.stopped = True
        self.shuffle = False
        self.repeat_context = False
        self.repeat_track = False
        owner = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, status, obj=None):
                body = b"" if obj is None else json.dumps(obj).encode()
                self.send_response(status)
                if obj is not None:
                    self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                owner.log.append(("GET", self.path, None))
                if self.path == "/":
                    return self._send(200, {"playback_ready": owner.logged_in})
                if self.path == "/status":
                    if not owner.logged_in:
                        return self._send(204)
                    return self._send(200, owner.status())
                if self.path == "/auth/code":
                    if owner.logged_in:
                        return self._send(204)
                    return self._send(200, {"code": owner.code, "expires_at": "2099-01-01T00:00:00Z",
                                            "url": "https://spotify.com/pair?code=" + owner.code})
                self._send(404)

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(n) if n else b""
                try:
                    body = json.loads(raw) if raw else None
                except ValueError:
                    body = {"_raw": raw.decode("utf-8", "replace")}
                owner.log.append(("POST", self.path, body))
                if self.path == "/player/playpause":
                    owner.paused = not owner.paused
                elif self.path == "/player/pause":
                    owner.paused = True
                elif self.path == "/player/resume":
                    owner.paused = False
                elif self.path == "/player/seek" and owner.track and body:
                    owner.track["position"] = body["position"]
                self._send(204)

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), H)
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def status(self):
        return {
            "username": "tester", "device_id": self.device_id, "device_type": "computer", "device_name": "ByteStream",
            "play_origin": "api", "play_origin_device_id": None, "context_uri": None, "context_name": None,
            "stopped": self.stopped, "paused": self.paused, "buffering": False, "volume": 70, "volume_steps": 100,
            "repeat_context": self.repeat_context, "repeat_track": self.repeat_track, "shuffle_context": self.shuffle,
            "track": self.track,
        }

    def play(self, uri, name, artists, album, cover, position=0, duration=215000):
        self.track = {"uri": uri, "name": name, "artist_names": artists, "artist_uris": [], "album_name": album,
                      "album_uri": "spotify:album:x", "album_cover_url": cover, "position": position,
                      "duration": duration, "release_date": "2020-01-01", "track_number": 1, "disc_number": 1,
                      "format": "OGG_VORBIS_320", "codec": "vorbis", "bitrate": 320, "sample_rate": 44100, "bit_depth": None}
        self.stopped = False
        self.paused = False

    def posts(self, path=None):
        return [e for e in self.log if e[0] == "POST" and (path is None or e[1] == path)]

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()
