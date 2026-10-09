; library.asm - the live Spotify library: playlists, saved albums and tracks, recently played, playlist and album
; pages, search results and cover downloads.
;
; Every request is a job on the net queue (net.asm); its handler runs on the UI thread, parses straight into the
; same lists the demo fixtures fill, and repaints.  Responses are matched to what is on screen by a generation
; number carried in the job, so an answer for an old search, a page that was left or a signed-out session is dropped.
;
; Lists are paged: the first page of everything is requested at sign-in, playlists and albums keep following
; "next" up to LIB_AUTO_MAX (the sidebar and grids need them all), liked songs and long playlists load the next
; page when the user scrolls near the end (lib_more / det_more, called from page_end).

%define LIB_PLAYLISTS   0
%define LIB_LIKED       1
%define LIB_ALBUMS      2
%define LIB_RECENT      3
%define LIB_N           4
%define LIB_AUTO_MAX    400

section .bss
lib_next:       resq LIB_N              ; owned UTF-8 URL of the next page of each list, or 0
lib_busy:       resd LIB_N
lib_total:      resd LIB_N
lib_gen:        resd 1
lib_failed:     resd 1                  ; a banner about a failed load was shown already
det_gen:        resd 1
det_next:       resq 1
det_busy:       resd 1
det_total:      resd 1
det_msg:        resq 1                  ; static UTF-16 line shown instead of the track list, or 0
det_img_m:      resq 1                  ; the open album's medium cover (UTF-8, owned)
det_id:         resq 1                  ; the open playlist / album id (UTF-8, owned)
det_flags:      resd 1                  ; its CD_FLAGS (collaborative / mine / public)
search_gen:     resd 1
srch_busy:      resd 1                  ; a search request is in flight
img_rr:         resd 1

section .data
ZSTR lp_playlists, "/v1/me/playlists?limit=50"
ZSTR lp_liked, "/v1/me/tracks?limit=50"
ZSTR lp_albums, "/v1/me/albums?limit=50"
ZSTR lp_recent, "/v1/me/player/recently-played?limit=50"
ZSTR lp_pl_pre, "/v1/playlists/"
ZSTR lp_pl_post, "/items?limit=100"
ZSTR lp_al_pre, "/v1/albums/"
ZSTR lp_al_post, "/tracks?limit=50"
ZSTR lp_ar_pre, "/v1/artists/"
ZSTR lp_ar_post, "/albums?include_groups=album,single&limit=50"
ZSTR lp_search_pre, "/v1/search?q="
ZSTR lp_search_post, "&type=track,album,playlist,artist&limit=10"
ZSTR lp_v1, "/v1/"
ZSTR l_lib_fail, "library: request failed, status "
ZSTR l_det_fail, "detail: request failed, status "
ZSTR l_search_fail, "search: request failed, status "
ZSTR k_nextp, "next"
ZSTR k_totalp, "total"
WSTR w_err_lib, "Some of your library could not be loaded. Details are in Settings > Diagnostics."
WSTR w_det_noaccess, "Spotify only shares the tracks of playlists you own or collaborate on."
WSTR w_det_failed, "These tracks could not be loaded. Check your connection and open the page again."
WSTR w_det_empty, "This one is empty."
WSTR w_lib_loading, "Loading..."
WSTR w_lib_nothing, "Nothing here yet."
align 8
lib_paths:      dq lp_playlists, lp_liked, lp_albums, lp_recent

section .text

; ---------------------------------------------------------------- requests
; rcx = path (UTF-8, starts with "/v1/"), edx = tag, r8 = job argument: GET it on the API worker.
PROC api_get, 0
        lea     r9, [w_get]
        call    api_call
        EPROC

; rcx = path (UTF-8, starts with "/v1/"), edx = tag, r8 = job argument, r9 = method (static UTF-16): a body-less
; request on the API worker
PROC api_call, 0
        mov     qword outarg(5), 0
        call    api_send
        EPROC

; The same with a JSON body: [rbp+48] = body (UTF-8, copied) or 0.   Bufs: URL top 5.   Locals: 6 body
PROC api_send, 8
        mov     loc(0), rdx
        mov     loc(1), r8
        mov     loc(2), r9
        mov     rax, stk5
        mov     loc(6), rax
        mov     rdx, rcx
        BUFZERO 5
        lea     rcx, loc(5)
        call    api_url
        xor     ecx, ecx
        mov     rdx, loc(0)
        mov     r8, loc(1)
        mov     r9, loc(2)
        mov     rax, loc(5)
        mov     outarg(5), rax
        mov     rax, loc(6)
        mov     outarg(6), rax
        xor     eax, eax
        cmp     qword loc(6), 0
        je      .nb
        mov     eax, JF_JSON
.nb:    mov     outarg(7), rax
        mov     qword outarg(8), 0
        call    net_submit
        lea     rcx, loc(5)
        call    buf_free
        EPROC

; rcx = absolute "next" URL from a response (UTF-8, heap: freed here), edx = tag, r8 = job argument.
; The host part is dropped and our own API base used instead, so a test server can answer every page.
PROC api_get_next, 3
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     rsi, rcx
.scan:  mov     al, [rsi]
        test    al, al
        jz      .drop
        cmp     al, '/'
        jne     .adv
        cmp     dword [rsi], '/v1/'
        je      .found
.adv:   inc     rsi
        jmp     .scan
.found: mov     rcx, rsi
        mov     rdx, loc(1)
        mov     r8, loc(2)
        call    api_get
.drop:  mov     rcx, loc(0)
        call    mem_free
        EPROC

; ---------------------------------------------------------------- the library at sign-in
; Forgets everything in flight (late answers will not match the new generations) and frees the "next" pointers.
PROC lib_reset, 2
        call    lk_reset
        mov     qword [queue_due], 0
        inc     dword [lib_gen]
        inc     dword [det_gen]
        inc     dword [search_gen]
        xor     ebx, ebx
.l:     lea     rax, [lib_next]
        mov     rcx, [rax+rbx*8]
        mov     qword [rax+rbx*8], 0
        call    mem_free
        lea     rax, [lib_busy]
        mov     dword [rax+rbx*4], 0
        lea     rax, [lib_total]
        mov     dword [rax+rbx*4], 0
        inc     ebx
        cmp     ebx, LIB_N
        jb      .l
        mov     rcx, [det_next]
        call    mem_free
        mov     qword [det_next], 0
        mov     qword [det_msg], 0
        mov     dword [det_busy], 0
        mov     dword [lib_failed], 0
        EPROC

; Requests the first page of every list.  Called when a sign-in (or a restored session) completes.
PROC lib_load_all, 2
        call    app_free_all
        call    lib_reset
        xor     ebx, ebx
.l:     lea     rax, [lib_busy]
        mov     dword [rax+rbx*4], 1
        lea     rax, [lib_paths]
        mov     rcx, [rax+rbx*8]
        mov     edx, TAG_LIST
        mov     r8d, [lib_gen]
        shl     r8d, 8
        or      r8d, ebx
        call    api_get
        inc     ebx
        cmp     ebx, LIB_N
        jb      .l
        EPROC

; ecx = list -> requests its next page when there is one and nothing is in flight
PROC lib_more, 2
        mov     loc(0), rcx
        lea     rax, [lib_busy]
        cmp     dword [rax+rcx*4], 0
        jne     .out
        lea     rax, [lib_next]
        mov     rdx, [rax+rcx*8]
        test    rdx, rdx
        jz      .out
        mov     qword [rax+rcx*8], 0
        lea     rax, [lib_busy]
        mov     dword [rax+rcx*4], 1
        mov     rcx, rdx
        mov     edx, TAG_LIST
        mov     r8d, [lib_gen]
        shl     r8d, 8
        or      r8d, dword loc(0)
        call    api_get_next
.out:   EPROC

; TAG_LIST: a page of one list.   Locals: 0 job, 1 list, 2 gen, 3 list pointer
PROC h_list, 6
        mov     rsi, rcx
        mov     loc(0), rcx
        mov     rax, [rsi+JB_ARG]
        movzx   ecx, al
        mov     loc(1), rcx
        shr     rax, 8
        mov     loc(2), rax
        mov     eax, dword loc(2)
        cmp     eax, [lib_gen]
        jne     .out                            ; from a previous session
        lea     rax, [lib_busy]
        mov     dword [rax+rcx*4], 0
        mov     eax, [rsi+JB_STATUS]
        cmp     eax, 200
        jne     .failed
        mov     rbx, [rsi+JB_RESP]
        mov     rcx, loc(1)
        cmp     ecx, LIB_PLAYLISTS
        je      .pl
        cmp     ecx, LIB_ALBUMS
        je      .al
        cmp     ecx, LIB_LIKED
        je      .lk
        ; recently played
        mov     rcx, rbx
        lea     rdx, [a_items]
        lea     r8, [lst_recent]
        mov     r9d, 1
        call    parse_tracks
        jmp     .paging
.pl:    mov     rcx, rbx
        lea     rdx, [a_items]
        lea     r8, [lst_playlists]
        mov     r9d, KIND_PLAYLIST
        mov     qword outarg(5), 0
        call    parse_cards
        jmp     .paging
.al:    mov     rcx, rbx
        lea     rdx, [a_items]
        lea     r8, [lst_albums]
        mov     r9d, KIND_ALBUM
        lea     rax, [a_album]
        mov     outarg(5), rax
        call    parse_cards
        jmp     .paging
.lk:    mov     rcx, rbx
        lea     rdx, [a_items]
        lea     r8, [lst_liked]
        mov     r9d, 1
        call    parse_tracks
.paging:
        mov     rcx, loc(1)                     ; what is in the library is saved: no need to ask Spotify about it
        cmp     ecx, LIB_LIKED
        jne     .mk1
        lea     rcx, [lst_liked]
        call    lk_mark_tracks
        jmp     .mk3
.mk1:   cmp     ecx, LIB_ALBUMS
        jne     .mk2
        lea     rcx, [lst_albums]
        call    lk_mark_cards
        jmp     .mk3
.mk2:   cmp     ecx, LIB_PLAYLISTS
        jne     .mk3
        lea     rcx, [lst_playlists]
        call    lk_mark_cards
.mk3:   mov     rsi, loc(0)
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [k_totalp]
        call    jpi
        mov     rcx, loc(1)
        lea     rdx, [lib_total]
        mov     [rdx+rcx*4], eax
        cmp     ecx, LIB_RECENT
        je      .done                           ; recently played pages by cursor: the first 50 are enough
        mov     rsi, loc(0)
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [k_nextp]
        call    jpu
        cmp     byte [rax], 0
        jne     .have
        mov     rcx, rax
        call    mem_free
        jmp     .done
.have:  mov     rcx, loc(1)
        lea     rdx, [lib_next]
        mov     rsi, [rdx+rcx*8]
        mov     [rdx+rcx*8], rax                ; (a stale pointer would be a leak, not a crash)
        mov     rcx, rsi
        call    mem_free
        ; playlists and albums keep going (the sidebar and the grids need all of them), up to a limit
        mov     rcx, loc(1)
        cmp     ecx, LIB_LIKED
        je      .done
        mov     rax, [lst_playlists+LS_COUNT]
        cmp     ecx, LIB_PLAYLISTS
        je      .cap
        mov     rax, [lst_albums+LS_COUNT]
.cap:   cmp     rax, LIB_AUTO_MAX
        jae     .done
        call    lib_more
        jmp     .done
.failed:
        lea     rcx, [l_lib_fail]
        mov     edx, eax
        call    log_num
        cmp     dword [lib_failed], 0
        jne     .done
        mov     dword [lib_failed], 1
        lea     rcx, [w_err_lib]
        xor     edx, edx
        xor     r8d, r8d
        call    ui_banner
.done:  mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
.out:   EPROC

; ---------------------------------------------------------------- playlist and album pages
; The page being opened is already described by the det_* globals (set by app_open_detail).
PROC real_load_detail, 2
        inc     dword [det_gen]
        mov     rcx, [det_next]
        call    mem_free
        mov     qword [det_next], 0
        mov     qword [det_msg], 0
        mov     dword [det_total], 0
        mov     dword [det_busy], 0
        call    det_request
        EPROC

; Reloads the open playlist / album from the start (after its tracks changed)
PROC det_reload, 0
        cmp     dword [page], PAGE_DETAIL
        jne     .out
        lea     rcx, [lst_detail]
        call    tracks_free
        lea     rcx, [lst_dalbums]
        call    cards_free
        call    real_load_detail
.out:   EPROC

; Requests the first page of the tracks of the page in det_id / det_kind.   Bufs: URL top 3
PROC det_request, 4
        mov     eax, [det_kind]
        cmp     eax, KIND_PLAYLIST
        je      .go
        cmp     eax, KIND_ALBUM
        je      .go
        cmp     eax, KIND_ARTIST
        jne     .out
.go:    mov     rcx, [det_id]
        test    rcx, rcx
        jz      .out
        cmp     byte [rcx], 0
        je      .out
        BUFZERO 3
        lea     rcx, loc(3)
        lea     rdx, [lp_pl_pre]
        cmp     dword [det_kind], KIND_ALBUM
        jne     .pre1
        lea     rdx, [lp_al_pre]
.pre1:  cmp     dword [det_kind], KIND_ARTIST
        jne     .pre
        lea     rdx, [lp_ar_pre]
.pre:   call    buf_append_z
        lea     rcx, loc(3)
        mov     rdx, [det_id]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [lp_pl_post]
        cmp     dword [det_kind], KIND_ALBUM
        jne     .post1
        lea     rdx, [lp_al_post]
.post1: cmp     dword [det_kind], KIND_ARTIST
        jne     .post
        lea     rdx, [lp_ar_post]
.post:  call    buf_append_z
        mov     dword [det_busy], 1
        mov     rcx, loc(3)
        mov     edx, TAG_DETAIL
        mov     r8d, [det_gen]
        call    api_get
        lea     rcx, loc(3)
        call    buf_free
.out:   EPROC

; Requests the next page of the open playlist / album when there is one
PROC det_more, 2
        cmp     dword [det_busy], 0
        jne     .out
        mov     rcx, [det_next]
        test    rcx, rcx
        jz      .out
        mov     qword [det_next], 0
        mov     dword [det_busy], 1
        mov     edx, TAG_DETAIL
        mov     r8d, [det_gen]
        call    api_get_next
.out:   EPROC

; TAG_DETAIL
PROC h_detail, 4
        mov     rsi, rcx
        mov     loc(0), rcx
        mov     rax, [rsi+JB_ARG]
        cmp     eax, [det_gen]
        jne     .out
        mov     dword [det_busy], 0
        mov     eax, [rsi+JB_STATUS]
        cmp     eax, 200
        je      .ok
        lea     rcx, [l_det_fail]
        mov     edx, eax
        call    log_num
        mov     rsi, loc(0)
        mov     eax, [rsi+JB_STATUS]
        lea     rcx, [w_det_failed]
        cmp     eax, 403
        je      .noacc
        cmp     eax, 404
        jne     .setmsg
.noacc: lea     rcx, [w_det_noaccess]
.setmsg:
        mov     [det_msg], rcx
        jmp     .paint
.ok:    cmp     dword [det_kind], KIND_ARTIST
        jne     .tracks
        mov     rcx, [rsi+JB_RESP]              ; an artist page lists albums, not tracks
        lea     rdx, [a_items]
        lea     r8, [lst_dalbums]
        mov     r9d, KIND_ALBUM
        mov     qword outarg(5), 0
        call    parse_cards
        jmp     .paging
.tracks: mov    rsi, loc(0)
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [a_items]
        lea     r8, [lst_detail]
        mov     r9d, 1
        cmp     dword [det_kind], KIND_ALBUM
        jne     .parse
        xor     r9d, r9d                        ; album tracks are bare track objects
.parse: call    parse_tracks
        cmp     dword [det_kind], KIND_ALBUM
        jne     .paging
        call    detail_fill_from_det
.paging:
        mov     rsi, loc(0)
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [k_totalp]
        call    jpi
        mov     [det_total], eax
        mov     rsi, loc(0)
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [k_nextp]
        call    jpu
        mov     loc(1), rax
        mov     rcx, [det_next]
        call    mem_free
        mov     qword [det_next], 0
        mov     rax, loc(1)
        cmp     byte [rax], 0
        jne     .keep
        mov     rcx, rax
        call    mem_free
        jmp     .empty
.keep:  mov     [det_next], rax
.empty: cmp     dword [det_kind], KIND_ARTIST
        je      .paint
        cmp     qword [lst_detail+LS_COUNT], 0
        jne     .paint
        lea     rcx, [w_det_empty]
        cmp     dword [det_total], 0
        je      .setmsg
        lea     rcx, [w_det_noaccess]           ; the page says it has tracks but sent none
        jmp     .setmsg
.paint: mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
.out:   EPROC

; Album tracks come without album details: borrow the open page's name and covers.
PROC detail_fill_from_det, 2
        xor     r12d, r12d
.l:     cmp     r12, [lst_detail+LS_COUNT]
        jae     .out
        mov     rax, r12
        imul    rax, TR_SIZE
        add     rax, [lst_detail+LS_PTR]
        mov     rsi, rax
        cmp     qword [rsi+TR_ALBUM], 0
        je      .fill
        mov     rax, [rsi+TR_ALBUM]
        cmp     word [rax], 0
        jne     .next                           ; already filled by an earlier page
.fill:  mov     rcx, [det_title]
        call    w_dup
        mov     rcx, [rsi+TR_ALBUM]
        mov     loc(0), rax
        call    mem_free
        mov     rax, loc(0)
        mov     [rsi+TR_ALBUM], rax
        mov     rcx, [det_img_m]
        call    u8_dup0
        mov     rcx, [rsi+TR_IMG_S]
        mov     loc(0), rax
        call    mem_free
        mov     rax, loc(0)
        mov     [rsi+TR_IMG_S], rax
        mov     rcx, [det_img]
        call    u8_dup0
        mov     rcx, [rsi+TR_IMG_L]
        mov     loc(0), rax
        call    mem_free
        mov     rax, loc(0)
        mov     [rsi+TR_IMG_L], rax
.next:  inc     r12
        jmp     .l
.out:   EPROC

; ---------------------------------------------------------------- search
; rcx = search text (UTF-16).  Newer queries supersede older ones: only the answer to the latest is shown.
PROC real_search, 8
        mov     loc(0), rcx
        inc     dword [search_gen]
        call    app_free_search
        mov     dword [srch_busy], 0
        mov     rcx, loc(0)
        cmp     word [rcx], 0
        je      .paint
        mov     rdx, -1
        call    w_to_u8
        mov     loc(1), rax
        mov     loc(2), rdx
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [lp_search_pre]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     rdx, loc(1)
        mov     r8, loc(2)
        call    buf_append_urlenc
        lea     rcx, loc(5)
        lea     rdx, [lp_search_post]
        call    buf_append_z
        mov     rcx, loc(1)
        call    mem_free
        mov     dword [srch_busy], 1
        mov     rcx, loc(5)
        mov     edx, TAG_SEARCH
        mov     r8d, [search_gen]
        call    api_get
        lea     rcx, loc(5)
        call    buf_free
        jmp     .paint
.empty: mov     dword [srch_busy], 0
.paint: mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        EPROC

; TAG_SEARCH
PROC h_search, 4
        mov     rsi, rcx
        mov     loc(0), rcx
        mov     rax, [rsi+JB_ARG]
        cmp     eax, [search_gen]
        jne     .out
        mov     dword [srch_busy], 0
        mov     eax, [rsi+JB_STATUS]
        cmp     eax, 200
        je      .ok
        lea     rcx, [l_search_fail]
        mov     edx, eax
        call    log_num
        jmp     .paint
.ok:    mov     rcx, [rsi+JB_RESP]
        lea     rdx, [a_tracks_items]
        lea     r8, [lst_search_t]
        xor     r9d, r9d
        call    parse_tracks
        mov     rsi, loc(0)
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [a_albums_items]
        lea     r8, [lst_search_a]
        mov     r9d, KIND_ALBUM
        mov     qword outarg(5), 0
        call    parse_cards
        mov     rsi, loc(0)
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [a_playlists_items]
        lea     r8, [lst_search_p]
        mov     r9d, KIND_PLAYLIST
        mov     qword outarg(5), 0
        call    parse_cards
        mov     rsi, loc(0)
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [a_artists_items]
        lea     r8, [lst_search_r]
        mov     r9d, KIND_ARTIST
        mov     qword outarg(5), 0
        call    parse_cards
.paint: mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
.out:   EPROC

; ---------------------------------------------------------------- cover art
; rcx = image URL (UTF-8; copied).  Three workers share the downloads.
PROC fetch_image_async, 2
        mov     loc(0), rcx
        mov     eax, [img_rr]
        inc     dword [img_rr]
        xor     edx, edx
        mov     ecx, NQ_COUNT-1
        div     ecx
        lea     ecx, [rdx+1]                    ; queue 1..3
        mov     edx, TAG_IMG
        xor     r8d, r8d
        lea     r9, [w_get]
        mov     rax, loc(0)
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        mov     qword outarg(7), JF_NOAUTH
        mov     qword outarg(8), 0
        call    net_submit
        EPROC

; TAG_IMG: the cover finished downloading (or failed)
PROC h_img, 2
        mov     rsi, rcx
        xor     edx, edx
        xor     r8d, r8d
        xor     r9d, r9d
        cmp     dword [rsi+JB_STATUS], 200
        jne     .set
        mov     rdx, [rsi+JB_RESP+BUF_PTR]      ; the response Buf is embedded in the job
        mov     r8, [rsi+JB_RESP+BUF_LEN]
        mov     r9, [rsi+JB_PIX]                ; already decoded by the worker, when our decoders could read it
.set:   mov     rcx, [rsi+JB_URL]
        call    img_set_data
        mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        EPROC

; ---------------------------------------------------------------- UI helpers
; Called from page_end: loads the next page of whatever list the current page shows when the user is near its end
; (or when the page is shorter than the window, so the first screen fills up).
PROC lib_scroll_check, 2
        cmp     dword [g_demo], 0
        jne     .out
        S       700
        mov     ecx, eax
        mov     eax, [content_h]
        sub     eax, [scroll_main]
        sub     eax, [view_h]                   ; pixels left below the viewport
        cmp     eax, ecx
        jg      .out
        mov     eax, [page]
        cmp     eax, PAGE_DETAIL
        je      .detail
        cmp     eax, PAGE_LIBRARY
        jne     .out
        cmp     dword [lib_tab], 1
        jne     .out
        mov     ecx, LIB_LIKED
        call    lib_more
        jmp     .out
.detail:
        call    det_more
.out:   EPROC
