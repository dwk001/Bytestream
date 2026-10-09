# ByteStream

A native Windows Spotify player written in **x86-64 assembly** (NASM). No C, no Rust, no runtime:
the window, GDI+ drawing, JSON parser and application logic are all assembly, calling Win32 DLLs
directly.

> Status: work in progress. The UI, data model and test harness are done and run in a built-in demo
> mode. Live Spotify sign-in, API calls and in-app playback are the next milestones (see below).

## What it does today

- Home, Search, Library (playlists / liked songs / albums), playlist and album pages
- Now-playing bar with seek, volume, shuffle, repeat, queue panel and full-screen view
- Cover art with an ambient colour tint, anti-aliased vector icons and text (GDI+)
- Dark, Midnight and Light themes; per-monitor DPI scaling
- `--demo` mode with built-in sample music, so the whole UI works offline

## Spotify and the terms of service

ByteStream will use only Spotify's **official** interfaces:

- OAuth 2.0 Authorization Code with PKCE (loopback redirect `http://127.0.0.1:8989/callback`)
- The Spotify Web API for your library, playlists and search
- The Spotify **Web Playback SDK**, hosted in WebView2, so audio plays inside ByteStream

It does not decode or decrypt Spotify's streams and does not use any private protocol.
Playback requires **Spotify Premium** (a Spotify requirement), and the app must be registered in the
[Spotify developer dashboard](https://developer.spotify.com/dashboard); you paste its client ID into
ByteStream on first run. ByteStream is not affiliated with Spotify.

## Build

Needs `nasm`, `lld-link` and Python 3. Works on Linux (cross-assembling) and on Windows.

```
make                 # -> build/bytestream.exe
make test            # unit selftests + scripted UI flows
```

On Linux the tests run the real `.exe` under Wine + Xvfb. Useful flags:

| flag | effect |
| --- | --- |
| `--demo` | load built-in sample music instead of signing in |
| `--selftest` | run the unit checks and exit |
| `--page N` `--tab N` `--detail N` `--theme N` | start on a given screen / theme |
| `--play` `--seek S` `--volume V` `--queue` `--fullscreen` | start in a playback state |
| `--act ID,ARG` | activate an on-screen control (fails if it is not actually on screen) |
| `--dump` | print the app state as `key=value` lines |
| `--screenshot FILE.bmp` | save the rendered frame and exit |

`tools/render_all.sh` renders every screen to PNG.

## Layout

```
src/        assembly sources (main.asm includes the rest)
web/        player page for the Spotify Web Playback SDK
tests/      end-to-end tests and recorded API fixtures
tools/      import-library generator, screenshot and fixture helpers
```
