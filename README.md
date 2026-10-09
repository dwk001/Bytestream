# ByteStream

A native Windows Spotify player written in **x86-64 assembly** (NASM). No C, no Rust, no runtime library:
the window, GDI+ drawing, JSON parser, HTTP client, OAuth, local web server and all application logic are
assembly, calling Win32 DLLs directly. One `.exe`, about 260 KB (plus the optional audio helper next to it).

Features: Home, Search (results as you type), Library (playlists, liked songs, albums), playlist and album pages,
now-playing bar with seek / volume / shuffle / repeat, queue panel, full-screen view with cover-tinted
background, three themes (Dark, Midnight, Light - Sonora's palettes), per-monitor DPI scaling, cover art with anti-aliased vector icons and text,
heart buttons (save / remove), a right-click menu everywhere (add to queue, play next, add to playlist, copy link,
open in Spotify ...), playlist create / rename / delete, add and remove tracks, media keys.

> Everything is controlled from the window. There is no config file to edit and no command line to learn.

Cover art is decoded by ByteStream's own PNG and JPEG decoders (DEFLATE, Huffman, integer IDCT - all assembly, on the
download threads, a 640 px cover in about 7 ms, pixel-identical to libjpeg's output); only formats it does not know (progressive JPEG, GIF ...) are passed to
Windows' GDI+. Everything on screen is drawn and handled by ByteStream itself, including the text boxes (caret, selection with the mouse
or Shift+arrows, Ctrl+arrows by word, copy / cut / paste, Tab between boxes) and the animations (hover fades, smooth wheel
scrolling, the queue panel and the full-screen view sliding). Nothing animates while nothing moves: an idle window draws
nothing and uses no CPU.

## What is assembly, and what is Windows

Everything in `src/` (about 25,000 lines) is hand-written NASM. The program itself does: JSON parsing, the HTTP client's
request logic, OAuth with PKCE, the local web server, the list / track / card models, layout and hit-testing, every widget
(buttons, rows, cards, menus, dialogs, the text boxes), animation, the cover cache, and the **PNG and JPEG decoders**.
It asks Windows for: opening a window and getting input (user32), shape / text rasterisation and bitmap scaling (GDI+),
TLS and HTTP transport (WinHTTP), sockets (Winsock), random numbers, SHA-256 and token encryption (bcrypt, DPAPI),
and the clipboard. The non-assembly parts that ship are separate programs, never linked in: `go-librespot.exe` (the
default audio engine, written in Go) and `web/player.js` (about 100 lines, the Edge engine: Spotify's playback SDK is
JavaScript and needs a browser with DRM, so a hidden Edge window hosts it and talks to ByteStream over local HTTP).

## Setting it up (once)

1. **Premium.** Spotify only lets third-party players stream with a Premium account.
2. **Register an app.** Open <https://developer.spotify.com/dashboard>, create an app and add
   `http://127.0.0.1:8989/callback` as a Redirect URI (ByteStream shows the exact address, with a Copy button, on
   its first screen and in Settings). While the app is in *development mode* Spotify lets you list up to five
   users; add your own account under *User management*.
3. **Paste the client ID** into ByteStream's first screen and press *Sign in with Spotify*. Your browser opens
   Spotify's consent page; when you accept, ByteStream is signed in. The sign-in uses OAuth with PKCE, so no
   client secret exists. Your refresh token is stored encrypted for your Windows account (DPAPI) in
   `%APPDATA%\ByteStream\auth.bin`; *Sign out* in Settings deletes it.
4. **Play something.** The first play starts the audio engine (see below) and ByteStream appears in Spotify's device
   list as **ByteStream**. With the lightweight engine the very first play also shows a one-time banner with a
   pairing code: press **Open page**, sign in to Spotify there and confirm the code; playback then starts by itself.

Windows may show *SmartScreen* ("Windows protected your PC") the first time, because the exe is unsigned
(*More info > Run anyway*). Settings > Diagnostics has *Test audio*, *Open log folder* and *Copy diagnostics*
if anything misbehaves; the log never contains tokens.

## Checking it on your PC (nothing below can be verified without a real Spotify account)

1. Sign in; Home should fill with your playlists and recently played tracks within a few seconds.
2. Settings > Diagnostics > **Test audio** should play a short test track (the first start takes a few seconds; the
   first ever one asks you to pair the helper). If it does not, the banner says why; otherwise *Copy diagnostics*
   and send them along together with `librespot.log` (same folder as `bytestream.log`).
3. Click a track: it plays, the seek bar moves, pause / next / previous / volume / shuffle / repeat work.
4. Click a heart (it fills in and the track appears in Liked Songs on Spotify), right-click a track (Add to
   queue, Add to playlist ...), press **+** in the sidebar to create a playlist.
5. Close ByteStream: the helper (go-librespot, or the Edge window) disappears with it. Task Manager shows how little
   memory the lightweight engine uses compared with Edge.

Known limits: Spotify's API does not expose podcasts-only features, artist top tracks, radio or lyrics; playlists you
only follow show metadata but no tracks (Spotify's 2026 API change); a development-mode app serves at most five
listed users.

## How playback works: two engines

Spotify audio is DRM-protected and ByteStream never decodes or decrypts it itself. Something else has to talk to
Spotify's streaming service, and there are two choices, selectable in **Settings > Playback engine**:

**Lightweight (default when `go-librespot.exe` is next to `bytestream.exe`).** A small separate program,
[go-librespot](https://github.com/devgianlu/go-librespot) (GPL-3.0, shipped unmodified, see `THIRD-PARTY.txt`), appears in
Spotify as a Connect device named *ByteStream* and plays through Windows' own audio (WASAPI). ByteStream starts it
hidden on the first play, controls it over a local API on a random `127.0.0.1` port (play / pause, next, previous, seek
and volume cost no Spotify requests), reads what is playing from it, and stops it after ten idle minutes. It dies with
ByteStream (Windows job object). No browser is involved, so the memory of the whole player stays small. The first time,
ByteStream shows a banner with a pairing code and an **Open page** button (spotify.com/pair); after that the login is
remembered in `%APPDATA%\ByteStream\librespot\state.json` and *Sign out* forgets it. Its output goes to
`librespot.log` in the same folder.

> **Honest warning.** go-librespot speaks Spotify's own client protocol, which is not a published API. Spotify's terms
> forbid third-party programs from doing that (go-librespot's own README says as much), so using this engine is
> against Spotify's terms of service. For your own Premium account the practical risk is small but real (Spotify could
> warn or suspend an account), and Spotify can change the protocol and break it at any time. Use it at your own
> risk, for personal use, and never share a build that uses it.

**Microsoft Edge.** The terms-compliant option: Spotify's **official Web Playback SDK** needs a browser engine with
Widevine, so ByteStream starts Microsoft Edge (or Chrome) in app mode with its own private profile, minimised, pointed
at a page served by ByteStream on `127.0.0.1`. That page is a tiny script (`web/player.js`) that makes the browser a
Spotify Connect device named ByteStream and relays commands and state to the app over local HTTP. It uses a few
hundred MB of RAM more than the lightweight engine. If `go-librespot.exe` is missing, ByteStream uses this engine
automatically.

Everything else (library, search, playlists, likes, queue, "play this album") uses the official Web API with OAuth 2.0
PKCE, whichever engine is chosen. Things Spotify's API cannot do are done honestly: it has no endpoint to remove,
reorder or insert into the queue, so *Play next / Remove / Move / Clear* rebuild the queue by restarting the current
track from the same position with `[current, queue...]` (playback then leaves its album or playlist context).

Spotify's Developer Policy asks that apps add independent value and not replace Spotify's core experience; this is
a personal, non-commercial project for a development-mode app. Music, metadata and cover art belong to Spotify
(*Open in Spotify* is in every right-click menu). ByteStream is not affiliated with Spotify; Spotify is a
trademark of Spotify AB.

## Security notes

- The local server binds only to `127.0.0.1`, checks the `Host` header exactly (DNS rebinding), requires a
  per-run random secret for the player page and its bridge, sends no CORS headers, and accepts a sign-in
  callback exactly once for the state value it issued.
- Tokens exist only in memory and in the DPAPI-encrypted file; logs and *Copy diagnostics* redact them.
- Only one ByteStream runs per data directory (a second launch focuses the first).

## Build

Needs `nasm`, `lld-link` (LLVM) and Python 3. Works on Linux (cross-assembling) and on Windows.

```
python tools/build.py        # -> build/bytestream.exe (+ build.map for crash reports)
make                         # the same, via make
python tests/run_tests.py    # 330+ end-to-end checks against the real .exe (Wine + Xvfb on Linux)
```

`tests/fake_spotify.py` is a small stateful Spotify (accounts + Web API + images) the tests run the app against;
`tests/player_page.js` tests `web/player.js` against a mocked SDK in headless Chromium. GitHub Actions
(`.github/workflows/windows.yml`) builds and runs everything on a real Windows runner, renders screenshots and
uploads the exe.

Developer flags (for the tests; normal use needs none):

| flag | effect |
| --- | --- |
| `--demo` | built-in sample music instead of signing in |
| `--selftest` | unit checks |
| `--page N` `--tab N` `--detail N` `--theme N` `--size WxH` `--scale P` | start on a screen |
| `--play` `--seek S` `--volume V` `--queue` `--fullscreen` | start in a playback state |
| `--act ID,ARG` / `--ctx ID,ARG` | click / right-click a control that is really on screen (ids 0xF000.. are pseudo targets: keys, text and mouse for the text fields, wheel for the page) |
| `--click X,Y` `--drag-to X,Y` | press / release the left button at a position through the real mouse path |
| `--anim` `--anim-hold P` `--shot-ms N` | keep animations on in a `--dump` / `--screenshot` run, freeze the sliding panels at P %, take the screenshot after N ms |
| `--clip-in TEXT` | what Ctrl+V pastes in a `--no-browser` run |
| `--decode FILE` `--decode-out RAW` `--decode-fuzz N` | run a picture through the program's own decoders (size, BGRA dump, damaged-copy fuzzing) |
| `--act-late` `--ctx-late` `--hold` | the same, driven by a fake player page |
| `--dump` | print the app state as `key=value` lines |
| `--screenshot FILE.bmp` | save the frame and exit |
| `--api-base` `--auth-base` `--no-browser` `--data-dir` | point at the fake Spotify, print instead of opening |

## Layout

```
src/        assembly sources (main.asm includes the rest)
web/        the player page for the Web Playback SDK
tests/      end-to-end tests, fake Spotify, recorded API shapes
tools/      import-library generator, build script, screenshot and crash-map helpers
```

Crash reports in the log hold function offsets; `python tools/crashmap.py build/bytestream.map --log bytestream.log`
turns them into function names (use the map from the same build).
