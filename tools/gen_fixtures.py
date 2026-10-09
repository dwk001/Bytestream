#!/usr/bin/env python3
"""Generate deterministic Spotify-Web-API-shaped JSON (fictional music) into tests/fixtures/.

Image URLs use the scheme `demo:<n>`; the app paints procedural cover art for them, so the
UI can be exercised (and screenshotted) with no network access.
"""
import json, os, random, zlib

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "fixtures")
rnd = random.Random(7)

ARTISTS = ["Neon Harbor", "The Quiet Engines", "Marlowe & Vane", "Saffron Static", "Kite Season",
           "Glass Orchard", "Low Tide Radio", "Paper Satellites", "Ivory Delta", "Moth Choir",
           "Violet Parade", "Night Bus Poets"]
WORDS = ["Midnight", "Static", "Lanterns", "Paper", "Echo", "Harbor", "Velvet", "Wildfire", "Orbit", "Honey",
         "Signal", "Gravity", "Daylight", "Satellite", "Mirror", "Ember", "Tide", "Neon", "Quiet", "Compass",
         "Rooftop", "Afterglow", "Zenith", "Cassette", "Monsoon", "Postcard", "Clockwork", "Dandelion"]
ALBUMS = ["Afterglow Season", "City of Lanterns", "Soft Machines", "Weather Report", "Slow Orbit",
          "Cassette Summer", "Paper Moons", "Low Light", "Night Shift Hymns", "Rooftop Sessions"]


def images(n):
    return [{"url": f"demo:{n}", "height": h, "width": h} for h in (640, 300, 64)]


def artist_list(names):
    return [{"id": f"ar{zlib.crc32(n.encode()) % 10**6}", "name": n, "uri": "spotify:artist:" + n.replace(" ", "")} for n in names]


def track(i, album_idx=None, with_album=True):
    a = ARTISTS[(i * 5) % len(ARTISTS)]
    names = [a] if i % 7 else [a, ARTISTS[(i * 5 + 3) % len(ARTISTS)]]
    alb = ALBUMS[(album_idx if album_idx is not None else i) % len(ALBUMS)]
    t = {
        "id": f"tr{i:04d}",
        "name": f"{WORDS[(i * 3) % len(WORDS)]} {WORDS[(i * 7 + 2) % len(WORDS)]}",
        "uri": f"spotify:track:tr{i:04d}",
        "duration_ms": 150000 + (i * 7919) % 120000,
        "artists": artist_list(names),
        "type": "track",
    }
    if with_album:
        ai = (album_idx if album_idx is not None else i) % len(ALBUMS)
        t["album"] = {"id": f"al{ai:03d}", "name": alb, "images": images(ai + 1),
                      "uri": f"spotify:album:al{ai:03d}", "artists": artist_list([a])}
    return t


def album(i):
    return {"id": f"al{i:03d}", "name": ALBUMS[i % len(ALBUMS)], "uri": f"spotify:album:al{i:03d}",
            "images": images(i + 1), "total_tracks": 8 + i % 6, "album_type": "album",
            "artists": artist_list([ARTISTS[(i * 5) % len(ARTISTS)]])}


def playlist(i, name, total):
    return {"id": f"pl{i:03d}", "name": name, "uri": f"spotify:playlist:pl{i:03d}", "images": images(20 + i),
            "owner": {"id": "demo", "display_name": "Demo Listener"}, "public": False,
            "items": {"total": total}}


def write(name, obj):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)
        f.write("\n")


PL = ["Daily Mix 1", "Late Night Drive", "Focus Flow", "Sunday Morning", "Road Trip Anthems", "Gym Energy",
      "Rainy Day Jazz", "Throwback Jams", "Indie Discoveries", "Coding Beats"]
write("me.json", {"id": "demo", "display_name": "Demo Listener", "images": []})
write("me_playlists.json", {"href": "x", "limit": 50, "total": len(PL), "next": None,
                            "items": [playlist(i, n, 12 + (i * 5) % 30) for i, n in enumerate(PL)]})
write("playlist_items.json", {"limit": 50, "total": 24, "next": None,
                              "items": [{"added_at": "2026-01-01T00:00:00Z", "item": track(i)} for i in range(24)]})
write("saved_tracks.json", {"total": 20, "next": None,
                            "items": [{"added_at": "2026-01-01T00:00:00Z", "track": track(30 + i)} for i in range(20)]})
write("saved_albums.json", {"total": 8, "next": None,
                            "items": [{"added_at": "2026-01-01T00:00:00Z", "album": album(i)} for i in range(8)]})
write("recent.json", {"items": [{"played_at": "2026-01-02T00:00:00Z", "track": track(60 + i)} for i in range(10)]})
write("search.json", {
    "tracks": {"items": [track(80 + i) for i in range(10)], "total": 10},
    "albums": {"items": [album(i) for i in range(4)], "total": 4},
    "artists": {"items": [{"id": f"ar{i}", "name": ARTISTS[i], "uri": f"spotify:artist:ar{i}", "images": images(40 + i)}
                          for i in range(4)], "total": 4},
    "playlists": {"items": [playlist(i, PL[i], 20) for i in range(3)] + [None], "total": 4},
})
write("album_tracks.json", {"total": 9, "next": None,
                            "items": [dict(track(100 + i, 3, with_album=False), track_number=i + 1) for i in range(9)]})
write("queue.json", {"currently_playing": track(5), "queue": [track(6 + i) for i in range(12)]})
print("fixtures written to", os.path.normpath(OUT))
