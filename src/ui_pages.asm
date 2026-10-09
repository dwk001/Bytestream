; ui_pages.asm - the screens that fill the main area: Home, Search, Library, Detail, Settings, Login.

section .bss
pg_x:           resd 1                  ; content origin for the page being painted
pg_y:           resd 1                  ; first y (already offset by the scroll position)
pg_w:           resd 1
edit_want:      resd 1                  ; bit 0: search box wanted, bit 1: client-id box wanted
edit_sx:        resd 1
edit_sy:        resd 1
edit_sw:        resd 1
edit_sh:        resd 1
edit_cx:        resd 1
edit_cy:        resd 1
edit_cw:        resd 1
edit_ch:        resd 1
det_title:      resq 1                  ; UTF-16, owned
det_sub:        resq 1
det_img:        resq 1                  ; UTF-8, owned
det_uri:        resq 1
det_kind:       resd 1
det_count:      resd 1
                align 8
sys_time:       resw 8

section .data
WSTR w_gm, "Good morning"
WSTR w_ga, "Good afternoon"
WSTR w_ge, "Good evening"
WSTR w_your_playlists, "Your playlists"
WSTR w_recent, "Recently played"
WSTR w_library, "Your Library"
WSTR w_tab_pl, "Playlists"
WSTR w_tab_liked, "Liked Songs"
WSTR w_tab_albums, "Albums"
WSTR w_search_hint, "Search"
WSTR w_cue_search, "What do you want to listen to?"
WSTR w_cue_client, "Paste your client ID"
WSTR w_search_none, "Type in the box above to search"
WSTR w_songs, "Songs"
WSTR w_albums, "Albums"
WSTR w_playlists, "Playlists"
WSTR w_artists, "Artists"
WSTR w_settings, "Settings"
WSTR w_account, "Account"
WSTR w_appearance, "Appearance"
WSTR w_about, "About"
WSTR w_signed_as, "Signed in as "
WSTR w_demo_mode, "Demo mode: showing built-in sample music"
WSTR w_signout, "Sign out"
WSTR w_theme_dark, "Dark"
WSTR w_theme_mid, "Midnight"
WSTR w_theme_light, "Light"
WSTR w_shortcuts, "Keyboard and mouse"
WSTR w_sc1, "Space  Play / pause        N / P  Next / previous track"
WSTR w_sc2, "Left / Right  Seek 5 seconds        Up / Down  Volume"
WSTR w_sc3, "F or F11  Full screen        Esc  Close a menu, dialog or full screen"
WSTR w_sc4, "Right-click a track, card or queue row for its menu (add to queue, save, add to a playlist, copy link ...)"
WSTR w_sc5, "Media keys work while ByteStream is focused, and Windows shows what is playing."
WSTR w_about1, "ByteStream for Windows, written in x86-64 assembly."
WSTR w_about2, "Playback uses the official Spotify Web Playback SDK and needs Spotify Premium."
WSTR w_about3, "Not affiliated with Spotify. Spotify is a trademark of Spotify AB."
WSTR w_about5, "Colour themes are Sonora's (GPL-3.0, github.com/sonorahq/sonora), which ByteStream takes its feature set from."
WSTR w_about4, `Music, metadata and cover art come from Spotify; use "Open in Spotify" in a right-click menu to see any item there.`
WSTR w_play, "Play"
WSTR w_cap_playlist, "PLAYLIST"
WSTR w_cap_album, "ALBUM"
WSTR w_cap_artist, "ARTIST"
WSTR w_welcome, "Welcome to ByteStream"
WSTR w_login_sub, "Listen to your Spotify library in a fast, native player."
WSTR w_clientid_lbl, "Spotify client ID"
WSTR w_signin, "Sign in with Spotify"
WSTR w_demo_btn, "Try the demo"
WSTR w_login_hint1, "Create a free app at developer.spotify.com/dashboard and add"
WSTR w_login_hint2, "http://127.0.0.1:8989/callback as a redirect URI, then paste its client ID."
WSTR w_login_hint3, "Playback needs a Spotify Premium account."
WSTR w_loading, "Loading..."
WSTR w_step1, "Create an app in the Spotify dashboard"
WSTR w_step2, "Add this Redirect URI to that app"
WSTR w_step3, "Paste the app's Client ID"
WSTR w_n1, "1"
WSTR w_n2, "2"
WSTR w_n3, "3"
WSTR w_open_dash, "Open dashboard"
WSTR w_copy, "Copy"
WSTR w_port, "Port"
WSTR w_spotify, "Spotify"
WSTR w_clientid_s, "Client ID"
WSTR w_redirect_s, "Redirect URI (add this to your Spotify app)"
WSTR w_login_note1, "Playback needs Spotify Premium. Apps in development mode allow up to 5 listed users."
WSTR w_login_note2, "Everything here can be changed later in Settings."
WSTR w_waiting, "Waiting for your browser..."
WSTR w_signing_in, "Signing in..."
WSTR w_copy_link, "Copy sign-in link"
WSTR w_cancel, "Cancel"
WSTR w_diag, "Diagnostics"
WSTR w_open_log, "Open log folder"
WSTR w_copy_diag, "Copy diagnostics"
WSTR w_test_audio, "Test audio"
WSTR w_edit_btn, "Edit"
WSTR w_delete_btn, "Delete"
WSTR w_diag_hint, "If something goes wrong, copy the diagnostics and send them with your report. Tokens are never logged."
WSTR w_no_results, "No results"

section .text

; ---------------------------------------------------------------- page frame
; Sets the clip to the main area and the origin for the page body. Returns eax = y of the first line.
PROC page_begin, 0
        mov     ecx, [lay_main_x]
        xor     edx, edx
        mov     r8d, [lay_main_w]
        mov     r9d, [lay_main_h]
        call    ui_clip
        mov     eax, [lay_main_x]
        add     eax, [lay_pad]
        mov     [pg_x], eax
        mov     eax, [lay_main_w]
        sub     eax, [lay_pad]
        sub     eax, [lay_pad]
        mov     [pg_w], eax
        mov     eax, [lay_pad]
        sub     eax, [scroll_main]
        add     eax, [banner_h]                 ; the error banner sits above the page
        mov     [pg_y], eax
        HIT     dword [lay_main_x], 0, dword [lay_main_w], dword [lay_main_h], H_SHELL, 0
        mov     eax, [pg_y]
        EPROC

; eax = y after the last element: records the content height and clamps the scroll position
PROC page_end, 0
        add     eax, [scroll_main]
        sub     eax, [banner_h]
        add     eax, [lay_pad]
        mov     [content_h], eax
        mov     ecx, [lay_main_h]
        mov     [view_h], ecx
        sub     eax, ecx
        jns     .mx
        xor     eax, eax
.mx:    cmp     [scroll_main], eax
        jle     .lo
        mov     [scroll_main], eax
.lo:    cmp     dword [scroll_main], 0
        jge     .done
        mov     dword [scroll_main], 0
.done:  call    ui_unclip
        call    lib_scroll_check
        EPROC

; rcx = List*, edx = y -> eax = y of the next element.  An empty list gets one muted line ("Loading..." while
; anything is still in flight, else "Nothing here yet.")
PROC draw_empty_hint, 2
        mov     loc(0), rdx
        cmp     qword [rcx+LS_COUNT], 0
        jne     .keep
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        SETALIGN 0
        lea     rcx, [w_lib_nothing]
        mov     eax, [det_busy]
        or      eax, [lib_busy]
        or      eax, [lib_busy+4]
        or      eax, [lib_busy+8]
        or      eax, [lib_busy+12]
        or      eax, [srch_busy]
        jz      .t
        lea     rcx, [w_lib_loading]
.t:     mov     edx, [pg_x]
        mov     r8d, dword loc(0)
        mov     r9d, [pg_w]
        S       28
        mov     outarg(5), rax
        call    gfx_text
        S       40
        add     eax, dword loc(0)
        jmp     .out
.keep:  mov     eax, dword loc(0)
.out:   EPROC

; ---------------------------------------------------------------- Home
PROC page_home, 4
        call    page_begin
        mov     r12d, eax
        lea     rcx, [sys_time]
        call    GetLocalTime
        movzx   eax, word [sys_time+8]
        lea     rcx, [w_gm]
        cmp     eax, 12
        jb      .g
        lea     rcx, [w_ga]
        cmp     eax, 18
        jb      .g
        lea     rcx, [w_ge]
.g:     call    page_title_at
        mov     r12d, eax
        lea     rcx, [w_your_playlists]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        lea     rcx, [lst_playlists]
        mov     edx, r12d
        call    draw_empty_hint
        mov     r12d, eax
        lea     rcx, [lst_playlists]
        mov     edx, SRC_PLAYLISTS
        mov     r8d, [pg_x]
        mov     r9d, r12d
        mov     eax, [pg_w]
        mov     outarg(5), rax
        mov     eax, 0x8000000C                 ; one row, at most 12 cards
        mov     outarg(6), rax
        call    draw_cards
        mov     r12d, eax
        S       24
        add     r12d, eax
        lea     rcx, [w_recent]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        lea     rcx, [lst_recent]
        mov     edx, r12d
        call    draw_empty_hint
        mov     r12d, eax
        lea     rcx, [lst_recent]
        mov     edx, SRC_RECENT
        mov     r8d, [pg_x]
        mov     r9d, r12d
        mov     eax, [pg_w]
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        call    draw_tracks
        call    page_end
        EPROC

; rcx = title -> eax = y below (uses r12d as the y position set by the caller)
PROC page_title_at, 1
        mov     loc(0), rcx
        SETFONT F_H1
        SETCOL  T_FG
        SETALIGN 0
        S       48
        mov     ebx, eax
        mov     rcx, loc(0)
        TXT     rcx, dword [pg_x], r12d, dword [pg_w], ebx
        S       64
        add     eax, r12d
        EPROC

; ---------------------------------------------------------------- Search
PROC page_search, 4
        call    page_begin
        mov     r12d, eax
        lea     rcx, [w_search_hint]
        call    page_title_at
        mov     r12d, eax
        ; the search box: a rounded surface, with a native EDIT control placed over its inner area
        S       560
        mov     ebx, [pg_w]
        cmp     ebx, eax
        cmova   ebx, eax
        S       48
        mov     r13d, eax
        SETCOL  T_SURFACE
        mov     eax, r13d
        shr     eax, 1
        mov     outarg(5), rax
        mov     ecx, [pg_x]
        mov     edx, r12d
        mov     r8d, ebx
        mov     r9d, r13d
        call    gfx_rrect
        SETCOL  T_MUTED_FG
        S       20
        mov     esi, eax
        S       16
        mov     ecx, [pg_x]
        add     ecx, eax
        mov     edx, r13d
        sub     edx, esi
        shr     edx, 1
        add     edx, r12d
        mov     r8d, esi
        lea     r9, [ic_search]
        call    icon_draw
        S       46
        mov     ecx, [pg_x]
        add     ecx, eax
        mov     [edit_sx], ecx
        S       12
        mov     edx, r13d
        sub     edx, eax
        sub     edx, eax
        mov     [edit_sh], edx
        add     eax, r12d
        mov     [edit_sy], eax
        S       46
        mov     ecx, ebx
        sub     ecx, eax
        S       16
        sub     ecx, eax
        mov     [edit_sw], ecx
        or      dword [edit_want], 1
        HIT     dword [pg_x], r12d, ebx, r13d, H_SEARCHBOX, 0
        add     r12d, r13d
        S       28
        add     r12d, eax
        cmp     qword [lst_search_t+LS_COUNT], 0
        jne     .res
        cmp     qword [lst_search_a+LS_COUNT], 0
        jne     .res
        cmp     qword [lst_search_p+LS_COUNT], 0
        jne     .res
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        S       28
        TXTL    w_search_none, dword [pg_x], r12d, dword [pg_w], eax
        mov     eax, r12d
        S       40
        add     eax, r12d
        jmp     .end
.res:   cmp     qword [lst_search_t+LS_COUNT], 0
        je      .alb
        lea     rcx, [w_songs]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        lea     rcx, [lst_search_t]
        mov     edx, SRC_SEARCH_T
        mov     r8d, [pg_x]
        mov     r9d, r12d
        mov     eax, [pg_w]
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        call    draw_tracks
        mov     r12d, eax
        S       20
        add     r12d, eax
.alb:   cmp     qword [lst_search_a+LS_COUNT], 0
        je      .pls
        lea     rcx, [w_albums]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        lea     rcx, [lst_search_a]
        mov     edx, SRC_SEARCH_A
        mov     r8d, [pg_x]
        mov     r9d, r12d
        mov     eax, [pg_w]
        mov     outarg(5), rax
        mov     qword outarg(6), 6
        call    draw_cards
        mov     r12d, eax
        S       20
        add     r12d, eax
.pls:   cmp     qword [lst_search_p+LS_COUNT], 0
        je      .art
        lea     rcx, [w_playlists]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        lea     rcx, [lst_search_p]
        mov     edx, SRC_SEARCH_P
        mov     r8d, [pg_x]
        mov     r9d, r12d
        mov     eax, [pg_w]
        mov     outarg(5), rax
        mov     qword outarg(6), 6
        call    draw_cards
        mov     r12d, eax
        S       20
        add     r12d, eax
.art:   cmp     qword [lst_search_r+LS_COUNT], 0
        je      .fin
        lea     rcx, [w_artists]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        lea     rcx, [lst_search_r]
        mov     edx, SRC_SEARCH_R
        mov     r8d, [pg_x]
        mov     r9d, r12d
        mov     eax, [pg_w]
        mov     outarg(5), rax
        mov     qword outarg(6), 6
        call    draw_cards
        mov     r12d, eax
.fin:   mov     eax, r12d
.end:   call    page_end
        EPROC

; ---------------------------------------------------------------- Library
PROC page_library, 4
        call    page_begin
        mov     r12d, eax
        lea     rcx, [w_library]
        call    page_title_at
        mov     r12d, eax
        mov     r13d, [pg_x]
        S       10
        mov     r14d, eax
        ; tabs
        lea     rcx, [w_tab_pl]
        mov     edx, r13d
        mov     r8d, r12d
        xor     r9d, r9d
        cmp     dword [lib_tab], 0
        sete    r9b
        mov     qword outarg(5), H_TAB
        mov     qword outarg(6), 0
        call    draw_pill
        lea     r13d, [r13+rax]
        add     r13d, r14d
        lea     rcx, [w_tab_liked]
        mov     edx, r13d
        mov     r8d, r12d
        xor     r9d, r9d
        cmp     dword [lib_tab], 1
        sete    r9b
        mov     qword outarg(5), H_TAB
        mov     qword outarg(6), 1
        call    draw_pill
        lea     r13d, [r13+rax]
        add     r13d, r14d
        lea     rcx, [w_tab_albums]
        mov     edx, r13d
        mov     r8d, r12d
        xor     r9d, r9d
        cmp     dword [lib_tab], 2
        sete    r9b
        mov     qword outarg(5), H_TAB
        mov     qword outarg(6), 2
        call    draw_pill
        S       36
        add     r12d, eax
        S       24
        add     r12d, eax
        mov     eax, [lib_tab]
        cmp     eax, 1
        je      .liked
        cmp     eax, 2
        je      .albums
        lea     rcx, [lst_playlists]
        mov     edx, SRC_PLAYLISTS
        jmp     .cards
.albums:
        lea     rcx, [lst_albums]
        mov     edx, SRC_ALBUMS
.cards: mov     loc(0), rcx
        mov     loc(1), rdx
        mov     edx, r12d
        call    draw_empty_hint
        mov     r12d, eax
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        mov     r8d, [pg_x]
        mov     r9d, r12d
        mov     eax, [pg_w]
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        call    draw_cards
        jmp     .end
.liked: lea     rcx, [lst_liked]
        mov     edx, r12d
        call    draw_empty_hint
        mov     r12d, eax
        lea     rcx, [lst_liked]
        mov     edx, SRC_LIKED
        mov     r8d, [pg_x]
        mov     r9d, r12d
        mov     eax, [pg_w]
        mov     outarg(5), rax
        mov     qword outarg(6), 1
        call    draw_tracks
.end:   call    page_end
        EPROC

; ---------------------------------------------------------------- Detail (playlist / album)
PROC page_detail, 8
        call    page_begin
        mov     r12d, eax
        S       40
        mov     ebx, eax
        SETCOL  T_FG
        IBTN    ic_back, dword [pg_x], r12d, ebx, H_BACK, 0, 20, 0, 0
        S       52
        add     r12d, eax
        S       220
        mov     r13d, eax                       ; cover size
        mov     rcx, [det_img]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, r13d
        S       12
        mov     outarg(5), rax
        call    draw_cover
        S       28
        mov     r14d, [pg_x]
        add     r14d, r13d
        add     r14d, eax                       ; text x
        mov     r15d, [pg_w]
        sub     r15d, r13d
        sub     r15d, eax                       ; text width
        ; vertical placement: caption / title / sub / play button, bottom aligned to the cover
        S       24
        mov     esi, eax                        ; caption height
        SETFONT F_CAPTION
        SETCOL  T_MUTED_FG
        lea     rcx, [w_cap_playlist]
        cmp     dword [det_kind], KIND_ALBUM
        jne     .cap1
        lea     rcx, [w_cap_album]
.cap1:  cmp     dword [det_kind], KIND_ARTIST
        jne     .cap
        lea     rcx, [w_cap_artist]
.cap:   S       24
        mov     edx, r14d
        mov     r8d, r12d
        add     r8d, r13d
        S       176
        sub     r8d, eax
        mov     r9d, r15d
        S       24
        mov     outarg(5), rax
        call    gfx_text
        SETFONT F_HERO
        SETCOL  T_FG
        S       64
        mov     edi, eax
        S       152
        mov     r8d, r12d
        add     r8d, r13d
        sub     r8d, eax
        mov     rcx, [det_title]
        mov     edx, r14d
        mov     r9d, r15d
        mov     outarg(5), rdi
        call    gfx_text
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        S       28
        mov     edi, eax
        S       88
        mov     r8d, r12d
        add     r8d, r13d
        sub     r8d, eax
        mov     rcx, [det_sub]
        mov     edx, r14d
        mov     r9d, r15d
        mov     outarg(5), rdi
        call    gfx_text
        ; Play button
        S       56
        mov     esi, eax
        mov     r8d, r12d
        add     r8d, r13d
        sub     r8d, esi
        mov     ebx, r8d                        ; button y
        lea     rcx, [ic_play]
        mov     edx, r14d
        mov     r9d, esi
        S       24
        mov     outarg(7), rax
        mov     eax, H_DETAIL_PLAY
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        mov     eax, T_PRIMARY+1
        mov     outarg(8), rax
        mov     eax, T_PRIMARY_FG+1
        mov     outarg(9), rax
        mov     r8d, ebx
        call    draw_icon_button
        cmp     dword [det_kind], KIND_ALBUM    ; (saving a playlist = following it; its own heart would delete the user's playlists)
        jne     .plbuttons
        S       44
        mov     r8d, eax                        ; heart box
        S       16
        lea     ecx, [r14+rsi]
        add     ecx, eax
        mov     edx, esi
        sub     edx, r8d
        shr     edx, 1
        add     edx, ebx
        mov     r9d, 0xFFFE0000                 ; the open album
        mov     rax, [det_uri]
        mov     outarg(5), rax
        mov     qword outarg(6), 1
        call    draw_heart
        jmp     .noheart
.plbuttons:
        test    dword [det_flags], CF_MINE      ; only playlists we own can be edited or deleted
        jz      .noheart
        S       16
        lea     edi, [r14+rsi]
        add     edi, eax                        ; x of the first button
        S       40
        mov     ecx, eax                        ; button height
        sub     esi, ecx
        shr     esi, 1
        add     esi, ebx                        ; y (centred on the play button)
        lea     rcx, [w_edit_btn]
        mov     edx, edi
        mov     r8d, esi
        S       92
        mov     r9d, eax
        S       40
        mov     outarg(5), rax
        mov     qword outarg(6), H_DET_EDIT
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
        S       92
        lea     edi, [rdi+rax]
        S       10
        add     edi, eax
        lea     rcx, [w_delete_btn]
        mov     edx, edi
        mov     r8d, esi
        S       100
        mov     r9d, eax
        S       40
        mov     outarg(5), rax
        mov     qword outarg(6), H_DET_DELETE
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
.noheart:
        S       24
        add     r12d, r13d
        add     r12d, eax
        cmp     dword [det_kind], KIND_ARTIST
        jne     .notartist
        lea     rcx, [w_tab_albums]             ; an artist page: the albums as cards
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        lea     rcx, [lst_dalbums]
        mov     edx, r12d
        call    draw_empty_hint
        mov     r12d, eax
        lea     rcx, [lst_dalbums]
        mov     edx, SRC_DALBUMS
        mov     r8d, [pg_x]
        mov     r9d, r12d
        mov     eax, [pg_w]
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        call    draw_cards
        call    page_end
        jmp     .done
.notartist:
        cmp     qword [det_msg], 0
        je      .tracks
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        SETALIGN 0
        mov     rcx, [det_msg]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        S       28
        mov     outarg(5), rax
        call    gfx_text
        S       60
        add     r12d, eax
        mov     eax, r12d
        call    page_end
        jmp     .done
.tracks:
        lea     rcx, [lst_detail]
        mov     edx, r12d
        call    draw_empty_hint
        mov     r12d, eax
        lea     rcx, [lst_detail]
        mov     edx, SRC_DETAIL
        mov     r8d, [pg_x]
        mov     r9d, r12d
        mov     eax, [pg_w]
        mov     outarg(5), rax
        mov     qword outarg(6), 1
        call    draw_tracks
        call    page_end
.done:  EPROC

; ---------------------------------------------------------------- shared setup widgets
; Draws a rounded input surface and registers where the native EDIT must sit.
; ecx = x, edx = y, r8d = w, r9d = h, [rbp+48] = which edit (1 client, 2 port)
PROC draw_edit_frame, 4
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        SETCOL  T_SURFACE
        mov     eax, dword loc(3)
        shr     eax, 1
        mov     outarg(5), rax
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        call    gfx_rrect
        S       14                              ; inner padding
        mov     r12d, eax
        mov     ecx, dword loc(0)
        add     ecx, r12d                       ; edit x
        S       22                              ; one line of text
        mov     r13d, dword loc(3)
        sub     r13d, eax
        jns     .vpad
        xor     r13d, r13d
.vpad:  shr     r13d, 1                         ; vertical padding = (frame - line) / 2
        mov     edx, dword loc(1)
        add     edx, r13d                       ; edit y
        mov     r8d, dword loc(2)
        sub     r8d, r12d
        sub     r8d, r12d                       ; edit w
        mov     r9d, dword loc(3)
        sub     r9d, r13d
        sub     r9d, r13d                       ; edit h
        mov     eax, stk5
        cmp     eax, 2
        je      .port
        cmp     eax, 4
        je      .dn
        cmp     eax, 5
        je      .dd
        mov     [edit_cx], ecx
        mov     [edit_cy], edx
        mov     [edit_cw], r8d
        mov     [edit_ch], r9d
        or      dword [edit_want], 2
        jmp     .out
.port:  mov     [edit_px], ecx
        mov     [edit_py], edx
        mov     [edit_pw], r8d
        mov     [edit_ph], r9d
        or      dword [edit_want], 4
        jmp     .out
.dn:    mov     [edit_dnx], ecx
        mov     [edit_dnx+4], edx
        mov     [edit_dnx+8], r8d
        mov     [edit_dnx+12], r9d
        or      dword [edit_want], 8
        jmp     .out
.dd:    mov     [edit_ddx], ecx
        mov     [edit_ddx+4], edx
        mov     [edit_ddx+8], r8d
        mov     [edit_ddx+12], r9d
        or      dword [edit_want], 16
.out:   EPROC

; The redirect URI in a box with a Copy button.  ecx = x, edx = y, r8d = w -> eax = y below
PROC draw_uri_row, 6
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        S       44
        mov     loc(3), rax                     ; height
        SETCOL  T_SURFACE
        mov     eax, dword loc(3)
        shr     eax, 1
        mov     outarg(5), rax
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        call    gfx_rrect
        S       84                              ; Copy button
        mov     r12d, eax
        S       6
        mov     r13d, eax
        mov     eax, dword loc(0)
        add     eax, dword loc(2)
        sub     eax, r12d
        sub     eax, r13d
        mov     r14d, eax                       ; button x
        mov     eax, dword loc(3)
        sub     eax, r13d
        sub     eax, r13d
        mov     r15d, eax                       ; button height
        mov     rcx, [redir_w]
        test    rcx, rcx
        jz      .btn
        SETFONT F_BODY
        SETCOL  T_FG
        SETALIGN 0
        S       16
        mov     edx, dword loc(0)
        add     edx, eax
        mov     r9d, r14d
        sub     r9d, edx
        sub     r9d, r13d
        mov     r8d, dword loc(1)
        mov     rcx, [redir_w]
        mov     eax, dword loc(3)
        mov     outarg(5), rax
        call    gfx_text
.btn:   lea     rcx, [w_copy]
        mov     edx, r14d
        mov     r8d, dword loc(1)
        add     r8d, r13d
        mov     r9d, r12d
        mov     outarg(5), r15
        mov     qword outarg(6), H_COPY_URI
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
        mov     eax, dword loc(1)
        add     eax, dword loc(3)
        EPROC

; ---------------------------------------------------------------- Settings
PROC page_settings, 8
        call    page_begin
        mov     r12d, eax
        lea     rcx, [w_settings]
        call    page_title_at
        mov     r12d, eax
        lea     rcx, [w_account]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        S       28
        mov     ebx, eax
        cmp     dword [g_demo], 0
        jne     .demo
        mov     rcx, [user_name]
        TXT     rcx, dword [pg_x], r12d, dword [pg_w], ebx
        jmp     .acct
.demo:  TXTL    w_demo_mode, dword [pg_x], r12d, dword [pg_w], ebx
.acct:  add     r12d, ebx
        S       12
        add     r12d, eax
        lea     rcx, [w_signout]
        mov     edx, [pg_x]
        mov     r8d, r12d
        S       140
        mov     r9d, eax
        S       40
        mov     outarg(5), rax
        mov     qword outarg(6), H_SIGNOUT
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
        S       40
        add     r12d, eax
        S       32
        add     r12d, eax
        ; ---- Spotify
        lea     rcx, [w_spotify]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        S       520
        mov     ebx, [pg_w]
        cmp     ebx, eax
        cmova   ebx, eax                        ; field width
        SETFONT F_SMALL_B
        SETCOL  T_MUTED_FG
        S       22
        mov     esi, eax
        TXTL    w_clientid_s, dword [pg_x], r12d, ebx, esi
        add     r12d, esi
        S       46
        mov     edi, eax
        mov     ecx, [pg_x]
        mov     edx, r12d
        mov     r8d, ebx
        mov     r9d, edi
        mov     qword outarg(5), 1
        call    draw_edit_frame
        add     r12d, edi
        S       16
        add     r12d, eax
        SETFONT F_SMALL_B
        SETCOL  T_MUTED_FG
        TXTL    w_redirect_s, dword [pg_x], r12d, ebx, esi
        add     r12d, esi
        mov     ecx, [pg_x]
        mov     edx, r12d
        mov     r8d, ebx
        call    draw_uri_row
        mov     r12d, eax
        S       16
        add     r12d, eax
        ; port field and the dashboard button on one line
        SETFONT F_BODY
        SETCOL  T_FG
        S       60
        mov     r14d, eax
        S       46
        mov     edi, eax
        TXTL    w_port, dword [pg_x], r12d, r14d, edi
        mov     ecx, [pg_x]
        add     ecx, r14d
        mov     edx, r12d
        S       110
        mov     r8d, eax
        mov     r9d, edi
        mov     qword outarg(5), 2
        call    draw_edit_frame
        lea     rcx, [w_open_dash]
        S       194                             ; label (60) + port field (110) + gap (24)
        mov     edx, [pg_x]
        add     edx, eax
        mov     r8d, r12d
        S       170
        mov     r9d, eax
        mov     outarg(5), rdi
        mov     qword outarg(6), H_OPEN_DASH
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
        add     r12d, edi
        S       36
        add     r12d, eax
        lea     rcx, [w_appearance]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        S       8
        add     r12d, eax
        mov     r13d, [pg_x]
        S       10
        mov     r14d, eax
        lea     rcx, [w_theme_dark]
        mov     edx, r13d
        mov     r8d, r12d
        xor     r9d, r9d
        cmp     dword [theme_idx], 0
        sete    r9b
        mov     qword outarg(5), H_THEME
        mov     qword outarg(6), 0
        call    draw_pill
        lea     r13d, [r13+rax]
        add     r13d, r14d
        lea     rcx, [w_theme_mid]
        mov     edx, r13d
        mov     r8d, r12d
        xor     r9d, r9d
        cmp     dword [theme_idx], 1
        sete    r9b
        mov     qword outarg(5), H_THEME
        mov     qword outarg(6), 1
        call    draw_pill
        lea     r13d, [r13+rax]
        add     r13d, r14d
        lea     rcx, [w_theme_light]
        mov     edx, r13d
        mov     r8d, r12d
        xor     r9d, r9d
        cmp     dword [theme_idx], 2
        sete    r9b
        mov     qword outarg(5), H_THEME
        mov     qword outarg(6), 2
        call    draw_pill
        S       36
        add     r12d, eax
        S       36
        add     r12d, eax
        lea     rcx, [w_diag]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        S       26
        mov     ebx, eax
        TXTL    w_diag_hint, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        S       10
        add     r12d, eax
        S       40
        mov     edi, eax
        lea     rcx, [w_open_log]
        mov     edx, [pg_x]
        mov     r8d, r12d
        S       160
        mov     r9d, eax
        mov     outarg(5), rdi
        mov     qword outarg(6), H_OPEN_LOG
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
        lea     rcx, [w_copy_diag]
        S       160
        mov     edx, [pg_x]
        add     edx, eax
        S       12
        add     edx, eax
        mov     r8d, r12d
        S       170
        mov     r9d, eax
        mov     outarg(5), rdi
        mov     qword outarg(6), H_COPY_DIAG
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
        lea     rcx, [w_test_audio]
        S       160
        mov     edx, [pg_x]
        add     edx, eax
        S       12
        add     edx, eax
        S       170
        add     edx, eax
        S       12
        add     edx, eax
        mov     r8d, r12d
        S       130
        mov     r9d, eax
        mov     outarg(5), rdi
        mov     qword outarg(6), H_TEST_AUDIO
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
        add     r12d, edi
        S       36
        add     r12d, eax
        lea     rcx, [w_shortcuts]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        S       26
        mov     ebx, eax
        TXTL    w_sc1, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        TXTL    w_sc2, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        TXTL    w_sc3, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        TXTL    w_sc4, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        TXTL    w_sc5, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        S       30
        add     r12d, eax
        lea     rcx, [w_about]
        mov     edx, [pg_x]
        mov     r8d, r12d
        mov     r9d, [pg_w]
        call    draw_section
        mov     r12d, eax
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        S       26
        mov     ebx, eax
        mov     rcx, [ver_w]
        TXT     rcx, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        TXTL    w_about1, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        TXTL    w_about2, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        TXTL    w_about3, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        TXTL    w_about4, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        TXTL    w_about5, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        mov     eax, r12d
        call    page_end
        EPROC

; ---------------------------------------------------------------- Login / first-run setup
; numbered step heading: rcx = number (UTF-16), rdx = text (UTF-16), r8d = x, r9d = y
PROC draw_step, 4
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        S       28
        mov     r12d, eax
        SETCOL  T_SURFACE
        mov     ecx, dword loc(2)
        mov     edx, dword loc(3)
        mov     r8d, r12d
        mov     r9d, r12d
        call    gfx_ellipse
        SETFONT F_SMALL_B
        SETCOL  T_FG
        SETALIGN 1
        mov     rcx, loc(0)
        mov     edx, dword loc(2)
        mov     r8d, dword loc(3)
        mov     r9d, r12d
        mov     outarg(5), r12
        call    gfx_text
        SETALIGN 0
        SETFONT F_BODY_B
        SETCOL  T_FG
        S       40
        mov     edx, dword loc(2)
        add     edx, eax
        mov     r8d, dword loc(3)
        S       318                             ; leaves room for the button / port field on the right
        mov     r9d, eax
        mov     rcx, loc(1)
        mov     outarg(5), r12
        call    gfx_text
        EPROC

PROC page_login, 12
        call    page_begin
        mov     r12d, eax
        S       520
        mov     ebx, [pg_w]
        cmp     ebx, eax
        cmova   ebx, eax                        ; column width
        mov     r13d, [ui_w]
        sub     r13d, ebx
        shr     r13d, 1                         ; column x
        cmp     dword [scroll_main], 0          ; centre vertically while everything fits
        jne     .start
        S       650
        mov     ecx, [ui_h]
        sub     ecx, eax
        jle     .start
        shr     ecx, 1
        add     r12d, ecx
.start: ; logo
        S       56
        mov     esi, eax
        SETCOL  T_ACCENT
        S       16
        mov     outarg(5), rax
        mov     ecx, r13d
        mov     edx, r12d
        mov     r8d, esi
        mov     r9d, esi
        call    gfx_rrect
        mov     ecx, 0xFFFFFFFF
        call    gfx_color
        S       13
        lea     ecx, [r13+rax]
        lea     edx, [r12+rax]
        mov     r8d, esi
        sub     r8d, eax
        sub     r8d, eax
        lea     r9, [ic_note]
        call    icon_draw
        S       76
        add     r12d, eax
        SETFONT F_H1
        SETCOL  T_FG
        S       44
        TXTL    w_welcome, r13d, r12d, ebx, eax
        S       50
        add     r12d, eax
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        S       24
        TXTL    w_login_sub, r13d, r12d, ebx, eax
        S       44
        add     r12d, eax
        ; step 1: dashboard
        lea     rcx, [w_n1]
        lea     rdx, [w_step1]
        mov     r8d, r13d
        mov     r9d, r12d
        call    draw_step
        lea     rcx, [w_open_dash]
        S       150
        mov     r9d, eax
        mov     edx, r13d
        add     edx, ebx
        sub     edx, eax
        mov     r8d, r12d
        S       36
        mov     outarg(5), rax
        mov     qword outarg(6), H_OPEN_DASH
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
        S       52
        add     r12d, eax
        ; step 2: redirect URI, with the port field at the right of the heading
        lea     rcx, [w_n2]
        lea     rdx, [w_step2]
        mov     r8d, r13d
        mov     r9d, r12d
        call    draw_step
        S       84
        mov     edi, eax                        ; port field width
        S       36
        mov     esi, eax                        ; port field height
        mov     ecx, r13d
        add     ecx, ebx
        sub     ecx, edi                        ; port field x
        mov     edx, r12d
        mov     r8d, edi
        mov     r9d, esi
        mov     qword outarg(5), 2
        mov     dword loc(6), ecx
        call    draw_edit_frame
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        SETALIGN 2
        S       50
        mov     r9d, eax
        S       8
        mov     edx, dword loc(6)
        sub     edx, eax
        sub     edx, r9d                        ; label x
        mov     r8d, r12d
        lea     rcx, [w_port]
        mov     outarg(5), rsi
        call    gfx_text
        SETALIGN 0
        S       48
        add     r12d, eax
        mov     ecx, r13d
        mov     edx, r12d
        mov     r8d, ebx
        call    draw_uri_row
        mov     r12d, eax
        S       24
        add     r12d, eax
        ; step 3: client id
        lea     rcx, [w_n3]
        lea     rdx, [w_step3]
        mov     r8d, r13d
        mov     r9d, r12d
        call    draw_step
        S       40
        add     r12d, eax
        S       46
        mov     edi, eax
        mov     ecx, r13d
        mov     edx, r12d
        mov     r8d, ebx
        mov     r9d, edi
        mov     qword outarg(5), 1
        call    draw_edit_frame
        add     r12d, edi
        S       24
        add     r12d, eax
        cmp     dword [auth_state], AUTH_OUT
        je      .idle
        ; ---- a sign-in is running: status line, and (while waiting for the browser) Copy link / Cancel
        SETFONT F_BODY_B
        SETCOL  T_FG
        lea     rcx, [w_waiting]
        cmp     dword [auth_state], AUTH_WAITING
        je      .stat
        lea     rcx, [w_signing_in]
.stat:  mov     edx, r13d
        mov     r8d, r12d
        mov     r9d, ebx
        S       30
        mov     outarg(5), rax
        call    gfx_text
        S       40
        add     r12d, eax
        cmp     dword [auth_state], AUTH_WAITING
        jne     .busy_end
        S       10
        mov     edi, eax                        ; gap between the two buttons
        mov     esi, ebx
        sub     esi, edi
        shr     esi, 1                          ; half width
        lea     rcx, [w_copy_link]
        mov     edx, r13d
        mov     r8d, r12d
        mov     r9d, esi
        S       44
        mov     outarg(5), rax
        mov     qword outarg(6), H_COPY_AUTH
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
        lea     rcx, [w_cancel]
        lea     edx, [r13+rsi]
        add     edx, edi
        mov     r8d, r12d
        mov     r9d, esi
        S       44
        mov     outarg(5), rax
        mov     qword outarg(6), H_CANCEL_SIGNIN
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
        S       56
        add     r12d, eax
.busy_end:
        S       20
        add     r12d, eax
        jmp     .notes
.idle:  lea     rcx, [w_signin]
        mov     edx, r13d
        mov     r8d, r12d
        mov     r9d, ebx
        S       48
        mov     outarg(5), rax
        mov     qword outarg(6), H_SIGNIN
        mov     qword outarg(7), 0
        mov     qword outarg(8), 0
        call    draw_button
        S       58
        add     r12d, eax
        lea     rcx, [w_demo_btn]
        mov     edx, r13d
        mov     r8d, r12d
        mov     r9d, ebx
        S       44
        mov     outarg(5), rax
        mov     qword outarg(6), H_DEMO
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
        S       62
        add     r12d, eax
.notes: SETFONT F_CAPTION
        SETCOL  T_MUTED_FG
        S       18
        mov     esi, eax
        TXTL    w_login_note1, r13d, r12d, ebx, esi
        add     r12d, esi
        TXTL    w_login_note2, r13d, r12d, ebx, esi
        add     r12d, esi
        mov     eax, r12d
        call    page_end
        EPROC
