; menu.asm - the right-click menu and the "Up next" queue operations behind it.
;
; Spotify's API can append to the queue and read it, but cannot remove, reorder or insert.  So ByteStream edits its
; own copy of the queue (q_up) and, for anything but an append, makes Spotify's queue match it by re-issuing
; "play" with [current track, queue...] (queue_replay): the current song carries on from the same position, but
; playback leaves its album / playlist context.  The menu labels say what they do.

%define MENU_MAX    8
%define MI_SIZE     16                  ; label* (0), action (8), pad
%define H_MENU_ITEM 38                  ; arg = item index
%define H_MENU_BG   39                  ; swallows the click that dismisses the menu

%define MA_PLAY     1
%define MA_QADD     2
%define MA_PLAYNEXT 3
%define MA_LIKE     4
%define MA_COPY     5
%define MA_OPEN     6
%define MA_QREMOVE  7
%define MA_QUP      8
%define MA_QDOWN    9
%define MA_QCLEAR   10
%define MA_QPLAY    11
%define MA_CARDOPEN 12

section .bss
menu_open:      resd 1
menu_x:         resd 1
menu_y:         resd 1
menu_n:         resd 1
menu_arg:       resd 1                  ; the hit argument of the item the menu was opened on
menu_items:     resb MENU_MAX*MI_SIZE
menu_uri:       resq 1                  ; owned UTF-8 URI of the target
queue_due:      resq 1                  ; GetTickCount64 at which the queue should be re-read (0 = never)
queue_busy:     resd 1

section .data
WSTR mw_play, "Play"
WSTR mw_qadd, "Add to queue"
WSTR mw_next, "Play next"
WSTR mw_save, "Save to Liked Songs"
WSTR mw_unsave, "Remove from Liked Songs"
WSTR mw_save_lib, "Save to your library"
WSTR mw_unsave_lib, "Remove from your library"
WSTR mw_copy, "Copy link"
WSTR mw_open, "Open in Spotify"
WSTR mw_qremove, "Remove from queue"
WSTR mw_qup, "Move up"
WSTR mw_qdown, "Move down"
WSTR mw_qclear, "Clear queue"
WSTR mw_cardopen, "Open"
WSTR w_link_done, "Link copied"
WSTR w_queued, "Added to queue"
WSTR w_err_queue, "Spotify could not add that to the queue. Start a song first, then try again."
ZSTR s_spotify_pre, "spotify:"
ZSTR s_web_pre, "https://open.spotify.com/"
ZSTR p_queue, "/v1/me/player/queue?uri="
ZSTR p_queue_get, "/v1/me/player/queue"
ZSTR a_queue_key, "queue"
ZSTR b_pos_pre, `],"position_ms":`
ZSTR l_queue_fail, "queue: request failed, status "
section .text

; ---------------------------------------------------------------- the list "q_up": edits shared by demo and live mode
; ecx = i: swaps q_up[i] and q_up[i+1]
q_swap:
        mov     rax, [q_up+LS_COUNT]
        lea     rdx, [rcx+1]
        cmp     rdx, rax
        jae     .r
        imul    rcx, TR_SIZE
        add     rcx, [q_up+LS_PTR]
        mov     r8d, TR_SIZE/8
.l:     mov     rax, [rcx]
        mov     rdx, [rcx+TR_SIZE]
        mov     [rcx], rdx
        mov     [rcx+TR_SIZE], rax
        add     rcx, 8
        dec     r8d
        jnz     .l
.r:     ret

; ecx = i: removes q_up[i], freeing its strings
PROC q_remove, 2
        mov     loc(0), rcx
        cmp     rcx, [q_up+LS_COUNT]
        jae     .out
        imul    rax, rcx, TR_SIZE
        add     rax, [q_up+LS_PTR]
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
        mov     rcx, rsi
        lea     rdx, [rsi+TR_SIZE]
        mov     r8, [q_up+LS_COUNT]
        dec     r8
        mov     [q_up+LS_COUNT], r8
        sub     r8, loc(0)
        imul    r8, TR_SIZE
        call    mem_copy
.out:   EPROC

; ecx = index (0..count), rdx = Track* to copy (deep) into q_up at that index
PROC q_insert, 3
        mov     loc(0), rcx
        mov     loc(1), rdx
        lea     rcx, [q_up]
        mov     edx, TR_SIZE
        call    list_push
        mov     rdx, rax
        mov     rcx, loc(1)
        call    track_copy
        mov     rbx, [q_up+LS_COUNT]
        dec     rbx                             ; the new element's index
.bubble: cmp    rbx, loc(0)
        jbe     .out
        lea     rcx, [rbx-1]
        call    q_swap
        dec     rbx
        jmp     .bubble
.out:   EPROC

; ---------------------------------------------------------------- keeping Spotify's queue in step
; Re-issues "play" so that Spotify's queue is [current track, q_up...] (at most 100), resuming where we are.
; Does nothing unless a song is playing through our own player.   Bufs: body top 8
PROC queue_replay, 12
        cmp     dword [g_demo], 0
        jne     .out
        cmp     dword [np_valid], 0
        je      .out
        cmp     dword [sdk_ready], 0
        je      .out
        BUFZERO 8
        lea     rcx, loc(8)
        lea     rdx, [b_uris_pre]
        call    buf_append_z
        lea     rcx, loc(8)
        mov     rdx, [np_uri]
        xor     r8d, r8d
        call    body_add_uri
        mov     loc(0), rax
        xor     ebx, ebx
.l:     cmp     rbx, [q_up+LS_COUNT]
        jae     .done
        cmp     dword loc(0), 100
        jae     .done
        imul    rax, rbx, TR_SIZE
        add     rax, [q_up+LS_PTR]
        mov     rdx, [rax+TR_URI]
        lea     rcx, loc(8)
        mov     r8d, dword loc(0)
        call    body_add_uri
        add     dword loc(0), eax
        inc     rbx
        jmp     .l
.done:  lea     rcx, loc(8)
        lea     rdx, [b_pos_pre]
        call    buf_append_z
        call    np_position
        mov     edx, eax
        lea     rcx, loc(8)
        call    buf_append_u64
        lea     rcx, loc(8)
        lea     rdx, [c_close]
        call    buf_append_z
        mov     rcx, loc(8)
        mov     qword loc(8), 0
        call    audio_do_play                   ; (frees the body)
        mov     ecx, 1500
        call    queue_mark
.out:   EPROC

; ecx = milliseconds from now: the queue will be read back from Spotify then
queue_mark:
        push    rbx
        sub     rsp, 32
        mov     ebx, ecx
        call    GetTickCount64
        add     rax, rbx
        mov     [queue_due], rax
        add     rsp, 32
        pop     rbx
        ret

; UI timer: reads the queue once its due time has come
PROC queue_tick, 2
        mov     rax, [queue_due]
        test    rax, rax
        jz      .out
        cmp     dword [g_demo], 0
        jne     .clr
        cmp     dword [signed_in], 0
        je      .clr
        cmp     dword [queue_busy], 0
        jne     .out
        call    GetTickCount64
        cmp     rax, [queue_due]
        jb      .out
        mov     qword [queue_due], 0
        mov     dword [queue_busy], 1
        lea     rcx, [p_queue_get]
        mov     edx, TAG_QUEUE
        mov     r8d, [lib_gen]
        call    api_get
        jmp     .out
.clr:   mov     qword [queue_due], 0
.out:   EPROC

; TAG_QUEUE: {"currently_playing":..,"queue":[tracks]}
PROC h_queue, 2
        mov     rsi, rcx
        mov     loc(0), rcx
        mov     dword [queue_busy], 0
        mov     rax, [rsi+JB_ARG]
        cmp     eax, [lib_gen]
        jne     .out
        mov     eax, [rsi+JB_STATUS]
        cmp     eax, 200
        je      .ok
        lea     rcx, [l_queue_fail]
        mov     edx, eax
        call    log_num
        jmp     .out
.ok:    lea     rcx, [q_up]
        call    tracks_free
        mov     rsi, loc(0)
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [a_queue_key]
        lea     r8, [q_up]
        xor     r9d, r9d
        call    parse_tracks
        mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
.out:   EPROC

; rcx = Track*: appends a copy to the queue now; in live mode Spotify is told too (POST /me/player/queue)
PROC queue_add, 4
        mov     loc(0), rcx
        mov     rcx, [q_up+LS_COUNT]
        mov     rdx, loc(0)
        call    q_insert
        cmp     dword [g_demo], 0
        jne     .out
        cmp     dword [sdk_ready], 0
        je      .out
        mov     rcx, loc(0)
        mov     rcx, [rcx+TR_URI]
        test    rcx, rcx
        jz      .out
        mov     loc(1), rcx
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [p_queue]
        call    buf_append_z
        mov     rcx, loc(1)
        call    u8_len
        mov     r8, rax
        lea     rcx, loc(5)
        mov     rdx, loc(1)
        call    buf_append_urlenc
        lea     rcx, loc(5)
        lea     rdx, [p_devarg]
        call    buf_append_z
        lea     rcx, loc(5)
        lea     rdx, [sdk_device]
        call    buf_append_z
        mov     rcx, loc(5)
        mov     edx, TAG_QADD
        mov     r8d, [lib_gen]
        lea     r9, [w_post]
        call    api_call
        lea     rcx, loc(5)
        call    buf_free
.out:   EPROC

; TAG_QADD: Spotify answered the POST
PROC h_qadd, 2
        mov     rsi, rcx
        mov     rax, [rsi+JB_ARG]
        cmp     eax, [lib_gen]
        jne     .out
        mov     eax, [rsi+JB_STATUS]
        cmp     eax, 200
        je      .ok
        cmp     eax, 204
        je      .ok
        lea     rcx, [w_err_queue]
        call    ui_toast
        mov     ecx, 300                        ; our optimistic copy was wrong: read the real queue back
        call    queue_mark
        jmp     .out
.ok:    lea     rcx, [w_queued]
        call    ui_toast
        mov     ecx, 800
        call    queue_mark
.out:   EPROC

; rcx = Track*: the track goes to the front of the queue (live mode: Spotify's queue is rebuilt to match)
PROC queue_play_next, 2
        mov     rdx, rcx
        xor     ecx, ecx
        call    q_insert
        call    queue_replay
        EPROC

; ---------------------------------------------------------------- the menu
; Closes the menu and forgets its target
PROC menu_close, 0
        mov     dword [menu_open], 0
        mov     rcx, [menu_uri]
        call    mem_free
        mov     qword [menu_uri], 0
        mov     dword [menu_n], 0
        EPROC

; rcx = label (static UTF-16), edx = action
menu_add:
        mov     eax, [menu_n]
        cmp     eax, MENU_MAX
        jae     .r
        imul    rax, rax, MI_SIZE
        lea     r8, [menu_items]
        add     rax, r8
        mov     [rax], rcx
        mov     [rax+8], edx
        inc     dword [menu_n]
.r:     ret

; rcx = URI (UTF-8) -> the menu's target (copied)
PROC menu_set_uri, 1
        mov     loc(0), rcx
        mov     rcx, [menu_uri]
        call    mem_free
        mov     rcx, loc(0)
        call    u8_dup0
        mov     [menu_uri], rax
        EPROC

; rcx = URI (UTF-8) -> eax = LKS_SAVED when it is known to be saved (never asks Spotify)
PROC like_peek, 2
        call    lk_hash
        call    lk_slot
        mov     rax, [rdx]
        and     eax, 3
        EPROC

; ecx = x, edx = y of a right click -> eax = 1 when a menu opened (repaint)
PROC ui_context, 8
        mov     loc(0), rcx
        mov     loc(1), rdx
        call    menu_close
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        call    hit_find
        test    rax, rax
        jz      .none
        mov     ebx, [rax+16]                   ; hit id
        mov     esi, [rax+20]                   ; hit argument
        mov     dword [menu_arg], esi
        cmp     ebx, H_TRACK
        je      .track
        cmp     ebx, H_LIKE
        je      .track
        cmp     ebx, H_QUEUE_ROW
        je      .queue
        cmp     ebx, H_CARD
        je      .card
        cmp     ebx, H_NP_COVER
        je      .np
.none:  xor     eax, eax
        jmp     .out
        ; ---- a track row
.track: mov     ecx, esi
        call    like_uri_for
        test    rax, rax
        jz      .none
        cmp     byte [rax], 0
        je      .none
        mov     rcx, rax
        mov     loc(2), rax
        call    menu_set_uri
        lea     rcx, [mw_play]
        mov     edx, MA_PLAY
        call    menu_add
        lea     rcx, [mw_qadd]
        mov     edx, MA_QADD
        call    menu_add
        lea     rcx, [mw_next]
        mov     edx, MA_PLAYNEXT
        call    menu_add
        mov     rcx, loc(2)
        call    like_peek
        lea     rcx, [mw_save]
        cmp     eax, LKS_SAVED
        jne     .tl
        lea     rcx, [mw_unsave]
.tl:    mov     edx, MA_LIKE
        call    menu_add
        jmp     .links
        ; ---- a row of the queue panel
.queue: mov     eax, esi
        cmp     rax, [q_up+LS_COUNT]
        jae     .none
        imul    rax, rax, TR_SIZE
        add     rax, [q_up+LS_PTR]
        mov     rcx, [rax+TR_URI]
        test    rcx, rcx
        jz      .none
        call    menu_set_uri
        lea     rcx, [mw_play]
        mov     edx, MA_QPLAY
        call    menu_add
        lea     rcx, [mw_qremove]
        mov     edx, MA_QREMOVE
        call    menu_add
        test    esi, esi
        jz      .nqu
        lea     rcx, [mw_qup]
        mov     edx, MA_QUP
        call    menu_add
.nqu:   lea     eax, [rsi+1]
        cmp     rax, [q_up+LS_COUNT]
        jae     .nqd
        lea     rcx, [mw_qdown]
        mov     edx, MA_QDOWN
        call    menu_add
.nqd:   lea     rcx, [mw_qclear]
        mov     edx, MA_QCLEAR
        call    menu_add
        jmp     .links
        ; ---- an album / playlist / artist card
.card:  mov     ecx, esi
        shr     ecx, 16
        mov     edx, esi
        movzx   edx, dx
        call    card_at
        test    rax, rax
        jz      .none
        mov     rsi, rax
        mov     rcx, [rsi+CD_URI]
        test    rcx, rcx
        jz      .none
        mov     loc(2), rcx
        call    menu_set_uri
        cmp     dword [rsi+CD_KIND], KIND_ARTIST
        je      .links
        lea     rcx, [mw_cardopen]
        mov     edx, MA_CARDOPEN
        call    menu_add
        cmp     dword [rsi+CD_KIND], KIND_ALBUM
        jne     .links                          ; (a playlist's own save button would delete it: not offered)
        mov     rcx, loc(2)
        call    like_peek
        lea     rcx, [mw_save_lib]
        cmp     eax, LKS_SAVED
        jne     .cl
        lea     rcx, [mw_unsave_lib]
.cl:    mov     edx, MA_LIKE
        call    menu_add
        jmp     .links
        ; ---- the playing track (bar cover)
.np:    cmp     dword [np_valid], 0
        je      .none
        mov     rcx, [np_uri]
        test    rcx, rcx
        jz      .none
        call    menu_set_uri
.links: lea     rcx, [mw_copy]
        mov     edx, MA_COPY
        call    menu_add
        lea     rcx, [mw_open]
        mov     edx, MA_OPEN
        call    menu_add
        mov     eax, dword loc(0)
        mov     [menu_x], eax
        mov     eax, dword loc(1)
        mov     [menu_y], eax
        mov     dword [menu_open], 1
        mov     eax, 1
.out:   EPROC

; The menu surface and its rows (an overlay above the page).   Locals: 0 x, 1 y, 2 w, 3 row height, 4 pad, 5 h
PROC paint_menu, 8
        cmp     dword [menu_open], 0
        je      .out
        HIT     0, 0, dword [ui_w], dword [ui_h], H_MENU_BG, 0
        S       250
        mov     loc(2), rax
        S       36
        mov     loc(3), rax
        S       6
        mov     loc(4), rax
        mov     eax, [menu_n]
        imul    eax, dword loc(3)
        mov     ecx, dword loc(4)
        lea     eax, [rax+rcx*2]
        mov     loc(5), rax
        mov     eax, [menu_x]
        mov     ecx, [ui_w]
        sub     ecx, dword loc(2)
        cmp     eax, ecx
        cmova   eax, ecx
        mov     loc(0), rax
        mov     eax, [menu_y]
        mov     ecx, [ui_h]
        sub     ecx, dword loc(5)
        cmp     eax, ecx
        cmova   eax, ecx
        mov     loc(1), rax
        SETCOL  T_POPOVER
        S       10
        mov     outarg(5), rax
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(5)
        call    gfx_rrect_fill_border
        HIT     dword loc(0), dword loc(1), dword loc(2), dword loc(5), H_SHELL, 0
        xor     ebx, ebx
.row:   cmp     ebx, [menu_n]
        jae     .out
        mov     eax, ebx
        imul    eax, dword loc(3)
        add     eax, dword loc(1)
        add     eax, dword loc(4)
        mov     r12d, eax                       ; row y
        cmp     dword [hover_id], H_MENU_ITEM
        jne     .text
        cmp     dword [hover_arg], ebx
        jne     .text
        SETCOL  T_HOVER
        S       6
        mov     r8d, dword loc(2)
        sub     r8d, eax
        sub     r8d, eax
        mov     edx, r12d
        mov     ecx, dword loc(0)
        add     ecx, eax
        mov     r9d, dword loc(3)
        mov     outarg(5), rax
        call    gfx_rrect
.text:  SETFONT F_BODY
        SETCOL  T_FG
        SETALIGN 0
        mov     eax, ebx
        imul    rax, rax, MI_SIZE
        lea     rcx, [menu_items]
        mov     rcx, [rcx+rax]
        S       16
        mov     edx, dword loc(0)
        add     edx, eax
        mov     r8d, r12d
        mov     r9d, dword loc(2)
        sub     r9d, eax
        sub     r9d, eax
        mov     eax, dword loc(3)
        mov     outarg(5), rax
        call    gfx_text
        HIT     dword loc(0), r12d, dword loc(2), dword loc(3), H_MENU_ITEM, ebx
        inc     ebx
        jmp     .row
.out:   EPROC

; rcx = URI (UTF-8) -> rax = heap "https://open.spotify.com/<type>/<id>" or 0 (local files have no page)
PROC spotify_link, 6
        mov     loc(0), rcx
        lea     rdx, [s_spotify_pre]
        call    u8_starts
        test    eax, eax
        jz      .none
        mov     rcx, loc(0)
        lea     rdx, [u_local]
        call    u8_starts
        test    eax, eax
        jnz     .none
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [s_web_pre]
        call    buf_append_z
        mov     rsi, loc(0)
        add     rsi, 8                          ; past "spotify:"
.c:     mov     al, [rsi]
        test    al, al
        jz      .d
        cmp     al, ':'
        jne     .lit
        mov     al, '/'
.lit:   mov     qword loc(2), 0
        mov     byte loc(2), al
        lea     rcx, loc(5)
        lea     rdx, loc(2)
        call    buf_append_z
        inc     rsi
        jmp     .c
.d:     mov     rax, loc(5)
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC

; ecx = item index: closes the menu and does what the item says
PROC menu_run, 8
        cmp     ecx, [menu_n]
        jae     .out
        imul    rax, rcx, MI_SIZE
        lea     rdx, [menu_items]
        mov     eax, [rdx+rax+8]
        mov     loc(0), rax                     ; action
        mov     rax, [menu_uri]
        mov     qword [menu_uri], 0
        mov     loc(1), rax                     ; URI (now ours)
        mov     eax, [menu_arg]
        mov     loc(2), rax                     ; hit argument
        mov     dword [menu_open], 0
        mov     dword [menu_n], 0
        mov     eax, dword loc(0)
        cmp     eax, MA_PLAY
        je      .play
        cmp     eax, MA_QPLAY
        je      .qplay
        cmp     eax, MA_QADD
        je      .qadd
        cmp     eax, MA_PLAYNEXT
        je      .next
        cmp     eax, MA_LIKE
        je      .like
        cmp     eax, MA_COPY
        je      .copy
        cmp     eax, MA_OPEN
        je      .open
        cmp     eax, MA_QREMOVE
        je      .qrm
        cmp     eax, MA_QUP
        je      .qup
        cmp     eax, MA_QDOWN
        je      .qdown
        cmp     eax, MA_QCLEAR
        je      .qclr
        cmp     eax, MA_CARDOPEN
        je      .cardopen
        jmp     .free
.play:  mov     ecx, H_TRACK
        mov     edx, dword loc(2)
        call    ui_activate
        jmp     .free
.qplay: mov     ecx, H_QUEUE_ROW
        mov     edx, dword loc(2)
        call    ui_activate
        jmp     .free
.cardopen:
        mov     ecx, H_CARD
        mov     edx, dword loc(2)
        call    ui_activate
        jmp     .free
.qadd:  mov     ecx, dword loc(2)
        call    track_for_arg
        test    rax, rax
        jz      .free
        mov     rcx, rax
        call    queue_add
        cmp     dword [g_demo], 0
        je      .free
        lea     rcx, [w_queued]
        call    ui_toast
        jmp     .free
.next:  mov     ecx, dword loc(2)
        call    track_for_arg
        test    rax, rax
        jz      .free
        mov     rcx, rax
        call    queue_play_next
        jmp     .free
.like:  mov     rcx, loc(1)
        call    like_toggle
        jmp     .free
.copy:  mov     rcx, loc(1)
        call    spotify_link
        test    rax, rax
        jz      .free
        mov     loc(3), rax
        mov     rcx, rax
        call    os_clipboard
        mov     rcx, loc(3)
        call    mem_free
        lea     rcx, [w_link_done]
        call    ui_toast
        jmp     .free
.open:  mov     rcx, loc(1)
        call    spotify_link
        test    rax, rax
        jz      .free
        mov     loc(3), rax
        mov     rcx, rax
        call    os_open_url
        mov     rcx, loc(3)
        call    mem_free
        jmp     .free
.qrm:   mov     ecx, dword loc(2)
        call    q_remove
        call    queue_replay
        jmp     .free
.qup:   mov     ecx, dword loc(2)
        dec     ecx
        call    q_swap
        call    queue_replay
        jmp     .free
.qdown: mov     ecx, dword loc(2)
        call    q_swap
        call    queue_replay
        jmp     .free
.qclr:  lea     rcx, [q_up]
        call    tracks_free
        call    queue_replay
.free:  mov     rcx, loc(1)
        call    mem_free
.out:   EPROC

; arg of a H_TRACK / H_LIKE hit (list source << 16 | row) -> rax = that Track* or 0
track_for_arg:
        mov     edx, ecx
        shr     edx, 16
        movzx   ecx, cx
        lea     rax, [lst_recent]
        cmp     edx, SRC_RECENT
        je      .row
        lea     rax, [lst_liked]
        cmp     edx, SRC_LIKED
        je      .row
        lea     rax, [lst_search_t]
        cmp     edx, SRC_SEARCH_T
        je      .row
        lea     rax, [lst_detail]
        cmp     edx, SRC_DETAIL
        je      .row
        xor     eax, eax
        ret
.row:   cmp     rcx, [rax+LS_COUNT]
        jae     .none
        imul    rcx, TR_SIZE
        add     rcx, [rax+LS_PTR]
        mov     rax, rcx
        ret
.none:  xor     eax, eax
        ret
