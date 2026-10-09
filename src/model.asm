; model.asm - in-memory records and the parsers that fill them from Spotify Web API JSON.
;
; Track (56 bytes)                         Card (56 bytes: playlist / album / artist)
;   +0  title   UTF-16*                      +0  name   UTF-16*
;   +8  artist  UTF-16* (joined)             +8  sub    UTF-16*  ("By x", artists, "Artist")
;   +16 album   UTF-16*                      +16 uri    UTF-8*
;   +24 uri     UTF-8*                       +24 id     UTF-8*
;   +32 img_s   UTF-8* (smallest cover)      +32 img_m  UTF-8* (medium cover)
;   +40 img_l   UTF-8* (largest cover)       +40 img_l  UTF-8*
;   +48 dur_ms  dword                        +48 kind   dword (0 playlist, 1 album, 2 artist)
;                                            +52 count  dword
; List { ptr, count, cap }  - elements are stored inline.

%define TR_TITLE  0
%define TR_ARTIST 8
%define TR_ALBUM  16
%define TR_URI    24
%define TR_IMG_S  32
%define TR_IMG_L  40
%define TR_DUR    48
%define TR_SIZE   56

%define CD_NAME   0
%define CD_SUB    8
%define CD_URI    16
%define CD_ID     24
%define CD_IMG_M  32
%define CD_IMG_L  40
%define CD_KIND   48
%define CD_COUNT  52
%define CD_SIZE   56

%define LS_PTR    0
%define LS_COUNT  8
%define LS_CAP    16

%define KIND_PLAYLIST 0
%define KIND_ALBUM    1
%define KIND_ARTIST   2

%macro ZSTR 2
%1:     db %2, 0
%endmacro

section .data
ZSTR k_name, "name"
ZSTR k_uri, "uri"
ZSTR k_id, "id"
ZSTR k_item, "item"
ZSTR k_track, "track"
ZSTR k_album, "album"
ZSTR k_artists, "artists"
ZSTR k_dur, "duration_ms"
ZSTR k_url, "url"
ZSTR k_album_name, "album.name"
ZSTR k_album_images, "album.images"
ZSTR k_images, "images"
ZSTR k_owner_name, "owner.display_name"
ZSTR k_items_total, "items.total"
ZSTR k_tracks_total, "tracks.total"
ZSTR k_total_tracks, "total_tracks"
ZSTR k_by, "By "
ZSTR k_artist_lbl, "Artist"
ZSTR k_comma, ", "
ZSTR k_empty, ""

section .text

; ---------------------------------------------------------------- lists
; rcx = List*, rdx = element size -> rax = pointer to a new zeroed element
PROC list_push, 2
        mov     rbx, rcx
        mov     loc(0), rdx
        mov     rax, [rbx+LS_COUNT]
        cmp     rax, [rbx+LS_CAP]
        jb      .ok
        mov     rcx, [rbx+LS_CAP]
        add     rcx, rcx
        cmp     rcx, 16
        jae     .g
        mov     ecx, 16
.g:     mov     [rbx+LS_CAP], rcx
        mov     rdx, rcx
        imul    rdx, loc(0)             ; bytes = cap * element size
        mov     rcx, [rbx+LS_PTR]
        call    mem_realloc
        mov     [rbx+LS_PTR], rax
.ok:    mov     rax, [rbx+LS_COUNT]
        imul    rax, loc(0)
        add     rax, [rbx+LS_PTR]
        inc     qword [rbx+LS_COUNT]
        EPROC

; rcx = List*: frees the storage (not the strings inside)
list_reset:
        push    rbx
        sub     rsp, 32
        mov     rbx, rcx
        mov     rcx, [rbx+LS_PTR]
        call    mem_free
        mov     qword [rbx+LS_PTR], 0
        mov     qword [rbx+LS_COUNT], 0
        mov     qword [rbx+LS_CAP], 0
        add     rsp, 32
        pop     rbx
        ret

; rcx = List* of Track: frees every string, then the storage
PROC tracks_free, 0
        mov     rbx, rcx
        xor     r12d, r12d
.l:     cmp     r12, [rbx+LS_COUNT]
        jae     .done
        mov     rax, r12
        imul    rax, TR_SIZE
        add     rax, [rbx+LS_PTR]
        mov     rsi, rax
        mov     rcx, [rsi+TR_TITLE]
        call    mem_free
        mov     rcx, [rsi+TR_ARTIST]
        call    mem_free
        mov     rcx, [rsi+TR_ALBUM]
        call    mem_free
        mov     rcx, [rsi+TR_URI]
        call    mem_free
        mov     rcx, [rsi+TR_IMG_S]
        call    mem_free
        mov     rcx, [rsi+TR_IMG_L]
        call    mem_free
        inc     r12
        jmp     .l
.done:  mov     rcx, rbx
        call    list_reset
        EPROC

; rcx = List* of Card
PROC cards_free, 0
        mov     rbx, rcx
        xor     r12d, r12d
.l:     cmp     r12, [rbx+LS_COUNT]
        jae     .done
        mov     rax, r12
        imul    rax, CD_SIZE
        add     rax, [rbx+LS_PTR]
        mov     rsi, rax
        mov     rcx, [rsi+CD_NAME]
        call    mem_free
        mov     rcx, [rsi+CD_SUB]
        call    mem_free
        mov     rcx, [rsi+CD_URI]
        call    mem_free
        mov     rcx, [rsi+CD_ID]
        call    mem_free
        mov     rcx, [rsi+CD_IMG_M]
        call    mem_free
        mov     rcx, [rsi+CD_IMG_L]
        call    mem_free
        inc     r12
        jmp     .l
.done:  mov     rcx, rbx
        call    list_reset
        EPROC

; ---------------------------------------------------------------- small JSON conveniences
; rcx = object, rdx = path -> rax = heap UTF-16 string ("" when missing)
PROC jpw, 0
        call    json_path
        mov     rcx, rax
        call    json_str_w
        EPROC

; rcx = object, rdx = path -> rax = heap UTF-8 string ("" when missing)
PROC jpu, 0
        call    json_path
        mov     rcx, rax
        call    json_str_u8
        EPROC

; rcx = object, rdx = path -> rax = integer (0 when missing)
PROC jpi, 0
        call    json_path
        mov     rcx, rax
        call    json_int
        EPROC

; rcx = array of {"name":..} objects -> rax = heap UTF-16 "a, b, c"
PROC join_names, 4
        mov     loc(0), rcx
        mov     qword loc(1), 0                 ; Buf based at &loc(3): ptr=loc(3) len=loc(2) cap=loc(1)
        mov     qword loc(2), 0
        mov     qword loc(3), 0
        mov     rcx, loc(0)
        call    json_count
        mov     r12, rax
        xor     ebx, ebx
.l:     cmp     rbx, r12
        jae     .done
        mov     rcx, loc(0)
        mov     rdx, rbx
        call    json_at
        lea     rdx, [k_name]
        mov     rcx, rax
        call    jpu
        mov     rsi, rax
        test    rbx, rbx
        jz      .nm
        lea     rcx, loc(3)
        lea     rdx, [k_comma]
        call    buf_append_z
.nm:    lea     rcx, loc(3)
        mov     rdx, rsi
        call    buf_append_z
        mov     rcx, rsi
        call    mem_free
        inc     rbx
        jmp     .l
.done:  mov     rcx, loc(3)
        test    rcx, rcx
        jnz     .have
        lea     rcx, [k_empty]
.have:  mov     rdx, -1
        call    u8_to_w
        mov     rsi, rax
        lea     rcx, loc(3)
        call    buf_free
        mov     rax, rsi
        EPROC

; rcx = images array, rdx = &small, r8 = &medium, r9 = &large  (each receives a heap UTF-8 URL or stays 0)
PROC parse_images, 6
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        test    rcx, rcx
        jz      .out
        call    json_count
        mov     loc(4), rax
        test    rax, rax
        jz      .out
        ; large = first
        mov     rcx, loc(0)
        xor     edx, edx
        call    json_at
        mov     rcx, rax
        lea     rdx, [k_url]
        call    jpu
        mov     rcx, loc(3)
        mov     [rcx], rax
        ; medium = second when present, else first
        mov     rdx, 1
        cmp     qword loc(4), 1
        ja      .m
        xor     edx, edx
.m:     mov     rcx, loc(0)
        call    json_at
        mov     rcx, rax
        lea     rdx, [k_url]
        call    jpu
        mov     rcx, loc(2)
        mov     [rcx], rax
        ; small = last
        mov     rcx, loc(0)
        mov     rdx, loc(4)
        dec     rdx
        call    json_at
        mov     rcx, rax
        lea     rdx, [k_url]
        call    jpu
        mov     rcx, loc(1)
        mov     [rcx], rax
.out:   EPROC

; ---------------------------------------------------------------- single records
; rcx = track object, rdx = Track*
PROC parse_track, 3
        mov     loc(0), rcx
        mov     loc(1), rdx
        lea     rdx, [k_name]
        call    jpw
        mov     rdx, loc(1)
        mov     [rdx+TR_TITLE], rax
        mov     rcx, loc(0)
        lea     rdx, [k_uri]
        call    jpu
        mov     rdx, loc(1)
        mov     [rdx+TR_URI], rax
        mov     rcx, loc(0)
        lea     rdx, [k_dur]
        call    jpi
        mov     rdx, loc(1)
        mov     [rdx+TR_DUR], eax
        mov     rcx, loc(0)
        lea     rdx, [k_artists]
        call    json_get
        mov     rcx, rax
        call    join_names
        mov     rdx, loc(1)
        mov     [rdx+TR_ARTIST], rax
        mov     rcx, loc(0)
        lea     rdx, [k_album_name]
        call    jpw
        mov     rdx, loc(1)
        mov     [rdx+TR_ALBUM], rax
        mov     qword loc(2), 0
        mov     rcx, loc(0)
        lea     rdx, [k_album_images]
        call    json_path
        mov     rcx, rax
        mov     rdx, loc(1)
        lea     rdx, [rdx+TR_IMG_S]
        mov     rax, loc(1)
        lea     r9, [rax+TR_IMG_L]
        lea     r8, loc(2)                      ; medium is not stored for tracks
        call    parse_images
        mov     rcx, loc(2)
        call    mem_free
        EPROC

; rcx = object, rdx = Card*, r8d = kind
PROC parse_card, 8
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     [rdx+CD_KIND], r8d
        lea     rdx, [k_name]
        call    jpw
        mov     rdx, loc(1)
        mov     [rdx+CD_NAME], rax
        mov     rcx, loc(0)
        lea     rdx, [k_uri]
        call    jpu
        mov     rdx, loc(1)
        mov     [rdx+CD_URI], rax
        mov     rcx, loc(0)
        lea     rdx, [k_id]
        call    jpu
        mov     rdx, loc(1)
        mov     [rdx+CD_ID], rax
        mov     qword loc(3), 0
        mov     rcx, loc(0)
        lea     rdx, [k_images]
        call    json_get
        mov     rcx, rax
        lea     rdx, loc(3)                     ; small (discarded)
        mov     rax, loc(1)
        lea     r8, [rax+CD_IMG_M]
        lea     r9, [rax+CD_IMG_L]
        call    parse_images
        mov     rcx, loc(3)
        call    mem_free
        ; sub line and count depend on the kind
        mov     eax, dword loc(2)
        cmp     eax, KIND_PLAYLIST
        je      .pl
        cmp     eax, KIND_ALBUM
        je      .al
        ; artist
        lea     rcx, [k_artist_lbl]
        mov     rdx, -1
        call    u8_to_w
        mov     rdx, loc(1)
        mov     [rdx+CD_SUB], rax
        jmp     .done
.pl:    mov     rcx, loc(0)
        lea     rdx, [k_owner_name]
        call    jpu
        mov     loc(3), rax
        mov     qword loc(4), 0                 ; Buf based at &loc(6): ptr=loc(6) len=loc(5) cap=loc(4)
        mov     qword loc(5), 0
        mov     qword loc(6), 0
        lea     rcx, loc(6)
        lea     rdx, [k_by]
        call    buf_append_z
        lea     rcx, loc(6)
        mov     rdx, loc(3)
        call    buf_append_z
        mov     rcx, loc(6)
        mov     rdx, -1
        call    u8_to_w
        mov     rdx, loc(1)
        mov     [rdx+CD_SUB], rax
        lea     rcx, loc(6)
        call    buf_free
        mov     rcx, loc(3)
        call    mem_free
        mov     rcx, loc(0)
        lea     rdx, [k_items_total]
        call    json_path
        test    rax, rax
        jnz     .pc
        mov     rcx, loc(0)
        lea     rdx, [k_tracks_total]
        call    json_path
.pc:    mov     rcx, rax
        call    json_int
        mov     rdx, loc(1)
        mov     [rdx+CD_COUNT], eax
        jmp     .done
.al:    mov     rcx, loc(0)
        lea     rdx, [k_artists]
        call    json_get
        mov     rcx, rax
        call    join_names
        mov     rdx, loc(1)
        mov     [rdx+CD_SUB], rax
        mov     rcx, loc(0)
        lea     rdx, [k_total_tracks]
        call    jpi
        mov     rdx, loc(1)
        mov     [rdx+CD_COUNT], eax
.done:  EPROC

; ---------------------------------------------------------------- pages
; Appends every track found under `path` to the list.  Each element may be wrapped
; ({"item":{..}} in 2026 responses, {"track":{..}} before) - pass wrap = 1 to unwrap.
; rcx = root JSON, rdx = path to the array ("" for the root itself), r8 = List*, r9d = wrap
PROC parse_tracks, 7
        mov     loc(2), r8
        mov     loc(3), r9
        cmp     byte [rdx], 0
        jne     .p
        mov     rax, rcx
        jmp     .have
.p:     call    json_path
.have:  test    rax, rax
        jz      .out
        mov     loc(0), rax
        mov     rcx, rax
        call    json_count
        mov     loc(1), rax
        xor     ebx, ebx
.l:     cmp     rbx, loc(1)
        jae     .out
        mov     rcx, loc(0)
        mov     rdx, rbx
        call    json_at
        mov     rsi, rax
        cmp     dword loc(3), 0
        je      .obj
        mov     rcx, rsi
        lea     rdx, [k_item]
        call    json_get
        test    rax, rax
        jnz     .got
        mov     rcx, rsi
        lea     rdx, [k_track]
        call    json_get
.got:   mov     rsi, rax
.obj:   test    rsi, rsi
        jz      .next
        cmp     byte [rsi], '{'
        jne     .next
        mov     rcx, loc(2)
        mov     edx, TR_SIZE
        call    list_push
        mov     rdx, rax
        mov     rcx, rsi
        call    parse_track
.next:  inc     rbx
        jmp     .l
.out:   EPROC

; rcx = root JSON, rdx = path to the array, r8 = List*, r9d = kind, [rbp+48] = wrapper key (or 0)
PROC parse_cards, 7
        mov     loc(2), r8
        mov     loc(3), r9
        mov     rax, stk5
        mov     loc(4), rax
        call    json_path
        test    rax, rax
        jz      .out
        mov     loc(0), rax
        mov     rcx, rax
        call    json_count
        mov     loc(1), rax
        xor     ebx, ebx
.l:     cmp     rbx, loc(1)
        jae     .out
        mov     rcx, loc(0)
        mov     rdx, rbx
        call    json_at
        mov     rsi, rax
        mov     rdx, loc(4)
        test    rdx, rdx
        jz      .obj
        mov     rcx, rsi
        call    json_get
        mov     rsi, rax
.obj:   test    rsi, rsi
        jz      .next
        cmp     byte [rsi], '{'
        jne     .next
        mov     rcx, loc(2)
        mov     edx, CD_SIZE
        call    list_push
        mov     rdx, rax
        mov     rcx, rsi
        mov     r8d, dword loc(3)
        call    parse_card
.next:  inc     rbx
        jmp     .l
.out:   EPROC
