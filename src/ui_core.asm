; ui_core.asm - UI state, DPI-scaled metrics, and the immediate-mode hit-test list.
;
; Painting is immediate-mode: every frame the paint code redraws everything and, for each clickable
; thing, appends a rectangle + (id, arg) to the hit list.  Input then looks the mouse position up in
; that list (last entry wins, so later-painted widgets sit on top).

; ---- pages
%define PAGE_HOME     0
%define PAGE_SEARCH   1
%define PAGE_LIBRARY  2
%define PAGE_DETAIL   3
%define PAGE_SETTINGS 4
%define PAGE_LOGIN    5

; ---- hit ids
%define H_NONE        0
%define H_NAV         1                 ; arg = page
%define H_SIDE_PL     2                 ; arg = playlist index
%define H_CARD        3                 ; arg = list<<16 | index
%define H_TRACK       4                 ; arg = list<<16 | index
%define H_PLAY        5
%define H_PREV        6
%define H_NEXT        7
%define H_SHUFFLE     8
%define H_REPEAT      9
%define H_SEEK        10
%define H_VOL         11
%define H_QUEUE       12
%define H_FULL        13
%define H_TAB         14                ; arg = library tab
%define H_SEARCHBOX   15
%define H_SIGNIN      16
%define H_THEME       17                ; arg = theme
%define H_SIGNOUT     18
%define H_BACK        19
%define H_FS_CLOSE    20
%define H_DETAIL_PLAY 21
%define H_QUEUE_ROW   22                ; arg = queue index
%define H_NP_COVER    23
%define H_DEMO        24
%define H_SHELL       25                ; inert surface that swallows clicks
%define H_COPY_URI    28
%define H_OPEN_DASH   29
%define H_BANNER_X    30
%define H_BANNER_ACT  31
%define H_OPEN_LOG    32
%define H_COPY_DIAG   33
%define H_CANCEL_SIGNIN 34
%define H_COPY_AUTH   35
%define H_TEST_AUDIO  36
%define H_LIKE        37                ; arg: see like_uri_for
%define H_CARD_PLAY   26
%define H_FIELD       47                ; arg = field index (field.asm)
%define H_ENGINE      48                ; arg = playback engine (0 lightweight helper, 1 Edge)
%define H_PILL        27

%define BA_NONE       0
%define BA_SETTINGS   1                 ; banner action: open Settings
%define BA_DASHBOARD  2                 ; banner action: open the Spotify dashboard
%define BA_GET_EDGE   3                 ; banner action: open the Microsoft Edge download page
%define BA_PAIR       4                 ; banner action: open the pairing page of the audio helper

; ---- track / card list sources used in H_TRACK / H_CARD args
%define SRC_RECENT    1
%define SRC_LIKED     2
%define SRC_SEARCH_T  3
%define SRC_DETAIL    4
%define SRC_PLAYLISTS 5
%define SRC_ALBUMS    6
%define SRC_SEARCH_A  7
%define SRC_SEARCH_P  8
%define SRC_SEARCH_R  9
%define SRC_DALBUMS   10                ; albums on an artist page

; ---- metrics (index into m[]); base values are at 100% scale
%define M_SB      0
%define M_BAR     1
%define M_QW      2
%define M_PAD     3
%define M_ROW     4
%define M_NAV     5
%define M_SROW    6
%define M_CARD    7
%define M_GAP     8
%define M_RAD     9
%define M_ICON    10
%define M_BTN     11
%define M_NMET    12

%define HIT_SIZE  24
%define HIT_MAX   2048

section .data
align 4
m_base: dd 232, 92, 320, 28, 52, 40, 34, 176, 20, 8, 20, 36

section .bss
m:              resd M_NMET
ui_w:           resd 1
ui_h:           resd 1
ui_scale:       resd 1                  ; 16.16
page:           resd 1
lib_tab:        resd 1
scroll_main:    resd 1
scroll_side:    resd 1
scroll_queue:   resd 1
content_h:      resd 1                  ; total height of the main page, set while painting
side_h:         resd 1
queue_h:        resd 1
view_h:         resd 1                  ; visible height of the main page
hover_id:       resd 1
hover_arg:      resd 1
press_id:       resd 1
press_arg:      resd 1
drag_id:        resd 1                  ; H_SEEK / H_VOL while dragging, else 0
drag_x:         resd 1
drag_w:         resd 1
drag_frac:      resd 1                  ; 0..1000 preview position while dragging a seek bar
queue_open:     resd 1
fullscreen:     resd 1
detail_sel:     resd 1                  ; playlist index highlighted in the sidebar (-1 none)
hit_n:          resd 1
clip_x0:        resd 1
clip_y0:        resd 1
clip_x1:        resd 1
clip_y1:        resd 1
                align 8
hit_tab:        resb HIT_SIZE*HIT_MAX
toast_text:     resq 1
toast_until:    resq 1
signed_in:      resd 1
edit_search:    resq 1
edit_syncing:   resd 1                  ; set while the program (not the user) fills an input
edit_client:    resq 1
edit_port:      resq 1
edit_dn:        resq 1                  ; dialog: playlist name
edit_dd:        resq 1                  ; dialog: description
banner_text:    resq 1                  ; UTF-16, owned (0 = none)
banner_label:   resq 1                  ; UTF-16, owned: action button label (0 = none)
banner_code:    resd 1
banner_h:       resd 1
redir_w:        resq 1                  ; UTF-16 copy of the redirect URI for display
ver_w:          resq 1                  ; UTF-16 "Version 0.1 (build ...)" for About
user_name:      resq 1                  ; UTF-16, owned
user_id:        resq 1                  ; Spotify user id (UTF-8, owned): decides which playlists are ours to change

section .text

%macro MET 2
        mov     %1, [m+4*(%2)]
%endmacro

; ---------------------------------------------------------------- metrics
; ecx = scale (16.16)
ui_metrics:
        mov     [ui_scale], ecx
        lea     r8, [m_base]
        lea     r9, [m]
        xor     edx, edx
.l:     mov     eax, [r8+rdx*4]
        imul    rax, rcx
        shr     rax, 16
        cmp     eax, 1
        jae     .s
        mov     eax, 1
.s:     mov     [r9+rdx*4], eax
        inc     edx
        cmp     edx, M_NMET
        jb      .l
        ret

; eax = value at 100% -> eax scaled
ui_s:
        imul    rax, [ui_scale]
        shr     rax, 16
        ret

; ---------------------------------------------------------------- hit list
hit_reset:
        inc     dword [img_frame]               ; a new paint pass: the cover cache ages its entries by frame
        mov     dword [hit_n], 0
hit_clip_reset:
        mov     dword [clip_x0], 0
        mov     dword [clip_y0], 0
        mov     eax, [ui_w]
        mov     [clip_x1], eax
        mov     eax, [ui_h]
        mov     [clip_y1], eax
        ret

; ecx = x, edx = y, r8d = w, r9d = h, [rsp+40] = id, [rsp+48] = arg   (leaf: no frame)
; The rectangle is intersected with the active clip; empty results are dropped.
hit_add:
        mov     eax, [hit_n]
        cmp     eax, HIT_MAX
        jae     .no
        ; x0 = max(x, clip_x0), x1 = min(x + w, clip_x1)
        mov     r10d, ecx
        cmp     r10d, [clip_x0]
        jge     .a
        mov     r10d, [clip_x0]
.a:     add     r8d, ecx
        cmp     r8d, [clip_x1]
        jle     .b
        mov     r8d, [clip_x1]
.b:     cmp     r8d, r10d
        jle     .no
        mov     r11d, edx
        cmp     r11d, [clip_y0]
        jge     .c
        mov     r11d, [clip_y0]
.c:     add     r9d, edx
        cmp     r9d, [clip_y1]
        jle     .d
        mov     r9d, [clip_y1]
.d:     cmp     r9d, r11d
        jle     .no
        imul    rax, rax, HIT_SIZE
        lea     rcx, [hit_tab]
        add     rax, rcx
        sub     r8d, r10d
        sub     r9d, r11d
        mov     [rax], r10d
        add     r11d, [ui_dy]                   ; the view being drawn may be sliding: rectangles follow it
        mov     [rax+4], r11d
        mov     [rax+8], r8d
        mov     [rax+12], r9d
        mov     edx, [rsp+40]
        mov     [rax+16], edx
        mov     edx, [rsp+48]
        mov     [rax+20], edx
        inc     dword [hit_n]
.no:    ret

; HIT x, y, w, h, id, arg - operands must not reference eax/ecx/edx/r8/r9.  Only valid inside a PROC.
%macro HIT 6
        mov     eax, %5
        mov     [rsp+32], rax
        mov     eax, %6
        mov     [rsp+40], rax
        mov     ecx, %1
        mov     edx, %2
        mov     r8d, %3
        mov     r9d, %4
        call    hit_add
%endmacro

; ecx = px, edx = py -> rax = hit entry (x,y,w,h,id,arg) or 0
hit_find:
        mov     eax, [hit_n]
.l:     test    eax, eax
        jz      .none
        dec     eax
        imul    r8, rax, HIT_SIZE
        lea     r9, [hit_tab]
        add     r8, r9
        mov     r9d, [r8]
        cmp     ecx, r9d
        jl      .l
        add     r9d, [r8+8]
        cmp     ecx, r9d
        jge     .l
        mov     r9d, [r8+4]
        cmp     edx, r9d
        jl      .l
        add     r9d, [r8+12]
        cmp     edx, r9d
        jge     .l
        mov     rax, r8
        ret
.none:  xor     eax, eax
        ret
