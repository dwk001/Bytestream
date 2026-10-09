# ByteStream

A native Windows Spotify player written in **x86-64 assembly** (NASM). No C, no Rust, no runtime library:
the window, GDI+ drawing, JSON parser, HTTP client, OAuth, local web server and all application logic are
assembly, calling Win32 DLLs directly. One `.exe`, about 230 KB.

Features: Home, Search (results as you type), Library (playlists, liked songs, albums), playlist and album pages,
now-playing bar with seek / volume / shuffle / repeat, queue panel, full-screen view with cover-tinted
background, three themes (Dark, Midnight, Light - Sonora's palettes), per-monitor DPI scaling, cover art with anti-aliased vector icons and text,
heart buttons (save / remove), a right-click menu everywhere (add to queue, play next, add to playlist, copy link,
open in Spotify ...), playlist create / rename / delete, add and remove tracks, media keys.

> Everything is controlled from the window. There is no config file to edit and no command line to learn.

Cover art is decoded by ByteStream's own PNG and JPEG decoders (DEFLATE, Huffman, integer IDCT - all assembly, on the
download threads, a 640 px cover in about 7 ms); only formats it does not know (progressive JPEG, GIF ...) are passed to
Windows' GDI+. Everything on screen is drawn and handled by ByteStream itself, including the text boxes (caret, selection with the mouse
or Shift+arrows, Ctrl+arrows by word, copy / cut / paste, Tab between boxes) and the animations (hover fades, smooth wheel
scrolling, the queue panel and the full-screen view sliding). Nothing animates while nothing moves: an idle window draws
nothing and uses no CPU.

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
4. **Play something.** The first play starts a small hidden Microsoft Edge window (see below) and
   ByteStream appears in Spotify's device list as **ByteStream**.

Windows may show *SmartScreen* ("Windows protected your PC") the first time, because the exe is unsigned
(*More info > Run anyway*). Settings > Diagnostics has *Test audio*, *Open log folder* and *Copy diagnostics*
if anything misbehaves; the log never contains tokens.

## Checking it on your PC (nothing below can be verified without a real Spotify account)

1. Sign in; Home should fill with your playlists and recently played tracks within a few seconds.
2. Settings > Diagnostics > **Test audio** should play a short test track (the first start of Edge takes a few
   seconds). If it does not, the banner says why; otherwise *Copy diagnostics* and send them along.
3. Click a track: it plays, the seek bar moves, pause / next / previous / volume / shuffle / repeat work.
4. Click a heart (it fills in and the track appears in Liked Songs on Spotify), right-click a track (Add to
   queue, Add to playlist ...), press **+** in the sidebar to create a playlist.
5. Close ByteStream: the helper Edge window disappears with it.

Known limits: Spotify's API does not expose podcasts-only features, artist top tracks, radio or lyrics; playlists you
only follow show metadata but no tracks (Spotify's 2026 API change); a development-mode app serves at most five
listed users.

## How playback works, and why it is allowed

Spotify audio is DRM-protected. ByteStream never decodes or decrypts it. Playback uses Spotify's **official
Web Playback SDK**, which needs a browser engine with Widevine, so ByteStream starts Microsoft Edge (or Chrome)
in app mode with its own private profile, minimised, pointed at a page served by ByteStream on
`127.0.0.1`. That page is a tiny script (`web/player.js`) that makes the browser a Spotify Connect device
named ByteStream and relays commands and state to the app over local HTTP. The helper is started on the first
play, stopped after ten idle minutes, and can never outlive ByteStream (it lives in a Windows job object).

Everything else uses the official Web API with OAuth 2.0 PKCE. No librespot, no private protocol, no scraping.
Things Spotify's API cannot do are done honestly: it has no endpoint to remove, reorder or insert into the
queue, so *Play next / Remove / Move / Clear* rebuild the queue by restarting the current track from the same
position with `[current, queue...]` (playback then leaves its album or playlist context).

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
python tests/run_tests.py    # 200+ end-to-end checks against the real .exe (Wine + Xvfb on Linux)
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
