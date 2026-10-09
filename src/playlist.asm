; playlist.asm - creating, editing and deleting playlists, adding and removing tracks.
;
;   create   POST   /v1/me/playlists                {"name","description","public"}
;   edit     PUT    /v1/playlists/{id}              {"name",["description"],"public"}
;   delete   DELETE /v1/me/library?uris=spotify:playlist:{id}      (deleting a playlist is unfollowing it)
;   add      POST   /v1/playlists/{id}/items        {"uris":[uri]}
;   remove   DELETE /v1/playlists/{id}/items        {"items":[{"uri":uri}]}
;
; Each request carries a small heap block [generation][kind][playlist id] as its job argument; the handler
; (h_plmod) refreshes whatever the change affected.

%define PK_CREATE   1
%define PK_UPDATE   2
%define PK_DELETE   3
%define PK_ADD      4
%define PK_REMOVE   5

section .data
ZSTR pl_path_me, "/v1/me/playlists"
ZSTR pl_path_pl, "/v1/playlists/"
ZSTR pl_path_items, "/items"
ZSTR pl_path_lib, "/v1/me/library?uris=spotify%3Aplaylist%3A"
ZSTR pb_name, `{"name":`
ZSTR pb_desc, `,"description":`
ZSTR pb_public, `,"public":`
ZSTR pb_uris, `{"uris":[`
ZSTR pb_items, `{"items":[{"uri":`
ZSTR pb_end_obj, `}`
ZSTR pb_end_uris, `]}`
ZSTR pb_end_items, `}]}`
ZSTR pl_hex, "0123456789abcdef"
ZSTR l_pl_fail, "playlist: request failed, kind/status "
WSTR w_pl_created, "Playlist created"
WSTR w_pl_updated, "Playlist updated"
WSTR w_pl_deleted, "Playlist removed"
WSTR w_pl_added, "Added to playlist"
WSTR w_pl_removed, "Removed from playlist"
WSTR w_pl_forbidden, "Spotify only lets you change playlists you own or collaborate on."
WSTR w_pl_failed, "Spotify could not change that playlist. Check your connection and try again."
section .text

; rcx = Buf*, rdx = UTF-8 text: appends it as a JSON string literal (quotes, backslashes and control characters escaped)
PROC buf_append_jstr, 4
        mov     loc(0), rcx
        mov     loc(1), rdx
        lea     rdx, [b_quote]
        call    buf_append_z
        mov     rsi, loc(1)
.l:     movzx   eax, byte [rsi]
        test    eax, eax
        jz      .end
        mov     qword loc(2), 0
        cmp     al, '"'
        je      .esc
        cmp     al, 92
        je      .esc
        cmp     al, 0x20
        jb      .ctl
        mov     byte loc(2), al
        jmp     .put
.esc:   mov     byte loc(2), 92
        mov     byte [rbp-72-16+1], al
        jmp     .put
.ctl:   mov     byte loc(2), 92
        mov     byte [rbp-72-16+1], 'u'
        mov     word [rbp-72-16+2], 0x3030      ; "00"
        mov     ecx, eax
        shr     ecx, 4
        lea     rdx, [pl_hex]
        mov     cl, [rdx+rcx]
        mov     byte [rbp-72-16+4], cl
        and     eax, 15
        mov     al, [rdx+rax]
        mov     byte [rbp-72-16+5], al
.put:   mov     rcx, loc(0)
        lea     rdx, loc(2)
        call    buf_append_z
        inc     rsi
        jmp     .l
.end:   mov     rcx, loc(0)
        lea     rdx, [b_quote]
        call    buf_append_z
        EPROC

; ecx = kind, rdx = playlist id (UTF-8) or 0 -> rax = heap block [lib_gen][kind][id...]
PROC pl_arg, 3
        mov     loc(0), rcx
        mov     loc(1), rdx
        xor     eax, eax
        test    rdx, rdx
        jz      .alloc
        mov     rcx, rdx
        call    u8_len
.alloc: lea     rcx, [rax+16]
        call    mem_alloc
        mov     loc(2), rax
        mov     ecx, [lib_gen]
        mov     [rax], ecx
        mov     ecx, dword loc(0)
        mov     [rax+4], ecx
        mov     rdx, loc(1)
        test    rdx, rdx
        jz      .out
        lea     rcx, [rax+8]
        call    u8_copy_z
        mov     rax, loc(2)
.out:   EPROC

; rcx = dst, rdx = src (UTF-8 z-string): copies it with its NUL
u8_copy_z:
.l:     mov     al, [rdx]
        mov     [rcx], al
        inc     rcx
        inc     rdx
        test    al, al
        jnz     .l
        ret

; ---------------------------------------------------------------- requests
; rcx = name (UTF-8), rdx = description (UTF-8), r8d = public.   Bufs: body top 8
PROC pl_create, 10
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        BUFZERO 8
        lea     rcx, loc(8)
        lea     rdx, [pb_name]
        call    buf_append_z
        lea     rcx, loc(8)
        mov     rdx, loc(0)
        call    buf_append_jstr
        lea     rcx, loc(8)
        lea     rdx, [pb_desc]
        call    buf_append_z
        lea     rcx, loc(8)
        mov     rdx, loc(1)
        call    buf_append_jstr
        lea     rcx, loc(8)
        lea     rdx, [pb_public]
        call    buf_append_z
        lea     rcx, loc(8)
        lea     rdx, [b_false]
        cmp     dword loc(2), 0
        je      .pub
        lea     rdx, [b_true]
.pub:   call    buf_append_z
        lea     rcx, loc(8)
        lea     rdx, [pb_end_obj]
        call    buf_append_z
        mov     ecx, PK_CREATE
        xor     edx, edx
        call    pl_arg
        mov     r8, rax
        lea     rcx, [pl_path_me]
        mov     edx, TAG_PLMOD
        lea     r9, [w_post]
        mov     rax, loc(8)
        mov     outarg(5), rax
        call    api_send
        lea     rcx, loc(8)
        call    buf_free
        EPROC

; rcx = id, rdx = name, r8 = description (empty = leave as is), r9d = public.   Bufs: URL top 5, body top 8
PROC pl_update, 12
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        BUFZERO 8
        lea     rcx, loc(8)
        lea     rdx, [pb_name]
        call    buf_append_z
        lea     rcx, loc(8)
        mov     rdx, loc(1)
        call    buf_append_jstr
        mov     rax, loc(2)
        cmp     byte [rax], 0
        je      .nodesc
        lea     rcx, loc(8)
        lea     rdx, [pb_desc]
        call    buf_append_z
        lea     rcx, loc(8)
        mov     rdx, loc(2)
        call    buf_append_jstr
.nodesc:
        lea     rcx, loc(8)
        lea     rdx, [pb_public]
        call    buf_append_z
        lea     rcx, loc(8)
        lea     rdx, [b_false]
        cmp     dword loc(3), 0
        je      .pub
        lea     rdx, [b_true]
.pub:   call    buf_append_z
        lea     rcx, loc(8)
        lea     rdx, [pb_end_obj]
        call    buf_append_z
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [pl_path_pl]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     rdx, loc(0)
        call    buf_append_z
        mov     ecx, PK_UPDATE
        mov     rdx, loc(0)
        call    pl_arg
        mov     r8, rax
        mov     rcx, loc(5)
        mov     edx, TAG_PLMOD
        lea     r9, [w_put]
        mov     rax, loc(8)
        mov     outarg(5), rax
        call    api_send
        lea     rcx, loc(5)
        call    buf_free
        lea     rcx, loc(8)
        call    buf_free
        EPROC

; rcx = id: deletes the playlist from the user's library.   Bufs: URL top 5
PROC pl_delete, 8
        mov     loc(0), rcx
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [pl_path_lib]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     rdx, loc(0)
        call    buf_append_z
        mov     ecx, PK_DELETE
        mov     rdx, loc(0)
        call    pl_arg
        mov     r8, rax
        mov     rcx, loc(5)
        mov     edx, TAG_PLMOD
        lea     r9, [w_delete]
        call    api_call
        lea     rcx, loc(5)
        call    buf_free
        EPROC

; rcx = playlist id, rdx = track URI, r8d = PK_ADD or PK_REMOVE.   Bufs: URL top 5, body top 8
PROC pl_tracks, 12
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        BUFZERO 8
        lea     rcx, loc(8)
        lea     rdx, [pb_uris]
        cmp     dword loc(2), PK_ADD
        je      .b
        lea     rdx, [pb_items]
.b:     call    buf_append_z
        lea     rcx, loc(8)
        mov     rdx, loc(1)
        call    buf_append_jstr
        lea     rcx, loc(8)
        lea     rdx, [pb_end_uris]
        cmp     dword loc(2), PK_ADD
        je      .e
        lea     rdx, [pb_end_items]
.e:     call    buf_append_z
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [pl_path_pl]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     rdx, loc(0)
        call    buf_append_z
        lea     rcx, loc(5)
        lea     rdx, [pl_path_items]
        call    buf_append_z
        mov     ecx, dword loc(2)
        mov     rdx, loc(0)
        call    pl_arg
        mov     r8, rax
        mov     rcx, loc(5)
        mov     edx, TAG_PLMOD
        lea     r9, [w_post]
        cmp     dword loc(2), PK_ADD
        je      .m
        lea     r9, [w_delete]
.m:     mov     rax, loc(8)
        mov     outarg(5), rax
        call    api_send
        lea     rcx, loc(5)
        call    buf_free
        lea     rcx, loc(8)
        call    buf_free
        EPROC

; Fetches the first page of the playlists again (after one was created, renamed or deleted)
PROC lib_reload_playlists, 2
        lea     rcx, [lst_playlists]
        call    cards_free
        mov     dword [detail_sel], -1
        mov     rcx, [lib_next+LIB_PLAYLISTS*8]
        call    mem_free
        mov     qword [lib_next+LIB_PLAYLISTS*8], 0
        mov     dword [lib_busy+LIB_PLAYLISTS*4], 1
        lea     rcx, [lp_playlists]
        mov     edx, TAG_LIST
        mov     r8d, [lib_gen]
        shl     r8d, 8
        or      r8d, LIB_PLAYLISTS
        call    api_get
        EPROC

; TAG_PLMOD: Spotify answered a playlist change.   Locals: 0 job, 1 block, 2 kind
PROC h_plmod, 4
        mov     rsi, rcx
        mov     loc(0), rcx
        mov     rax, [rsi+JB_ARG]
        mov     loc(1), rax
        mov     ecx, [rax]
        cmp     ecx, [lib_gen]
        jne     .free
        mov     ecx, [rax+4]
        mov     loc(2), rcx
        mov     eax, [rsi+JB_STATUS]
        cmp     eax, 200
        je      .ok
        cmp     eax, 201
        je      .ok
        cmp     eax, 204
        je      .ok
        mov     edx, eax
        lea     rcx, [l_pl_fail]
        imul    ecx, dword loc(2), 1000
        add     edx, ecx
        lea     rcx, [l_pl_fail]
        call    log_num
        mov     rsi, loc(0)
        lea     rcx, [w_pl_failed]
        cmp     dword [rsi+JB_STATUS], 403
        jne     .toast
        lea     rcx, [w_pl_forbidden]
.toast: call    ui_toast
        jmp     .free
.ok:    mov     eax, dword loc(2)
        cmp     eax, PK_CREATE
        je      .create
        cmp     eax, PK_UPDATE
        je      .update
        cmp     eax, PK_DELETE
        je      .delete
        cmp     eax, PK_ADD
        je      .add
        ; removed a track
        lea     rcx, [w_pl_removed]
        call    ui_toast
        call    pl_if_open_reload
        jmp     .paint
.create: lea    rcx, [w_pl_created]
        call    ui_toast
        call    lib_reload_playlists
        jmp     .paint
.update: lea    rcx, [w_pl_updated]
        call    ui_toast
        call    lib_reload_playlists
        jmp     .paint
.delete: lea    rcx, [w_pl_deleted]
        call    ui_toast
        call    lib_reload_playlists
        mov     rcx, loc(1)
        add     rcx, 8
        call    pl_is_open
        test    eax, eax
        jz      .paint
        mov     dword [page], PAGE_LIBRARY      ; the page that was open no longer exists
        mov     dword [detail_sel], -1
        jmp     .paint
.add:   lea     rcx, [w_pl_added]
        call    ui_toast
        call    pl_if_open_reload
.paint: mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
.free:  mov     rcx, loc(1)
        call    mem_free
        EPROC

; rcx = playlist id -> eax = 1 when that playlist's page is the one on screen
pl_is_open:
        mov     rdx, [det_id]
        test    rdx, rdx
        jz      .no
        cmp     dword [page], PAGE_DETAIL
        jne     .no
        cmp     dword [det_kind], KIND_PLAYLIST
        jne     .no
        sub     rsp, 40
        call    u8_eq
        add     rsp, 40
        ret
.no:    xor     eax, eax
        ret

; (uses the block of the current h_plmod frame) reloads the open page when the change was made to it
pl_if_open_reload:
        push    rbx
        sub     rsp, 32
        mov     rbx, [rbp-72-8*1]               ; h_plmod's loc(1): the block
        lea     rcx, [rbx+8]
        call    pl_is_open
        test    eax, eax
        jz      .r
        call    det_reload
.r:     add     rsp, 32
        pop     rbx
        ret
