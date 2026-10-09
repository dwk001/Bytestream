# Bytestream

## sonora.asm

A [Sonora](https://github.com/sonorahq/sonora)-style local music player written in pure x86-64
assembly: NASM, Linux, **raw syscalls, no libc**. The binary is a few KB.

```
make            # nasm + ld
./sonora ~/Music
make test       # drives the real binary through a pty with scripted keystrokes
```

| key | action |
| --- | --- |
| `j` / `k` / arrows | move selection |
| `Enter` | play selected |
| `Space` | pause / resume |
| `n` / `p` | next / previous |
| `+` / `-` | volume |
| `s` / `q` | stop / quit |

### What it does

- Scans a directory (`getdents64`) for `.wav` files, sorted
- Parses RIFF/WAVE headers (8/16-bit PCM, 1–8 channels)
- Plays through OSS (`/dev/dsp`) with software volume for 16-bit audio, auto-advance at end of track
- Raw-mode terminal UI: scrolling list, now-playing line, progress bar, clock
- If `/dev/dsp` doesn't exist it runs in "silent timing mode" (UI and clock run in real time, no sound)

### What it is *not*

Upstream Sonora is ~107k lines of Rust (GPUI renderer, webview, Widevine DRM, Apple Music / Deezer /
YouTube / Subsonic clients, MP3/FLAC/AAC decoding, TLS). Full feature parity in hand-written assembly
is not realistic, so this ports the **local-library player core** only. Missing: streaming services,
TLS/HTTP, compressed codecs, GUI, playlists persistence, ALSA/PulseAudio/PipeWire (modern desktops
often need an OSS emulation layer such as `padsp`/`aoss` or `snd-pcm-oss`).

### Tested vs. not tested

Tested (`make test`): listing, sorting, playback clock, pause/stop, next/prev, arrows, volume
control, auto-advance, malformed files, empty/missing directories.
**Not tested:** actual audio output — the dev container has no sound device, so the `/dev/dsp`
code path (open + `SNDCTL_DSP_*` ioctls + writes) is unverified on real hardware.
