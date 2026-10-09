; fixtures.asm - recorded API responses (tests/fixtures/*.json) embedded for --demo mode and selftests.
; Each blob is NUL-terminated so the JSON scanner can run over it directly.

%macro FIXTURE 2
%1:     incbin %2
        db 0
%endmacro

section .data
FIXTURE fx_me, "../tests/fixtures/me.json"
FIXTURE fx_playlists, "../tests/fixtures/me_playlists.json"
FIXTURE fx_playlist_items, "../tests/fixtures/playlist_items.json"
FIXTURE fx_saved_tracks, "../tests/fixtures/saved_tracks.json"
FIXTURE fx_saved_albums, "../tests/fixtures/saved_albums.json"
FIXTURE fx_recent, "../tests/fixtures/recent.json"
FIXTURE fx_search, "../tests/fixtures/search.json"
FIXTURE fx_album_tracks, "../tests/fixtures/album_tracks.json"
FIXTURE fx_queue, "../tests/fixtures/queue.json"
section .text
