; ui_chrome.asm - the persistent window furniture: sidebar, player bar, queue panel, full-screen view.

section .bss
seek_x:         resd 1                  ; geometry of the seek / volume bars painted last (for dragging)
seek_w:         resd 1
vol_x:          resd 1
vol_w:          resd 1

section .data
WSTR w_app, "ByteStream"
WSTR w_nav_home, "Home"
WSTR w_nav_search, "Search"
WSTR w_nav_library, "Library"
WSTR w_nav_settings, "Settings"
WSTR w_playlists_cap, "PLAYLISTS"
WSTR w_nothing, "Nothing playing"
WSTR w_pick, "Pick something to play"
WSTR w_queue, "Queue"
WSTR w_now_playing, "Now playing"
WSTR w_next_up, "Next up"
WSTR w_queue_empty, "Nothing queued"
WSTR w_np_cap, "NOW PLAYING"
WSTR w_zero_time, "0:00"

section .text

; ---------------------------------------------------------------- sidebar
; rcx = icon program, rdx = label, r8d = page, r9d = y
PROC draw_nav_item, 8
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        S       12
        mov     loc(4), rax                     ; x
        mov     eax, [lay_sb_w]
        mov     ecx, dword loc(4)
        shl     ecx, 1
        sub     eax, ecx
        mov     loc(5), rax                     ; w
        MET     eax, M_NAV
        mov     loc(6), rax                     ; h
        xor     ebx, ebx                        ; selected?
        mov     eax, [page]
        cmp     eax, dword loc(2)
        sete    bl
        test    ebx, ebx
        jz      .nosel
        SETCOL  T_SIDEBAR_ACC
        jmp     .bg
.nosel: mov     ecx, H_NAV
        mov     edx, dword loc(2)
        call    anim_hv
        imul    eax, 0x40
        shr     eax, 8
        jz      .nobg
        SETCOL_AR T_SIDEBAR_ACC, eax
.bg:    S       8
        mov     outarg(5), rax
        mov     ecx, dword loc(4)
        mov     edx, dword loc(3)
        mov     r8d, dword loc(5)
        mov     r9d, dword loc(6)
        call    gfx_rrect
.nobg:  test    ebx, ebx
        jz      .dim
        SETCOL  T_FG
        jmp     .ic
.dim:   SETCOL  T_MUTED_FG
.ic:    S       20
        mov     r12d, eax                       ; icon size
        mov     eax, dword loc(6)
        sub     eax, r12d
        shr     eax, 1
        add     eax, dword loc(3)
        mov     edx, eax
        S       14
        add     eax, dword loc(4)
        mov     ecx, eax
        mov     r8d, r12d
        mov     r9, loc(0)
        call    icon_draw
        SETFONT F_BODY_B
        S       46
        add     eax, dword loc(4)
        mov     edx, eax
        mov     rcx, loc(1)
        mov     r8d, dword loc(3)
        mov     r9d, dword loc(5)
        sub     r9d, 46
        mov     eax, dword loc(6)
        mov     outarg(5), rax
        call    gfx_text
        mov     eax, H_NAV
        mov     [rsp+32], rax
        mov     eax, dword loc(2)
        mov     [rsp+40], rax
        mov     ecx, dword loc(4)
        mov     edx, dword loc(3)
        mov     r8d, dword loc(5)
        mov     r9d, dword loc(6)
        call    hit_add
        EPROC

PROC paint_sidebar, 12
        mov     eax, [lay_sb_w]
        mov     loc(0), rax
        mov     eax, [lay_bar_y]
        mov     loc(1), rax
        SETCOL  T_SIDEBAR
        RECT    0, 0, dword loc(0), dword loc(1)
        SETCOL  T_SIDEBAR_BORDER
        mov     ecx, dword loc(0)
        dec     ecx
        RECT    ecx, 0, 1, dword loc(1)
        HIT     0, 0, dword loc(0), dword loc(1), H_SHELL, 0
        ; logo
        S       20
        mov     r12d, eax
        S       32
        mov     r13d, eax
        SETCOL  T_ACCENT
        S       9
        mov     outarg(5), rax
        mov     ecx, r12d
        mov     edx, r12d
        mov     r8d, r13d
        mov     r9d, r13d
        call    gfx_rrect
        mov     ecx, 0xFFFFFFFF
        call    gfx_color
        S       6
        lea     ecx, [r12+rax]
        lea     edx, [r12+rax]
        mov     r8d, r13d
        sub     r8d, eax
        sub     r8d, eax
        lea     r9, [ic_note]
        call    icon_draw
        SETFONT F_H2
        SETCOL  T_FG
        S       62
        mov     edx, eax
        TXTL    w_app, edx, r12d, 140, r13d
        ; navigation
        S       80
        mov     r14d, eax
        MET     r15d, M_NAV
        S       2
        add     r15d, eax
        lea     rcx, [ic_home]
        lea     rdx, [w_nav_home]
        mov     r8d, PAGE_HOME
        mov     r9d, r14d
        call    draw_nav_item
        add     r14d, r15d
        lea     rcx, [ic_search]
        lea     rdx, [w_nav_search]
        mov     r8d, PAGE_SEARCH
        mov     r9d, r14d
        call    draw_nav_item
        add     r14d, r15d
        lea     rcx, [ic_lib]
        lea     rdx, [w_nav_library]
        mov     r8d, PAGE_LIBRARY
        mov     r9d, r14d
        call    draw_nav_item
        add     r14d, r15d
        lea     rcx, [ic_sliders]
        lea     rdx, [w_nav_settings]
        mov     r8d, PAGE_SETTINGS
        mov     r9d, r14d
        call    draw_nav_item
        add     r14d, r15d
        ; PLAYLISTS caption
        S       22
        add     r14d, eax
        SETFONT F_CAPTION
        SETCOL  T_HEAD_FG
        S       20
        mov     edx, eax
        S       18
        TXTL    w_playlists_cap, edx, r14d, 160, eax
        S       32
        mov     ebx, eax                        ; "+" button box
        S       12
        mov     esi, dword loc(0)
        sub     esi, eax
        sub     esi, ebx                        ; x
        S       7
        mov     edi, r14d
        sub     edi, eax                        ; y
        S       16
        mov     r15d, eax                       ; icon size
        SETCOL  T_MUTED_FG
        IBTN    ic_plus, esi, edi, ebx, H_NEW_PL, 0, r15d, 0, 0
        S       24
        add     r14d, eax
        ; scrolling list
        mov     eax, dword loc(1)
        S       12
        mov     ecx, eax
        mov     eax, dword loc(1)
        sub     eax, ecx
        sub     eax, r14d                       ; viewport height
        mov     r13d, eax
        MET     ebx, M_SROW
        mov     rax, [lst_playlists+LS_COUNT]
        imul    eax, ebx
        mov     [side_h], eax
        sub     eax, r13d                       ; clamp scroll
        jns     .mx
        xor     eax, eax
.mx:    cmp     [scroll_side], eax
        jle     .scl
        mov     [scroll_side], eax
.scl:   cmp     dword [scroll_side], 0
        jge     .clip
        mov     dword [scroll_side], 0
.clip:  mov     ecx, 0
        mov     edx, r14d
        mov     r8d, dword loc(0)
        dec     r8d
        mov     r9d, r13d
        call    ui_clip
        xor     r12d, r12d
.pl:    cmp     r12, [lst_playlists+LS_COUNT]
        jae     .end
        mov     eax, ebx
        imul    eax, r12d
        add     eax, r14d
        sub     eax, [scroll_side]
        mov     loc(2), rax                     ; row y
        lea     ecx, [rax+rbx]
        cmp     ecx, r14d
        jle     .nx
        mov     ecx, r14d
        add     ecx, r13d
        cmp     eax, ecx
        jge     .end
        mov     rax, r12
        imul    rax, CD_SIZE
        add     rax, [lst_playlists+LS_PTR]
        mov     rsi, rax
        S       12
        mov     loc(3), rax                     ; x pad
        ; highlight selected or hovered
        xor     edi, edi
        cmp     dword [page], PAGE_DETAIL
        jne     .nsel
        cmp     dword [detail_sel], r12d
        sete    dil
.nsel:  test    edi, edi
        jz      .nhv
        SETCOL  T_SIDEBAR_ACC
        jmp     .fillrow
.nhv:   mov     ecx, H_SIDE_PL
        mov     edx, r12d
        call    anim_hv
        imul    eax, 0x40
        shr     eax, 8
        jz      .cover
        SETCOL_AR T_SIDEBAR_ACC, eax
.fillrow:
        mov     eax, dword loc(0)
        mov     ecx, dword loc(3)
        shl     ecx, 1
        sub     eax, ecx
        mov     r8d, eax
        mov     ecx, dword loc(3)
        mov     edx, dword loc(2)
        mov     r9d, ebx
        mov     qword outarg(5), 8
        call    gfx_rrect
.cover: S       26
        mov     r15d, eax
        mov     edx, dword loc(3)
        S       8
        add     edx, eax
        mov     eax, ebx
        sub     eax, r15d
        shr     eax, 1
        add     eax, dword loc(2)
        mov     r8d, eax
        mov     r9d, r15d
        mov     rcx, [rsi+CD_IMG_M]
        mov     qword outarg(5), 5
        call    draw_cover
        SETFONT F_BODY
        SETCOL  T_FG
        S       8
        mov     edx, dword loc(3)
        add     edx, eax
        add     edx, r15d
        S       10
        add     edx, eax
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(0)
        sub     r9d, edx
        S       12
        sub     r9d, eax
        mov     rcx, [rsi+CD_NAME]
        mov     eax, ebx
        mov     outarg(5), rax
        call    gfx_text
        mov     eax, H_SIDE_PL
        mov     [rsp+32], rax
        mov     eax, r12d
        mov     [rsp+40], rax
        mov     ecx, 0
        mov     edx, dword loc(2)
        mov     r8d, dword loc(0)
        mov     r9d, ebx
        call    hit_add
.nx:    inc     r12
        jmp     .pl
.end:   call    ui_unclip
        EPROC

; ---------------------------------------------------------------- shared control painters
; ecx = x, edx = y (centre line), r8d = width : seek bar for the current track
PROC draw_seekbar, 10
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     [seek_x], ecx
        mov     [seek_w], r8d
        ; position fraction in 1/1000ths
        call    np_position
        mov     ebx, eax
        cmp     dword [drag_id], H_SEEK
        jne     .frac
        mov     eax, [np_dur]
        imul    eax, [drag_frac]
        xor     edx, edx
        mov     ecx, 1000
        div     ecx
        mov     ebx, eax
.frac:  xor     esi, esi
        mov     ecx, [np_dur]
        test    ecx, ecx
        jz      .have
        mov     eax, ebx
        imul    rax, 1000
        xor     edx, edx
        div     rcx
        mov     esi, eax
        cmp     esi, 1000
        jbe     .have
        mov     esi, 1000
.have:  S       4
        mov     r12d, eax                       ; track thickness
        mov     r13d, dword loc(1)
        mov     eax, r12d
        shr     eax, 1
        sub     r13d, eax                       ; track y
        SETCOL  T_TRACK
        mov     eax, r12d
        shr     eax, 1
        mov     outarg(5), rax
        mov     ecx, dword loc(0)
        mov     edx, r13d
        mov     r8d, dword loc(2)
        mov     r9d, r12d
        call    gfx_rrect
        mov     eax, dword loc(2)
        imul    eax, esi
        xor     edx, edx
        mov     ecx, 1000
        div     ecx
        mov     r14d, eax                       ; filled width
        cmp     r14d, r12d
        jae     .fw
        mov     r14d, r12d
.fw:    xor     edi, edi                        ; hot?
        cmp     dword [hover_id], H_SEEK
        je      .hot
        cmp     dword [drag_id], H_SEEK
        jne     .col
.hot:   mov     edi, 1
.col:   SETCOL  T_PROGRESS
        mov     eax, r12d
        shr     eax, 1
        mov     outarg(5), rax
        mov     ecx, dword loc(0)
        mov     edx, r13d
        mov     r8d, r14d
        mov     r9d, r12d
        call    gfx_rrect
        test    edi, edi
        jz      .hit
        S       12
        mov     r15d, eax
        shr     eax, 1
        mov     ecx, dword loc(0)
        add     ecx, r14d
        sub     ecx, eax
        mov     edx, dword loc(1)
        sub     edx, eax
        mov     r8d, r15d
        mov     r9d, r15d
        call    gfx_ellipse
.hit:   S       10
        mov     ecx, dword loc(1)
        sub     ecx, eax
        shl     eax, 1
        mov     r9d, eax
        mov     edx, ecx
        mov     ecx, dword loc(0)
        mov     r8d, dword loc(2)
        mov     qword [rsp+32], H_SEEK
        mov     qword [rsp+40], 0
        call    hit_add
        EPROC

; ecx = x, edx = y (centre line), r8d = width : volume slider
PROC draw_volume, 10
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     [vol_x], ecx
        mov     [vol_w], r8d
        S       4
        mov     r12d, eax
        mov     r13d, dword loc(1)
        shr     eax, 1
        sub     r13d, eax
        SETCOL  T_TRACK
        mov     eax, r12d
        shr     eax, 1
        mov     outarg(5), rax
        mov     ecx, dword loc(0)
        mov     edx, r13d
        mov     r8d, dword loc(2)
        mov     r9d, r12d
        call    gfx_rrect
        mov     eax, dword loc(2)
        imul    eax, [np_vol]
        xor     edx, edx
        mov     ecx, 100
        div     ecx
        mov     r14d, eax
        cmp     r14d, r12d
        jae     .fw
        mov     r14d, r12d
.fw:    SETCOL  T_PROGRESS
        mov     eax, r12d
        shr     eax, 1
        mov     outarg(5), rax
        mov     ecx, dword loc(0)
        mov     edx, r13d
        mov     r8d, r14d
        mov     r9d, r12d
        call    gfx_rrect
        cmp     dword [hover_id], H_VOL
        je      .knob
        cmp     dword [drag_id], H_VOL
        jne     .hit
.knob:  S       12
        mov     r15d, eax
        shr     eax, 1
        mov     ecx, dword loc(0)
        add     ecx, r14d
        sub     ecx, eax
        mov     edx, dword loc(1)
        sub     edx, eax
        mov     r8d, r15d
        mov     r9d, r15d
        call    gfx_ellipse
.hit:   S       10
        mov     edx, dword loc(1)
        sub     edx, eax
        shl     eax, 1
        mov     r9d, eax
        mov     ecx, dword loc(0)
        mov     r8d, dword loc(2)
        mov     qword [rsp+32], H_VOL
        mov     qword [rsp+40], 0
        call    hit_add
        EPROC

; ecx = centre x, edx = top y, r8d = small button box, r9d = play button box
PROC draw_transport, 12
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        mov     r12d, r8d
        shr     r12d, 2                         ; gap
        mov     eax, r8d
        shl     eax, 2
        add     eax, r9d
        lea     eax, [rax+r12*4]
        shr     eax, 1
        sub     ecx, eax
        mov     r13d, ecx                       ; running x
        mov     eax, r9d
        sub     eax, r8d
        shr     eax, 1
        add     eax, edx
        mov     r14d, eax                       ; y of small buttons
        mov     eax, r8d
        mov     ecx, 55
        mul     ecx
        mov     ecx, 100
        div     ecx
        mov     r15d, eax                       ; small icon size
        ; shuffle
        cmp     dword [np_shuffle], 0
        je      .sh0
        SETCOL  T_PRIMARY
        jmp     .sh1
.sh0:   SETCOL  T_MUTED_FG
.sh1:   IBTN    ic_shuffle, r13d, r14d, dword loc(2), H_SHUFFLE, 0, r15d, 0, 0
        cmp     dword [np_shuffle], 0
        je      .sh2
        SETCOL  T_PRIMARY
        S       3
        mov     r8d, eax
        mov     r9d, eax
        mov     ecx, r13d
        mov     eax, dword loc(2)
        shr     eax, 1
        add     ecx, eax
        sub     ecx, 1
        mov     edx, r14d
        add     edx, dword loc(2)
        call    gfx_ellipse
.sh2:   mov     eax, dword loc(2)
        add     eax, r12d
        add     r13d, eax
        ; previous
        SETCOL  T_FG
        IBTN    ic_prev, r13d, r14d, dword loc(2), H_PREV, 0, r15d, 0, 0
        mov     eax, dword loc(2)
        add     eax, r12d
        add     r13d, eax
        ; play / pause
        mov     eax, dword loc(3)
        mov     ecx, 42
        mul     ecx
        mov     ecx, 100
        div     ecx
        mov     r15d, eax
        mov     ebx, T_PRIMARY_FG+1
        lea     rsi, [ic_play]
        cmp     dword [np_valid], 0
        je      .pp
        cmp     dword [np_paused], 0
        jne     .pp
        lea     rsi, [ic_pause]
.pp:    mov     r8d, dword loc(1)
        mov     eax, T_PRIMARY+1
        mov     outarg(8), rax
        mov     eax, ebx
        mov     outarg(9), rax
        mov     eax, H_PLAY
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        mov     eax, r15d
        mov     outarg(7), rax
        mov     rcx, rsi
        mov     edx, r13d
        mov     r9d, dword loc(3)
        call    draw_icon_button
        mov     eax, dword loc(3)
        add     eax, r12d
        add     r13d, eax
        ; next
        mov     eax, dword loc(2)
        mov     ecx, 55
        mul     ecx
        mov     ecx, 100
        div     ecx
        mov     r15d, eax
        SETCOL  T_FG
        IBTN    ic_next, r13d, r14d, dword loc(2), H_NEXT, 0, r15d, 0, 0
        mov     eax, dword loc(2)
        add     eax, r12d
        add     r13d, eax
        ; repeat
        cmp     dword [np_repeat], 0
        je      .rp0
        SETCOL  T_PRIMARY
        jmp     .rp1
.rp0:   SETCOL  T_MUTED_FG
.rp1:   IBTN    ic_repeat, r13d, r14d, dword loc(2), H_REPEAT, 0, r15d, 0, 0
        cmp     dword [np_repeat], 0
        je      .done
        SETCOL  T_PRIMARY
        S       3
        mov     r8d, eax
        mov     r9d, eax
        mov     ecx, r13d
        mov     eax, dword loc(2)
        shr     eax, 1
        add     ecx, eax
        sub     ecx, 1
        mov     edx, r14d
        add     edx, dword loc(2)
        call    gfx_ellipse
.done:  EPROC

; ---------------------------------------------------------------- player bar
; left block: cover + title / artist
PROC bar_left, 8
        S       14
        mov     r12d, eax                       ; padding
        mov     eax, [lay_bar_h]
        sub     eax, r12d
        sub     eax, r12d
        mov     r13d, eax                       ; cover size
        mov     r14d, [lay_bar_y]
        add     r14d, r12d                      ; cover y
        cmp     dword [np_valid], 0
        je      .empty
        mov     rcx, [np_img_s]
        mov     edx, r12d
        mov     r8d, r14d
        mov     r9d, r13d
        S       8
        mov     outarg(5), rax
        call    draw_cover
        mov     qword [rsp+32], H_NP_COVER
        mov     qword [rsp+40], 0
        mov     ecx, r12d
        mov     edx, r14d
        mov     r8d, r13d
        mov     r9d, r13d
        call    hit_add
        S       14
        lea     esi, [r12+r13]
        add     esi, eax                        ; text x
        mov     eax, [ui_w]
        imul    eax, 28
        xor     edx, edx
        mov     ecx, 100
        div     ecx
        sub     eax, esi
        mov     edi, eax                        ; text width
        S       34
        sub     edi, eax                        ; room for the heart after the text
        mov     ebx, [lay_bar_h]
        shr     ebx, 1
        add     ebx, [lay_bar_y]                ; vertical middle of the bar
        SETFONT F_BODY_B
        SETCOL  T_FG
        S       22
        mov     r8d, ebx
        sub     r8d, eax
        mov     rcx, [np_title]
        mov     edx, esi
        mov     r9d, edi
        mov     outarg(5), rax
        call    gfx_text
        SETFONT F_SMALL
        SETCOL  T_MUTED_FG
        S       20
        mov     r8d, ebx
        mov     rcx, [np_artist]
        mov     edx, esi
        mov     r9d, edi
        mov     outarg(5), rax
        call    gfx_text
        S       30
        mov     r8d, eax                        ; heart box
        S       4
        lea     ecx, [rsi+rdi]
        add     ecx, eax
        mov     eax, r8d
        shr     eax, 1
        mov     edx, ebx
        sub     edx, eax
        mov     r9d, 0xFFFF0000                 ; the playing track
        mov     rax, [np_uri]
        mov     outarg(5), rax
        mov     qword outarg(6), 1
        call    draw_heart
        jmp     .out
.empty: SETCOL  T_SURFACE
        S       8
        mov     outarg(5), rax
        mov     ecx, r12d
        mov     edx, r14d
        mov     r8d, r13d
        mov     r9d, r13d
        call    gfx_rrect
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        S       14
        lea     edx, [r12+r13]
        add     edx, eax
        mov     r8d, [lay_bar_y]
        mov     r9d, 260
        lea     rcx, [w_nothing]
        mov     eax, [lay_bar_h]
        mov     outarg(5), rax
        call    gfx_text
.out:   EPROC

; centre block: transport buttons, seek bar and the two time labels
PROC bar_center, 10
        mov     eax, [ui_w]
        mov     loc(0), rax                     ; window width
        S       36
        mov     r13d, eax                       ; small box
        S       44
        mov     r14d, eax                       ; play box
        S       10
        add     eax, [lay_bar_y]
        mov     edx, eax
        mov     ecx, dword loc(0)
        shr     ecx, 1
        mov     r8d, r13d
        mov     r9d, r14d
        call    draw_transport
        ; seek bar: min(560 dp, 36 % of the window), centred
        mov     eax, dword loc(0)
        imul    eax, 36
        xor     edx, edx
        mov     ecx, 100
        div     ecx
        mov     ebx, eax
        S       560
        cmp     ebx, eax
        cmova   ebx, eax                        ; ebx = bar width
        mov     eax, dword loc(0)
        sub     eax, ebx
        shr     eax, 1
        mov     esi, eax                        ; bar x
        S       34
        mov     edi, [lay_bar_y]
        add     edi, [lay_bar_h]
        sub     edi, eax                        ; bar centre line
        mov     ecx, esi
        mov     edx, edi
        mov     r8d, ebx
        call    draw_seekbar
        ; time labels
        SETFONT F_CAPTION
        SETCOL  T_MUTED_FG
        S       18
        mov     r12d, eax                       ; label height
        shr     eax, 1
        mov     r15d, edi
        sub     r15d, eax                       ; label y
        call    np_position
        mov     edx, eax
        cmp     dword [drag_id], H_SEEK
        jne     .fmt1
        mov     eax, [np_dur]
        imul    eax, [drag_frac]
        xor     edx, edx
        mov     ecx, 1000
        div     ecx
        mov     edx, eax
.fmt1:  lea     rcx, loc(2)                     ; 16-byte wide buffer: loc(2)..loc(1)
        call    w_fmt_time
        SETALIGN 2
        S       52
        mov     edx, esi
        sub     edx, eax
        S       8
        sub     edx, eax
        S       44
        mov     r9d, eax
        mov     r8d, r15d
        lea     rcx, loc(2)
        mov     outarg(5), r12
        call    gfx_text
        SETALIGN 0
        lea     rcx, loc(2)
        mov     edx, [np_dur]
        cmp     dword [np_valid], 0
        jne     .fmt2
        xor     edx, edx
.fmt2:  call    w_fmt_time
        lea     edx, [rsi+rbx]
        S       8
        add     edx, eax
        S       44
        mov     r9d, eax
        mov     r8d, r15d
        lea     rcx, loc(2)
        mov     outarg(5), r12
        call    gfx_text
        EPROC

; right block: volume slider, queue and full-screen buttons
PROC bar_right, 6
        S       36
        mov     r12d, eax                       ; button box
        S       16
        mov     r13d, eax                       ; right margin
        S       18
        mov     ebx, eax                        ; icon size
        mov     eax, [lay_bar_h]
        sub     eax, r12d
        shr     eax, 1
        add     eax, [lay_bar_y]
        mov     r14d, eax                       ; button y
        mov     r15d, [ui_w]
        sub     r15d, r13d
        sub     r15d, r12d                      ; x of the full-screen button
        SETCOL  T_FG
        IBTN    ic_expand, r15d, r14d, r12d, H_FULL, 0, ebx, 0, 0
        S       6
        sub     r15d, r12d
        sub     r15d, eax
        cmp     dword [queue_open], 0
        je      .q0
        SETCOL  T_PRIMARY
        jmp     .q1
.q0:    SETCOL  T_FG
.q1:    IBTN    ic_queue, r15d, r14d, r12d, H_QUEUE, 0, ebx, 0, 0
        S       20
        sub     r15d, eax
        S       110
        mov     esi, eax                        ; slider width
        sub     r15d, esi
        mov     edi, [lay_bar_h]
        shr     edi, 1
        add     edi, [lay_bar_y]                ; middle of the bar
        mov     ecx, r15d
        mov     edx, edi
        mov     r8d, esi
        call    draw_volume
        SETCOL  T_MUTED_FG
        S       20
        mov     r12d, eax                       ; speaker icon size
        S       28
        mov     ecx, r15d
        sub     ecx, eax
        mov     edx, edi
        mov     eax, r12d
        shr     eax, 1
        sub     edx, eax
        mov     r8d, r12d
        lea     r9, [ic_volume]
        call    icon_draw
        EPROC

PROC paint_player_bar, 0
        SETCOL  T_SURFACE2
        RECT    0, dword [lay_bar_y], dword [ui_w], dword [lay_bar_h]
        SETCOL  T_BORDER
        RECT    0, dword [lay_bar_y], dword [ui_w], 1
        HIT     0, dword [lay_bar_y], dword [ui_w], dword [lay_bar_h], H_SHELL, 0
        call    bar_left
        call    bar_center
        call    bar_right
        EPROC
