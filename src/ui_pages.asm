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
WSTR w_about1, "ByteStream for Windows, written in x86-64 assembly."
WSTR w_about2, "Playback uses the official Spotify Web Playback SDK and needs Spotify Premium."
WSTR w_about3, "Not affiliated with Spotify. Spotify is a trademark of Spotify AB."
WSTR w_play, "Play"
WSTR w_cap_playlist, "PLAYLIST"
WSTR w_cap_album, "ALBUM"
WSTR w_welcome, "Welcome to ByteStream"
WSTR w_login_sub, "Listen to your Spotify library in a fast, native player."
WSTR w_clientid_lbl, "Spotify client ID"
WSTR w_signin, "Sign in with Spotify"
WSTR w_demo_btn, "Try the demo"
WSTR w_login_hint1, "Create a free app at developer.spotify.com/dashboard and add"
WSTR w_login_hint2, "http://127.0.0.1:8989/callback as a redirect URI, then paste its client ID."
WSTR w_login_hint3, "Playback needs a Spotify Premium account."
WSTR w_loading, "Loading..."
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
        mov     [pg_y], eax
        HIT     dword [lay_main_x], 0, dword [lay_main_w], dword [lay_main_h], H_SHELL, 0
        mov     eax, [pg_y]
        EPROC

; eax = y after the last element: records the content height and clamps the scroll position
PROC page_end, 0
        add     eax, [scroll_main]
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
        EPROC

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
.cards: mov     r8d, [pg_x]
        mov     r9d, r12d
        mov     eax, [pg_w]
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        call    draw_cards
        jmp     .end
.liked: lea     rcx, [lst_liked]
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
        jne     .cap
        lea     rcx, [w_cap_album]
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
        S       24
        add     r12d, r13d
        add     r12d, eax
        lea     rcx, [lst_detail]
        mov     edx, SRC_DETAIL
        mov     r8d, [pg_x]
        mov     r9d, r12d
        mov     eax, [pg_w]
        mov     outarg(5), rax
        mov     qword outarg(6), 1
        call    draw_tracks
        call    page_end
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
        ; "Signed in as <name>"
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
        TXTL    w_about1, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        TXTL    w_about2, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        TXTL    w_about3, dword [pg_x], r12d, dword [pg_w], ebx
        add     r12d, ebx
        mov     eax, r12d
        call    page_end
        EPROC

; ---------------------------------------------------------------- Login
PROC page_login, 8
        xor     ecx, ecx
        xor     edx, edx
        mov     r8d, [ui_w]
        mov     r9d, [ui_h]
        call    ui_clip
        HIT     0, 0, dword [ui_w], dword [ui_h], H_SHELL, 0
        S       460
        mov     ebx, [ui_w]
        cmp     ebx, eax
        cmova   ebx, eax
        S       24
        sub     ebx, eax
        sub     ebx, eax                        ; column width
        cmp     ebx, 0
        jg      .w
        mov     ebx, 100
.w:     mov     r13d, [ui_w]
        sub     r13d, ebx
        shr     r13d, 1                         ; column x
        S       500
        mov     r12d, [ui_h]
        sub     r12d, eax
        shr     r12d, 1                         ; column y
        S       24
        cmp     r12d, eax
        jge     .y
        mov     r12d, eax
.y:     ; logo
        S       64
        mov     esi, eax
        SETCOL  T_ACCENT
        S       18
        mov     outarg(5), rax
        mov     ecx, r13d
        mov     edx, r12d
        mov     r8d, esi
        mov     r9d, esi
        call    gfx_rrect
        mov     ecx, 0xFFFFFFFF
        call    gfx_color
        S       14
        lea     ecx, [r13+rax]
        lea     edx, [r12+rax]
        mov     r8d, esi
        sub     r8d, eax
        sub     r8d, eax
        lea     r9, [ic_note]
        call    icon_draw
        S       88
        add     r12d, eax
        SETFONT F_H1
        SETCOL  T_FG
        S       48
        TXTL    w_welcome, r13d, r12d, ebx, eax
        S       54
        add     r12d, eax
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        S       26
        TXTL    w_login_sub, r13d, r12d, ebx, eax
        S       56
        add     r12d, eax
        SETFONT F_SMALL_B
        SETCOL  T_FG
        S       22
        TXTL    w_clientid_lbl, r13d, r12d, ebx, eax
        S       26
        add     r12d, eax
        ; client id box
        S       46
        mov     r14d, eax
        SETCOL  T_SURFACE
        mov     eax, r14d
        shr     eax, 1
        mov     outarg(5), rax
        mov     ecx, r13d
        mov     edx, r12d
        mov     r8d, ebx
        mov     r9d, r14d
        call    gfx_rrect
        S       18
        lea     ecx, [r13+rax]
        mov     [edit_cx], ecx
        S       12
        lea     edx, [r12+rax]
        mov     [edit_cy], edx
        mov     eax, r14d
        S       12
        mov     ecx, eax
        mov     eax, r14d
        sub     eax, ecx
        sub     eax, ecx
        mov     [edit_ch], eax
        S       36
        mov     ecx, ebx
        sub     ecx, eax
        mov     [edit_cw], ecx
        or      dword [edit_want], 2
        add     r12d, r14d
        S       18
        add     r12d, eax
        lea     rcx, [w_signin]
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
        S       66
        add     r12d, eax
        SETFONT F_CAPTION
        SETCOL  T_MUTED_FG
        S       18
        mov     esi, eax
        TXTL    w_login_hint1, r13d, r12d, ebx, esi
        add     r12d, esi
        TXTL    w_login_hint2, r13d, r12d, ebx, esi
        add     r12d, esi
        TXTL    w_login_hint3, r13d, r12d, ebx, esi
        call    ui_unclip
        EPROC
