; app.asm - application state transitions: loading data, opening pages, handling clicks / keys.

section .bss
lst_playlists:  resq 3
lst_albums:     resq 3
lst_liked:      resq 3
lst_recent:     resq 3
lst_search_t:   resq 3
lst_search_a:   resq 3
lst_search_p:   resq 3
lst_search_r:   resq 3
lst_detail:     resq 3
back_page:      resd 1
focus_req:      resd 1                  ; 1 = move keyboard focus to the search box, 2 = client-id box

section .data
ZSTR a_items, "items"
ZSTR a_album, "album"
ZSTR a_tracks_items, "tracks.items"
ZSTR a_albums_items, "albums.items"
ZSTR a_playlists_items, "playlists.items"
ZSTR a_artists_items, "artists.items"
ZSTR a_demo_user, "Demo Listener"
WSTR w_artist_na, "Artist pages are not available yet"
WSTR w_need_signin, "Sign in with Spotify first"

section .text

; ---------------------------------------------------------------- data
PROC app_free_search, 0
        lea     rcx, [lst_search_t]
        call    tracks_free
        lea     rcx, [lst_search_a]
        call    cards_free
        lea     rcx, [lst_search_p]
        call    cards_free
        lea     rcx, [lst_search_r]
        call    cards_free
        EPROC

PROC app_free_all, 0
        lea     rcx, [q_up]
        call    tracks_free
        lea     rcx, [lst_playlists]
        call    cards_free
        lea     rcx, [lst_albums]
        call    cards_free
        lea     rcx, [lst_liked]
        call    tracks_free
        lea     rcx, [lst_recent]
        call    tracks_free
        lea     rcx, [lst_detail]
        call    tracks_free
        call    app_free_search
        EPROC

; Fills every list from the embedded fixtures (the same JSON shapes the live API returns).
PROC app_load_demo, 0
        call    app_free_all
        lea     rcx, [fx_playlists]
        lea     rdx, [a_items]
        lea     r8, [lst_playlists]
        mov     r9d, KIND_PLAYLIST
        mov     qword outarg(5), 0
        call    parse_cards
        lea     rcx, [fx_saved_albums]
        lea     rdx, [a_items]
        lea     r8, [lst_albums]
        mov     r9d, KIND_ALBUM
        lea     rax, [a_album]
        mov     outarg(5), rax
        call    parse_cards
        lea     rcx, [fx_saved_tracks]
        lea     rdx, [a_items]
        lea     r8, [lst_liked]
        mov     r9d, 1
        call    parse_tracks
        lea     rcx, [fx_recent]
        lea     rdx, [a_items]
        lea     r8, [lst_recent]
        mov     r9d, 1
        call    parse_tracks
        call    lk_reset
        lea     rcx, [lst_liked]
        call    lk_mark_tracks
        lea     rcx, [lst_albums]
        call    lk_mark_cards
        mov     rcx, [user_name]
        call    mem_free
        lea     rcx, [a_demo_user]
        mov     rdx, -1
        call    u8_to_w
        mov     [user_name], rax
        mov     dword [g_demo], 1
        mov     dword [signed_in], 1
        mov     dword [np_vol], 70
        EPROC

; rcx = search text (UTF-16)
PROC app_search_demo, 0
        push    rcx
        sub     rsp, 8
        call    app_free_search
        add     rsp, 8
        pop     rcx
        cmp     word [rcx], 0
        je      .out
        lea     rcx, [fx_search]
        lea     rdx, [a_tracks_items]
        lea     r8, [lst_search_t]
        xor     r9d, r9d
        call    parse_tracks
        lea     rcx, [fx_search]
        lea     rdx, [a_albums_items]
        lea     r8, [lst_search_a]
        mov     r9d, KIND_ALBUM
        mov     qword outarg(5), 0
        call    parse_cards
        lea     rcx, [fx_search]
        lea     rdx, [a_playlists_items]
        lea     r8, [lst_search_p]
        mov     r9d, KIND_PLAYLIST
        mov     qword outarg(5), 0
        call    parse_cards
        lea     rcx, [fx_search]
        lea     rdx, [a_artists_items]
        lea     r8, [lst_search_r]
        mov     r9d, KIND_ARTIST
        mov     qword outarg(5), 0
        call    parse_cards
.out:   EPROC

; ---------------------------------------------------------------- list lookup
; ecx = source id -> rax = Card list or 0
card_list_for:
        lea     rax, [lst_playlists]
        cmp     ecx, SRC_PLAYLISTS
        je      .r
        lea     rax, [lst_albums]
        cmp     ecx, SRC_ALBUMS
        je      .r
        lea     rax, [lst_search_a]
        cmp     ecx, SRC_SEARCH_A
        je      .r
        lea     rax, [lst_search_p]
        cmp     ecx, SRC_SEARCH_P
        je      .r
        lea     rax, [lst_search_r]
        cmp     ecx, SRC_SEARCH_R
        je      .r
        xor     eax, eax
.r:     ret

track_list_for:
        lea     rax, [lst_recent]
        cmp     ecx, SRC_RECENT
        je      .r
        lea     rax, [lst_liked]
        cmp     ecx, SRC_LIKED
        je      .r
        lea     rax, [lst_search_t]
        cmp     ecx, SRC_SEARCH_T
        je      .r
        lea     rax, [lst_detail]
        cmp     ecx, SRC_DETAIL
        je      .r
        xor     eax, eax
.r:     ret

; ecx = source, edx = index -> rax = Card* or 0
card_at:
        push    rdx
        sub     rsp, 8
        call    card_list_for
        add     rsp, 8
        pop     rdx
        test    rax, rax
        jz      .r
        cmp     rdx, [rax+LS_COUNT]
        jae     .none
        imul    rdx, CD_SIZE
        add     rdx, [rax+LS_PTR]
        mov     rax, rdx
        ret
.none:  xor     eax, eax
.r:     ret

; ---------------------------------------------------------------- detail pages
; Tracks of an album arrive without album info: borrow it from the card.
PROC detail_fill_album, 2
        mov     rbx, rcx
        xor     r12d, r12d
.l:     cmp     r12, [lst_detail+LS_COUNT]
        jae     .out
        mov     rax, r12
        imul    rax, TR_SIZE
        add     rax, [lst_detail+LS_PTR]
        mov     rsi, rax
        mov     rcx, [rbx+CD_NAME]
        call    w_dup
        mov     rcx, [rsi+TR_ALBUM]
        mov     loc(0), rax
        call    mem_free
        mov     rax, loc(0)
        mov     [rsi+TR_ALBUM], rax
        mov     rcx, [rbx+CD_IMG_M]
        call    u8_dup0
        mov     rcx, [rsi+TR_IMG_S]
        mov     loc(0), rax
        call    mem_free
        mov     rax, loc(0)
        mov     [rsi+TR_IMG_S], rax
        mov     rcx, [rbx+CD_IMG_L]
        call    u8_dup0
        mov     rcx, [rsi+TR_IMG_L]
        mov     loc(0), rax
        call    mem_free
        mov     rax, loc(0)
        mov     [rsi+TR_IMG_L], rax
        inc     r12
        jmp     .l
.out:   EPROC

; rcx = Card*, edx = index in the sidebar playlist list or -1
PROC app_open_detail, 2
        mov     rbx, rcx
        mov     loc(0), rdx
        mov     rcx, [det_title]
        call    mem_free
        mov     rcx, [det_sub]
        call    mem_free
        mov     rcx, [det_img]
        call    mem_free
        mov     rcx, [det_uri]
        call    mem_free
        mov     rcx, [rbx+CD_NAME]
        call    w_dup
        mov     [det_title], rax
        mov     rcx, [rbx+CD_SUB]
        call    w_dup
        mov     [det_sub], rax
        mov     rcx, [det_img_m]
        call    mem_free
        mov     rcx, [rbx+CD_IMG_M]
        call    u8_dup0
        mov     [det_img_m], rax
        mov     rcx, [rbx+CD_IMG_L]
        call    u8_dup0
        mov     [det_img], rax
        mov     rcx, [rbx+CD_URI]
        call    u8_dup0
        mov     [det_uri], rax
        mov     eax, [rbx+CD_KIND]
        mov     [det_kind], eax
        mov     eax, [rbx+CD_COUNT]
        mov     [det_count], eax
        lea     rcx, [lst_detail]
        call    tracks_free
        cmp     dword [g_demo], 0
        je      .real
        cmp     dword [det_kind], KIND_ALBUM
        je      .album
        lea     rcx, [fx_playlist_items]
        lea     rdx, [a_items]
        lea     r8, [lst_detail]
        mov     r9d, 1
        call    parse_tracks
        jmp     .show
.album: lea     rcx, [fx_album_tracks]
        lea     rdx, [a_items]
        lea     r8, [lst_detail]
        xor     r9d, r9d
        call    parse_tracks
        mov     rcx, rbx
        call    detail_fill_album
        jmp     .show
.real:  mov     rcx, rbx
        call    real_load_detail
.show:  cmp     dword [page], PAGE_DETAIL
        je      .keep
        mov     eax, [page]
        mov     [back_page], eax
.keep:  mov     dword [page], PAGE_DETAIL
        mov     dword [scroll_main], 0
        mov     eax, dword loc(0)
        mov     [detail_sel], eax
        EPROC

; ---------------------------------------------------------------- activation (clicks)
; ecx = hit id, edx = hit arg -> eax = 1 when the screen must be repainted
PROC ui_activate, 6
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     eax, 1
        cmp     ecx, H_NAV
        je      .nav
        cmp     ecx, H_SIDE_PL
        je      .side
        cmp     ecx, H_CARD
        je      .card
        cmp     ecx, H_CARD_PLAY
        je      .cardplay
        cmp     ecx, H_TRACK
        je      .track
        cmp     ecx, H_PLAY
        je      .play
        cmp     ecx, H_PREV
        je      .prev
        cmp     ecx, H_NEXT
        je      .next
        cmp     ecx, H_SHUFFLE
        je      .shuffle
        cmp     ecx, H_REPEAT
        je      .repeat
        cmp     ecx, H_QUEUE
        je      .queue
        cmp     ecx, H_FULL
        je      .full
        cmp     ecx, H_NP_COVER
        je      .full
        cmp     ecx, H_FS_CLOSE
        je      .fsclose
        cmp     ecx, H_TAB
        je      .tab
        cmp     ecx, H_THEME
        je      .theme
        cmp     ecx, H_BACK
        je      .back
        cmp     ecx, H_DETAIL_PLAY
        je      .dplay
        cmp     ecx, H_QUEUE_ROW
        je      .qrow
        cmp     ecx, H_SEARCHBOX
        je      .sbox
        cmp     ecx, H_DEMO
        je      .demo
        cmp     ecx, H_SIGNIN
        je      .signin
        cmp     ecx, H_SIGNOUT
        je      .signout
        cmp     ecx, H_COPY_URI
        je      .copyuri
        cmp     ecx, H_OPEN_DASH
        je      .dash
        cmp     ecx, H_BANNER_X
        je      .bclose
        cmp     ecx, H_BANNER_ACT
        je      .bact
        cmp     ecx, H_OPEN_LOG
        je      .openlog
        cmp     ecx, H_COPY_DIAG
        je      .copydiag
        cmp     ecx, H_CANCEL_SIGNIN
        je      .cancelsignin
        cmp     ecx, H_COPY_AUTH
        je      .copyauth
        cmp     ecx, H_TEST_AUDIO
        je      .testaudio
        cmp     ecx, H_LIKE
        je      .like
        cmp     ecx, H_MENU_ITEM
        je      .menuitem
        cmp     ecx, H_MENU_BG
        je      .menubg
        xor     eax, eax
        jmp     .out
.nav:   mov     eax, edx
        mov     [page], eax
        mov     dword [scroll_main], 0
        mov     dword [detail_sel], -1
        cmp     eax, PAGE_SEARCH
        jne     .done
        mov     dword [focus_req], 1
        jmp     .done
.side:  mov     ecx, SRC_PLAYLISTS
        mov     edx, dword loc(1)
        call    card_at
        test    rax, rax
        jz      .done
        mov     rcx, rax
        mov     edx, dword loc(1)
        call    app_open_detail
        jmp     .done
.card:  mov     eax, dword loc(1)
        mov     ecx, eax
        shr     ecx, 16
        movzx   edx, ax
        call    card_at
        test    rax, rax
        jz      .done
        cmp     dword [rax+CD_KIND], KIND_ARTIST
        jne     .open
        lea     rcx, [w_artist_na]
        call    ui_toast
        jmp     .done
.open:  mov     rcx, rax
        mov     edx, -1
        call    app_open_detail
        jmp     .done
.cardplay:
        mov     eax, dword loc(1)
        mov     ecx, eax
        shr     ecx, 16
        movzx   edx, ax
        call    card_at
        test    rax, rax
        jz      .done
        mov     rcx, rax
        mov     edx, -1
        call    app_open_detail
        lea     rcx, [lst_detail]
        xor     edx, edx
        call    player_play_list
        jmp     .done
.track: mov     eax, dword loc(1)
        mov     ecx, eax
        shr     ecx, 16
        movzx   ebx, ax
        call    track_list_for
        test    rax, rax
        jz      .done
        mov     rcx, rax
        mov     edx, ebx
        call    player_play_list
        jmp     .done
.play:  cmp     dword [np_valid], 0
        jne     .tog
        lea     rcx, [lst_recent]           ; nothing loaded yet: start from the recent list
        cmp     qword [rcx+LS_COUNT], 0
        je      .done
        xor     edx, edx
        call    player_play_list
        jmp     .done
.tog:   call    player_toggle
        jmp     .done
.prev:  call    player_prev
        jmp     .done
.next:  call    player_next
        jmp     .done
.shuffle:
        call    player_shuffle_toggle
        jmp     .done
.repeat:
        call    player_repeat_cycle
        jmp     .done
.queue: xor     dword [queue_open], 1
        jmp     .done
.full:  mov     dword [fullscreen], 1
        jmp     .done
.fsclose:
        mov     dword [fullscreen], 0
        jmp     .done
.tab:   mov     eax, dword loc(1)
        mov     [lib_tab], eax
        mov     dword [scroll_main], 0
        jmp     .done
.theme: mov     ecx, dword loc(1)
        call    theme_set
        call    ui_theme_changed
        jmp     .done
.back:  mov     eax, [back_page]
        mov     [page], eax
        mov     dword [scroll_main], 0
        mov     dword [detail_sel], -1
        jmp     .done
.dplay: lea     rcx, [lst_detail]
        xor     edx, edx
        call    player_play_list
        jmp     .done
.qrow:  cmp     dword [g_demo], 0
        jne     .qdemo
        lea     rcx, [q_up]                     ; live: play the queue from that row on
        mov     edx, dword loc(1)
        call    player_play_list
        jmp     .done
.qdemo: mov     ebx, dword loc(1)
.skip:  call    player_next
        dec     ebx
        jns     .skip
        jmp     .done
.sbox:  mov     dword [focus_req], 1
        jmp     .done
.demo:  call    app_load_demo
        mov     dword [page], PAGE_HOME
        jmp     .done
.signin:
        call    real_sign_in
        jmp     .done
.copyuri:
        call    app_copy_redirect
        jmp     .done
.openlog:
        call    app_open_log_folder
        jmp     .done
.cancelsignin:
        call    auth_cancel
        jmp     .done
.copyauth:
        mov     rcx, [auth_url_buf]
        test    rcx, rcx
        jz      .done
        call    os_clipboard
        lea     rcx, [w_link_copied]
        call    ui_toast
        jmp     .done
.copydiag:
        call    app_copy_diagnostics
        jmp     .done
.menuitem:
        mov     ecx, dword loc(1)
        call    menu_run
        jmp     .done
.menubg:
        call    menu_close
        jmp     .done
.like:  mov     ecx, dword loc(1)
        call    like_uri_for
        mov     rcx, rax
        call    like_toggle
        jmp     .done
.testaudio:
        cmp     dword [g_demo], 0
        je      .ta_live
        lea     rcx, [w_ta_demo]
        call    ui_toast
        jmp     .done
.ta_live:
        call    audio_test
        jmp     .done
.dash:  lea     rcx, [s_dashboard_url]
        call    os_open_url
        jmp     .done
.bclose:
        call    ui_banner_clear
        jmp     .done
.bact:  mov     eax, dword loc(1)
        call    ui_banner_clear
        cmp     dword loc(1), BA_DASHBOARD
        jne     .bset
        lea     rcx, [s_dashboard_url]
        call    os_open_url
        jmp     .done
.bset:  cmp     dword loc(1), BA_GET_EDGE
        jne     .bset2
        lea     rcx, [s_edge_url]
        call    os_open_url
        jmp     .done
.bset2: cmp     dword loc(1), BA_SETTINGS
        jne     .done
        cmp     dword [signed_in], 0
        je      .done                           ; signed out: the setup fields are already on screen
        mov     dword [page], PAGE_SETTINGS
        mov     dword [scroll_main], 0
        jmp     .done
.signout:
        call    real_sign_out
        cmp     dword [g_demo], 0
        je      .done
        mov     dword [g_demo], 0
        mov     dword [signed_in], 0
        mov     dword [page], PAGE_LOGIN
.done:  mov     eax, 1
.out:   EPROC

; ---------------------------------------------------------------- mouse
; ecx = x, edx = y -> eax = bit0 repaint
PROC ui_mouse_move, 2
        mov     [mouse_x], ecx
        mov     loc(0), rcx
        mov     [mouse_y], edx
        cmp     dword [drag_id], 0
        je      .hover
        call    ui_drag_update
        mov     eax, 1
        jmp     .out
.hover: mov     ecx, dword loc(0)
        call    hit_find
        xor     ecx, ecx
        xor     edx, edx
        test    rax, rax
        jz      .cmp
        mov     ecx, [rax+16]
        mov     edx, [rax+20]
        cmp     ecx, H_SHELL
        jne     .cmp
        xor     ecx, ecx
        xor     edx, edx
.cmp:   xor     eax, eax
        cmp     ecx, [hover_id]
        jne     .chg
        cmp     edx, [hover_arg]
        je      .out
.chg:   mov     [hover_id], ecx
        mov     [hover_arg], edx
        mov     eax, 1
.out:   EPROC

; Updates the seek / volume drag from the mouse x kept in mouse_x
PROC ui_drag_update, 0
        mov     eax, [mouse_x]
        sub     eax, [drag_x]
        jns     .lo
        xor     eax, eax
.lo:    imul    eax, 1000
        mov     ecx, [drag_w]
        test    ecx, ecx
        jz      .out
        xor     edx, edx
        div     ecx
        cmp     eax, 1000
        jbe     .set
        mov     eax, 1000
.set:   mov     [drag_frac], eax
        cmp     dword [drag_id], H_VOL
        jne     .out
        xor     edx, edx
        mov     ecx, 10
        div     ecx
        mov     ecx, eax
        call    player_set_volume
.out:   EPROC

; ecx = x, edx = y -> eax: bit0 repaint, bit1 capture the mouse
PROC ui_mouse_down, 2
        mov     [mouse_x], ecx
        call    hit_find
        xor     ecx, ecx
        xor     edx, edx
        test    rax, rax
        jz      .rec
        mov     ecx, [rax+16]
        mov     edx, [rax+20]
.rec:   mov     [press_id], ecx
        mov     [press_arg], edx
        cmp     ecx, H_SEEK
        je      .seek
        cmp     ecx, H_VOL
        je      .vol
        xor     eax, eax
        jmp     .out
.seek:  cmp     dword [np_valid], 0
        je      .none
        mov     eax, [seek_x]
        mov     [drag_x], eax
        mov     eax, [seek_w]
        mov     [drag_w], eax
        mov     dword [drag_id], H_SEEK
        jmp     .go
.vol:   mov     eax, [vol_x]
        mov     [drag_x], eax
        mov     eax, [vol_w]
        mov     [drag_w], eax
        mov     dword [drag_id], H_VOL
.go:    call    ui_drag_update
        mov     eax, 3
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC

; ecx = x, edx = y -> eax: bit0 repaint, bit1 release the mouse capture
PROC ui_mouse_up, 2
        mov     [mouse_x], ecx
        mov     eax, [drag_id]
        test    eax, eax
        jz      .click
        cmp     eax, H_SEEK
        jne     .enddrag
        call    ui_drag_update
        mov     eax, [np_dur]
        imul    eax, [drag_frac]
        xor     edx, edx
        mov     ecx, 1000
        div     ecx
        mov     ecx, eax
        call    player_seek
.enddrag:
        mov     dword [drag_id], 0
        mov     dword [press_id], 0
        mov     eax, 3
        jmp     .out
.click: call    hit_find
        test    rax, rax
        jz      .nohit
        mov     ecx, [rax+16]
        mov     edx, [rax+20]
        cmp     ecx, [press_id]
        jne     .nohit
        cmp     edx, [press_arg]
        jne     .nohit
        call    ui_activate
        mov     dword [press_id], 0
        jmp     .out
.nohit: mov     dword [press_id], 0
        xor     eax, eax
.out:   EPROC

; ecx = wheel delta (signed, 120 per notch), edx = mouse x
PROC ui_wheel, 2
        cmp     dword [fullscreen], 0
        jne     .none
        movsxd  rax, ecx
        imul    rax, -60
        mov     r8d, [ui_scale]
        imul    rax, r8
        sar     rax, 16
        cqo
        mov     rcx, 120
        idiv    rcx
        mov     ecx, eax                        ; signed pixel step
        cmp     edx, [lay_sb_w]
        jl      .side
        cmp     edx, [lay_q_x]
        jge     .q
        add     [scroll_main], ecx
        jmp     .ok
.side:  add     [scroll_side], ecx
        jmp     .ok
.q:     cmp     dword [queue_open], 0
        je      .none
        add     [scroll_queue], ecx
.ok:    mov     eax, 1
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC

; ---------------------------------------------------------------- keyboard
; ecx = virtual key -> eax = 1 to repaint
PROC ui_key, 2
        mov     loc(0), rcx
        xor     eax, eax
        cmp     ecx, VK_ESCAPE
        je      .esc
        cmp     ecx, VK_SPACE
        je      .space
        cmp     ecx, VK_F11
        je      .f11
        cmp     ecx, 'F'
        je      .f
        cmp     ecx, 'N'
        je      .nx
        cmp     ecx, 'P'
        je      .pv
        cmp     ecx, VK_RIGHT
        je      .right
        cmp     ecx, VK_LEFT
        je      .left
        cmp     ecx, VK_UP
        je      .up
        cmp     ecx, VK_DOWN
        je      .down
        jmp     .out
.esc:   cmp     dword [menu_open], 0
        je      .esc2
        call    menu_close
        jmp     .yes
.esc2:  cmp     dword [fullscreen], 0
        je      .out
        mov     dword [fullscreen], 0
        jmp     .yes
.space: mov     ecx, H_PLAY
        xor     edx, edx
        call    ui_activate
        jmp     .out
.f11:
.f:     xor     dword [fullscreen], 1
        jmp     .yes
.nx:    call    player_next
        jmp     .yes
.pv:    call    player_prev
        jmp     .yes
.right: call    np_position
        add     eax, 5000
        mov     ecx, eax
        call    player_seek
        jmp     .yes
.left:  call    np_position
        sub     eax, 5000
        jns     .l2
        xor     eax, eax
.l2:    mov     ecx, eax
        call    player_seek
        jmp     .yes
.up:    mov     ecx, [np_vol]
        add     ecx, 5
        call    player_set_volume
        jmp     .yes
.down:  mov     ecx, [np_vol]
        sub     ecx, 5
        jns     .d2
        xor     ecx, ecx
.d2:    call    player_set_volume
.yes:   mov     eax, 1
.out:   EPROC

; copies the redirect URI to the clipboard and confirms with a toast
PROC app_copy_redirect, 4
        mov     qword loc(1), 0
        mov     qword loc(2), 0
        mov     qword loc(3), 0
        lea     rcx, loc(3)
        call    redirect_uri_append
        mov     rcx, loc(3)
        call    os_clipboard
        lea     rcx, loc(3)
        call    buf_free
        lea     rcx, [w_copied]
        call    ui_toast
        EPROC

section .data
WSTR w_copied, "Redirect URI copied"
WSTR w_need_client, "Enter your Spotify Client ID first (step 3)."
WSTR w_bad_port, "The port must be a number between 1024 and 65535."
WSTR w_signin_soon, "Sign-in is not wired up in this build yet."
section .text

; Sign-in button.  Validates the setup fields; the OAuth flow itself lands in the next milestone.
PROC app_sign_in_check, 0
        cmp     byte [set_client_id], 0
        jne     .port
        lea     rcx, [w_need_client]
        xor     edx, edx
        xor     r8d, r8d
        call    ui_banner
        mov     dword [focus_req], 2
        xor     eax, eax
        jmp     .out
.port:  mov     eax, [set_port]
        cmp     eax, 1024
        jb      .badport
        cmp     eax, 65535
        ja      .badport
        mov     eax, 1
        jmp     .out
.badport:
        lea     rcx, [w_bad_port]
        xor     edx, edx
        xor     r8d, r8d
        call    ui_banner
        mov     dword [focus_req], 3
        xor     eax, eax
.out:   EPROC

PROC app_open_log_folder, 2
        lea     rcx, [data_dir]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(0), rax
        mov     rcx, rax
        call    os_open_url                     ; ShellExecute "open" on a folder opens Explorer
        mov     rcx, loc(0)
        call    mem_free
        EPROC

; Version / OS line followed by the tail of the log, on the clipboard.
PROC app_copy_diagnostics, 6
        mov     qword loc(1), 0                 ; Buf based at &loc(3)
        mov     qword loc(2), 0
        mov     qword loc(3), 0
        lea     rcx, loc(3)
        lea     rdx, [l_start]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [app_version]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [l_build]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [build_id]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [l_win]
        call    buf_append_z
        lea     rcx, loc(3)
        mov     edx, [os_ver]
        call    buf_append_u64
        lea     rcx, loc(3)
        lea     rdx, [l_dot]
        call    buf_append_z
        lea     rcx, loc(3)
        mov     edx, [os_ver+4]
        call    buf_append_u64
        lea     rcx, loc(3)
        lea     rdx, [l_dot]
        call    buf_append_z
        lea     rcx, loc(3)
        mov     edx, [os_ver+8]
        call    buf_append_u64
        lea     rcx, loc(3)
        lea     rdx, [l_nl]
        call    buf_append_z
        lea     rcx, [log_path]
        call    file_read_all                   ; rax = contents, rdx = length
        test    rax, rax
        jz      .send
        mov     loc(0), rax
        mov     rsi, rax
        cmp     rdx, 6000
        jbe     .copy
        lea     rsi, [rax+rdx-6000]             ; only the tail ...
.skip:  cmp     byte [rsi], 10                  ; ... starting at a line boundary
        je      .bol
        cmp     byte [rsi], 0
        je      .copy
        inc     rsi
        jmp     .skip
.bol:   inc     rsi
.copy:  lea     rcx, loc(3)
        mov     rdx, rsi
        call    buf_append_z
        mov     rcx, loc(0)
        call    mem_free
.send:  mov     rcx, loc(3)
        call    os_clipboard
        lea     rcx, loc(3)
        call    buf_free
        lea     rcx, [w_diag_copied]
        call    ui_toast
        EPROC

section .data
WSTR w_diag_copied, "Diagnostics copied to the clipboard"
section .text

section .data
WSTR w_link_copied, "Sign-in link copied"
section .text
