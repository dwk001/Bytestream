; window.asm - Win32 window, double-buffered painting, message routing, native EDIT controls.

extern RegisterClassExW, CreateWindowExW, DefWindowProcW, ShowWindow, UpdateWindow, GetMessageW
extern TranslateMessage, DispatchMessageW, PostQuitMessage, BeginPaint, EndPaint, InvalidateRect
extern GetClientRect, LoadCursorW, SetCursor, SetTimer, KillTimer, SetWindowPos, SetFocus
extern GetWindowTextW, ScreenToClient, SetCapture, ReleaseCapture, GetDpiForWindow, SetProcessDPIAware
extern TrackMouseEvent, GetDC, ReleaseDC, SendMessageW, AdjustWindowRectEx, GetModuleHandleW
extern CreateCompatibleDC, CreateDIBSection, SelectObject, DeleteObject, DeleteDC, BitBlt, GdiFlush
extern GdipCreateFromHDC, CreateFileW, CloseHandle, WriteFile

%define ID_EDIT_SEARCH   101
%define ID_EDIT_CLIENT   102
%define ID_EDIT_PORT     103
%define ID_EDIT_DN       104
%define ID_EDIT_DD       105
%define TIMER_TICK       1
%define TIMER_SEARCH     2
%define EN_CHANGE        0x0300
%define WM_SETFONT       0x0030

section .bss
hwnd:           resq 1
hinst:          resq 1
bb_dc:          resq 1
bb_bmp:         resq 1
bb_old:         resq 1
bb_bits:        resq 1
bb_g:           resq 1
bb_w:           resd 1
bb_h:           resd 1
mouse_x:        resd 1
mouse_y:        resd 1
tracking:       resd 1
h_arrow:        resq 1
h_hand:         resq 1
shot_done:      resd 1
cli_shot:       resq 1                  ; wide path of --screenshot (0 = interactive)
first_paint:    resd 1
wc:             resb 80
msg_buf:        resb 56
ps_buf:         resb 72
frame_valid:    resd 1                  ; a full frame has been rendered (hit list and layout are current)
bar_only:       resd 1                  ; this paint redraws the player bar only (playback progress ticks)
bar_hit_n:      resd 1                  ; length of the hit list just before the player bar was added
bar_rect:       resd 4
paints_full:    resd 1                  ; counters shown by --dump
paints_bar:     resd 1
rc_buf:         resb 16
tme_buf:        resb 24
bmi_buf:        resb 48
edit_last:      resd 20                 ; last rectangle given to each EDIT (x y w h) x5
edit_vis:       resd 5
edit_text:      resw 200
search_buf:     resw 260
shot_hdr:       resb 64
mmi_min_w:      resd 1
mmi_min_h:      resd 1

section .data
WSTR cls_name, "ByteStreamWindow"
WSTR win_title, "ByteStream"
WSTR cls_edit, "EDIT"
WSTR face_name, "Segoe UI"
WSTR empty_w, ""

section .text

; ecx = ARGB -> eax = COLORREF (0x00BBGGRR)
argb_to_cr:
        mov     eax, ecx
        mov     edx, ecx
        shr     edx, 16
        and     edx, 0xFF               ; R
        and     eax, 0xFF               ; B
        shl     eax, 16
        or      eax, edx
        mov     edx, ecx
        and     edx, 0xFF00             ; G already in place
        or      eax, edx
        ret

; ---------------------------------------------------------------- back buffer
PROC bb_create, 8
        mov     loc(0), rcx                     ; width
        mov     loc(1), rdx                     ; height
        mov     rcx, [bb_g]
        test    rcx, rcx
        jz      .nog
        call    GdipDeleteGraphics
        mov     qword [bb_g], 0
.nog:   mov     rcx, [bb_dc]
        test    rcx, rcx
        jz      .fresh
        mov     rdx, [bb_old]
        call    SelectObject
        mov     rcx, [bb_bmp]
        call    DeleteObject
        mov     rcx, [bb_dc]
        call    DeleteDC
.fresh: mov     rcx, [hwnd]
        call    GetDC
        mov     loc(2), rax
        mov     rcx, rax
        call    CreateCompatibleDC
        mov     [bb_dc], rax
        lea     rdi, [bmi_buf]                  ; BITMAPINFOHEADER, top-down 32 bpp
        mov     dword [rdi], 40
        mov     eax, dword loc(0)
        mov     [rdi+4], eax
        mov     eax, dword loc(1)
        neg     eax
        mov     [rdi+8], eax
        mov     word [rdi+12], 1
        mov     word [rdi+14], 32
        mov     dword [rdi+16], 0
        mov     dword [rdi+20], 0
        mov     rcx, [bb_dc]
        lea     rdx, [bmi_buf]
        xor     r8d, r8d                        ; DIB_RGB_COLORS
        lea     r9, [bb_bits]
        mov     qword outarg(5), 0
        mov     qword outarg(6), 0
        call    CreateDIBSection
        mov     [bb_bmp], rax
        mov     rcx, [bb_dc]
        mov     rdx, rax
        call    SelectObject
        mov     [bb_old], rax
        mov     rcx, [hwnd]
        mov     rdx, loc(2)
        call    ReleaseDC
        mov     rcx, [bb_dc]
        lea     rdx, [bb_g]
        call    GdipCreateFromHDC
        mov     rcx, [bb_g]
        call    gfx_attach
        mov     eax, dword loc(0)
        mov     [bb_w], eax
        mov     eax, dword loc(1)
        mov     [bb_h], eax
        EPROC

; ---------------------------------------------------------------- a frame
PROC render_frame, 2
        cmp     qword [bb_g], 0
        je      .out
        cmp     dword [bar_only], 0
        je      .full
        inc     dword [paints_bar]
        ; progress tick: everything but the player bar is unchanged in the back buffer, so only the bar is redrawn
        mov     eax, [bar_hit_n]
        mov     [hit_n], eax
        call    hit_clip_reset
        call    paint_player_bar
        call    like_flush
        jmp     .out
.full:  inc     dword [paints_full]
        mov     eax, [bb_w]
        mov     [ui_w], eax
        mov     eax, [bb_h]
        mov     [ui_h], eax
        mov     dword [edit_want], 0
        call    hit_reset
        call    lay_compute
        SETCOL  T_BG
        RECT    0, 0, dword [ui_w], dword [ui_h]
        mov     eax, [page]
        cmp     eax, PAGE_HOME
        je      .home
        cmp     eax, PAGE_SEARCH
        je      .search
        cmp     eax, PAGE_LIBRARY
        je      .library
        cmp     eax, PAGE_DETAIL
        je      .detail
        cmp     eax, PAGE_SETTINGS
        je      .settings
        call    page_login
        jmp     .overlays
.home:  call    page_home
        jmp     .chrome
.search: call   page_search
        jmp     .chrome
.library: call  page_library
        jmp     .chrome
.detail: call   page_detail
        jmp     .chrome
.settings: call page_settings
.chrome: call   paint_sidebar
        call    paint_queue
        mov     eax, [hit_n]
        mov     [bar_hit_n], eax
        call    paint_player_bar
.overlays:
        call    paint_banner
        call    paint_fullscreen
        call    paint_menu
        call    paint_dialog
        call    paint_toast
        mov     dword [frame_valid], 1
        call    like_flush                      ; hearts painted this frame that need an answer go out as one request
.out:   EPROC

; Moves / shows / hides the native EDIT controls to match what the current page asked for.
PROC sync_edits, 0
        cmp     dword [dlg_kind], 0
        je      .nodlg
        and     dword [edit_want], 0x18         ; a dialog is open: only its own fields may show
.nodlg: ; search box
        mov     eax, [edit_want]
        and     eax, 1
        mov     edx, [edit_sx]
        mov     r8d, [edit_sy]
        mov     r9d, [edit_sw]
        mov     ecx, [edit_sh]
        cmp     dword [fullscreen], 0
        je      .s1
        xor     eax, eax
.s1:    mov     rbx, [edit_search]
        lea     rsi, [edit_last]
        lea     rdi, [edit_vis]
        call    place_edit
        mov     eax, [edit_want]
        shr     eax, 1
        and     eax, 1
        mov     edx, [edit_cx]
        mov     r8d, [edit_cy]
        mov     r9d, [edit_cw]
        mov     ecx, [edit_ch]
        mov     rbx, [edit_client]
        lea     rsi, [edit_last+16]
        lea     rdi, [edit_vis+4]
        call    place_edit
        mov     eax, [edit_want]
        shr     eax, 2
        and     eax, 1
        mov     edx, [edit_px]
        mov     r8d, [edit_py]
        mov     r9d, [edit_pw]
        mov     ecx, [edit_ph]
        mov     rbx, [edit_port]
        lea     rsi, [edit_last+32]
        lea     rdi, [edit_vis+8]
        call    place_edit
        mov     eax, [edit_want]
        shr     eax, 3
        and     eax, 1
        mov     edx, [edit_dnx]
        mov     r8d, [edit_dnx+4]
        mov     r9d, [edit_dnx+8]
        mov     ecx, [edit_dnx+12]
        mov     rbx, [edit_dn]
        lea     rsi, [edit_last+48]
        lea     rdi, [edit_vis+12]
        call    place_edit
        mov     eax, [edit_want]
        shr     eax, 4
        and     eax, 1
        mov     edx, [edit_ddx]
        mov     r8d, [edit_ddx+4]
        mov     r9d, [edit_ddx+8]
        mov     ecx, [edit_ddx+12]
        mov     rbx, [edit_dd]
        lea     rsi, [edit_last+64]
        lea     rdi, [edit_vis+16]
        call    place_edit
        cmp     dword [focus_req], 0
        je      .out
        cmp     dword [focus_req], 4
        jne     .f1
        mov     rcx, [edit_dn]
        call    SetFocus
        jmp     .done
.f1:    cmp     dword [focus_req], 1
        jne     .cl
        mov     rcx, [edit_search]
        call    SetFocus
        jmp     .done
.cl:    mov     rcx, [edit_client]
        cmp     dword [focus_req], 3
        jne     .cl2
        mov     rcx, [edit_port]
.cl2:   call    SetFocus
.done:  mov     dword [focus_req], 0
.out:   EPROC

; eax = want visible, edx/r8d/r9d/ecx = x/y/w/h, rbx = control, rsi = last rect[4], rdi = visible flag
PROC place_edit, 2
        mov     loc(0), rcx
        mov     loc(1), rdx
        test    rbx, rbx
        jz      .out
        test    eax, eax
        jz      .hide
        mov     eax, [rsi]
        cmp     eax, edx
        jne     .move
        mov     eax, [rsi+4]
        cmp     eax, r8d
        jne     .move
        mov     eax, [rsi+8]
        cmp     eax, r9d
        jne     .move
        mov     eax, [rsi+12]
        cmp     eax, ecx
        jne     .move
        cmp     dword [rdi], 0
        jne     .out
.move:  mov     [rsi], edx
        mov     [rsi+4], r8d
        mov     [rsi+8], r9d
        mov     [rsi+12], ecx
        mov     dword [rdi], 1
        mov     rcx, rbx
        xor     edx, edx                        ; HWND_TOP
        mov     r8d, dword loc(1)
        mov     r9d, [rsi+4]
        mov     eax, [rsi+8]
        mov     outarg(5), rax
        mov     rax, loc(0)
        mov     outarg(6), rax
        mov     qword outarg(7), 0x0040         ; SWP_SHOWWINDOW
        call    SetWindowPos
        jmp     .out
.hide:  cmp     dword [rdi], 0
        je      .out
        mov     dword [rdi], 0
        mov     rcx, rbx
        xor     edx, edx                        ; SW_HIDE
        call    ShowWindow
.out:   EPROC

; ---------------------------------------------------------------- native edit controls
; ecx = control id -> rax = EDIT hwnd
PROC make_edit, 4
        mov     loc(0), rcx
        mov     ecx, 0
        lea     rdx, [cls_edit]
        lea     r8, [empty_w]
        mov     r9d, WS_CHILD | ES_AUTOHSCROLL
        mov     qword outarg(5), 0
        mov     qword outarg(6), 0
        mov     qword outarg(7), 10
        mov     qword outarg(8), 10
        mov     rax, [hwnd]
        mov     outarg(9), rax
        mov     rax, loc(0)
        mov     outarg(10), rax
        mov     rax, [hinst]
        mov     outarg(11), rax
        mov     qword outarg(12), 0
        call    CreateWindowExW
        mov     loc(1), rax
        mov     rcx, rax
        mov     edx, WM_SETFONT
        mov     r8, [edit_font]
        mov     r9d, 1
        call    SendMessageW
        mov     rax, loc(1)
        EPROC

PROC ui_make_fonts, 2
        mov     rcx, [edit_font]
        test    rcx, rcx
        jz      .mk
        call    DeleteObject
.mk:    lea     rdi, [logfont]
        mov     ecx, 96
        xor     eax, eax
        rep     stosb
        lea     rdi, [logfont]
        S       15
        neg     eax
        mov     [rdi], eax                      ; lfHeight (negative = pixels)
        mov     dword [rdi+16], 400             ; lfWeight
        mov     byte [rdi+23], 1                ; DEFAULT_CHARSET
        mov     byte [rdi+26], 5                ; CLEARTYPE_QUALITY
        lea     rsi, [face_name]
        lea     rdi, [logfont+28]
        mov     ecx, 9
        rep     movsw
        lea     rcx, [logfont]
        call    CreateFontIndirectW
        mov     [edit_font], rax
        ; re-apply to existing controls
        mov     rcx, [edit_search]
        test    rcx, rcx
        jz      .c
        mov     edx, WM_SETFONT
        mov     r8, [edit_font]
        mov     r9d, 1
        call    SendMessageW
.c:     mov     rcx, [edit_client]
        test    rcx, rcx
        jz      .out
        mov     edx, WM_SETFONT
        mov     r8, [edit_font]
        mov     r9d, 1
        call    SendMessageW
        mov     rcx, [edit_dn]
        test    rcx, rcx
        jz      .out
        mov     edx, WM_SETFONT
        mov     r8, [edit_font]
        mov     r9d, 1
        call    SendMessageW
        mov     rcx, [edit_dd]
        test    rcx, rcx
        jz      .out
        mov     edx, WM_SETFONT
        mov     r8, [edit_font]
        mov     r9d, 1
        call    SendMessageW
.out:   EPROC

; Rebuilds the colour-dependent GDI objects after a theme change.
PROC ui_theme_changed, 0
        mov     rcx, [edit_brush]
        test    rcx, rcx
        jz      .mk
        call    DeleteObject
.mk:    mov     ecx, [th+4*T_SURFACE]
        call    argb_to_cr
        mov     ecx, eax
        call    CreateSolidBrush
        mov     [edit_brush], rax
        mov     dword [edit_vis], 0
        mov     dword [edit_vis+4], 0
        mov     dword [edit_vis+12], 0
        mov     dword [edit_vis+16], 0
        mov     rcx, [hwnd]
        test    rcx, rcx
        jz      .out
        xor     edx, edx
        mov     r8d, 1
        call    InvalidateRect
.out:   EPROC

; ---------------------------------------------------------------- window procedure
PROC wndproc, 12
        mov     loc(0), rcx                     ; hwnd
        mov     loc(1), rdx                     ; message
        mov     loc(2), r8                      ; wParam
        mov     loc(3), r9                      ; lParam
        cmp     edx, WM_PAINT
        je      .paint
        cmp     edx, WM_ERASEBKGND
        je      .one
        cmp     edx, WM_MOUSEMOVE
        je      .mmove
        cmp     edx, WM_LBUTTONDOWN
        je      .lbd
        cmp     edx, WM_LBUTTONUP
        je      .lbu
        cmp     edx, 0x0205                     ; WM_RBUTTONUP
        je      .rbu
        cmp     edx, WM_MOUSEWHEEL
        je      .wheel
        cmp     edx, WM_MOUSELEAVE
        je      .leave
        cmp     edx, WM_SETCURSOR
        je      .cursor
        cmp     edx, WM_KEYDOWN
        je      .key
        cmp     edx, 0x0319                     ; WM_APPCOMMAND: the keyboard's media keys
        je      .appcmd
        cmp     edx, WM_TIMER
        je      .timer
        cmp     edx, WM_SIZE
        je      .size
        cmp     edx, WM_COMMAND
        je      .command
        cmp     edx, WM_CTLCOLOREDIT
        je      .ctlcolor
        cmp     edx, WM_GETMINMAXINFO
        je      .minmax
        cmp     edx, WM_DPICHANGED
        je      .dpi
        cmp     edx, WM_DESTROY
        je      .destroy
        cmp     edx, WM_APP
        jae     .app
.def:   mov     rcx, loc(0)
        mov     rdx, loc(1)
        mov     r8, loc(2)
        mov     r9, loc(3)
        call    DefWindowProcW
        jmp     .out
.one:   mov     eax, 1
        jmp     .out
.zero:  xor     eax, eax
        jmp     .out

.paint: mov     rcx, loc(0)
        lea     rdx, [ps_buf]
        call    BeginPaint
        mov     loc(4), rax                     ; hdc
        ; only the player bar is invalid (a playback tick) and nothing else floats over it: redraw just the bar
        mov     dword [bar_only], 0
        cmp     dword [frame_valid], 0
        je      .fullpaint
        cmp     qword [cli_shot], 0
        jne     .fullpaint
        cmp     dword [page], PAGE_LOGIN
        je      .fullpaint
        cmp     qword [banner_text], 0
        jne     .fullpaint
        cmp     qword [toast_text], 0
        jne     .fullpaint
        cmp     dword [fullscreen], 0
        jne     .fullpaint
        cmp     dword [queue_open], 0
        jne     .fullpaint
        cmp     dword [menu_open], 0
        jne     .fullpaint
        cmp     dword [dlg_kind], 0
        jne     .fullpaint
        mov     eax, [ps_buf+16]                ; PAINTSTRUCT.rcPaint.top
        cmp     eax, [lay_bar_y]
        jl      .fullpaint
        mov     dword [bar_only], 1
.fullpaint:
        call    render_frame
        cmp     dword [bar_only], 0
        jne     .noedits
        call    sync_edits
.noedits:
        call    GdiFlush
        mov     rcx, loc(4)
        xor     edx, edx
        xor     r8d, r8d
        mov     r9d, [bb_w]
        mov     eax, [bb_h]
        mov     outarg(5), rax
        mov     rax, [bb_dc]
        mov     outarg(6), rax
        mov     qword outarg(7), 0
        mov     qword outarg(8), 0
        mov     qword outarg(9), SRCCOPY
        call    BitBlt
        mov     rcx, loc(0)
        lea     rdx, [ps_buf]
        call    EndPaint
        cmp     qword [cli_shot], 0
        je      .zero
        cmp     dword [cli_ready], 0
        je      .zero
        cmp     dword [shot_done], 0
        jne     .zero
        inc     dword [first_paint]
        cmp     dword [first_paint], 2          ; let a second frame settle (async covers, edits)
        jb      .repaint
        mov     dword [shot_done], 1
        call    write_screenshot
        xor     ecx, ecx
        call    PostQuitMessage
        jmp     .zero
.repaint:
        mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero

.rbu:   mov     rax, loc(3)
        movsx   ecx, ax
        sar     rax, 16
        movsx   edx, ax
        call    ui_context
        test    eax, eax
        jz      .zero
        mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero

.mmove: mov     rax, loc(3)
        movsx   ecx, ax
        sar     rax, 16
        movsx   edx, ax
        call    ui_mouse_move
        mov     loc(4), rax                     ; 1 = hover/drag changed
        cmp     dword [tracking], 0
        jne     .mm2
        mov     dword [tme_buf], 24
        mov     dword [tme_buf+4], 2            ; TME_LEAVE
        mov     rax, loc(0)
        mov     [tme_buf+8], rax
        lea     rcx, [tme_buf]
        call    TrackMouseEvent
        mov     dword [tracking], 1
.mm2:   cmp     dword loc(4), 0
        je      .zero
        mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero


.lbd:   mov     rcx, loc(0)
        call    SetFocus
        mov     rax, loc(3)
        movsx   ecx, ax
        sar     rax, 16
        movsx   edx, ax
        call    ui_mouse_down
        mov     loc(4), rax
        test    al, 2
        jz      .lbd2
        mov     rcx, loc(0)
        call    SetCapture
.lbd2:  mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero

.lbu:   mov     rax, loc(3)
        movsx   ecx, ax
        sar     rax, 16
        movsx   edx, ax
        call    ui_mouse_up
        mov     loc(4), rax
        test    al, 2
        jz      .lbu2
        call    ReleaseCapture
.lbu2:  mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero

.wheel: mov     rax, loc(2)
        sar     rax, 16
        movsx   ecx, ax                         ; wheel delta
        mov     rax, loc(3)                     ; screen coordinates -> client
        movsx   edx, ax
        mov     dword loc(11), edx              ; POINT at &loc(11): x, then y
        sar     rax, 16
        movsx   edx, ax
        mov     dword [rbp-72-8*11+4], edx
        mov     loc(4), rcx
        mov     rcx, loc(0)
        lea     rdx, loc(11)
        call    ScreenToClient
        mov     rcx, loc(4)
        mov     edx, dword loc(11)
        call    ui_wheel
        mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero

.leave: mov     dword [tracking], 0
        mov     dword [hover_id], 0
        mov     dword [hover_arg], 0
        mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero

.cursor:
        mov     rax, loc(3)
        and     eax, 0xFFFF
        cmp     eax, 1                          ; HTCLIENT
        jne     .def
        mov     eax, [hover_id]
        mov     rcx, [h_arrow]
        cmp     eax, H_NONE
        je      .setc
        mov     rcx, [h_hand]
.setc:  call    SetCursor
        jmp     .one

.key:   mov     rcx, loc(2)
        call    ui_key
        test    eax, eax
        jz      .zero
        mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero

.appcmd: mov    rax, loc(3)
        shr     rax, 16
        and     eax, 0x0FFF                     ; GET_APPCOMMAND_LPARAM
        mov     ecx, H_PLAY
        cmp     eax, 14                         ; APPCOMMAND_MEDIA_PLAY_PAUSE
        je      .appact
        cmp     eax, 46                         ; APPCOMMAND_MEDIA_PLAY
        je      .appact
        cmp     eax, 47                         ; APPCOMMAND_MEDIA_PAUSE
        je      .appact
        mov     ecx, H_NEXT
        cmp     eax, 11                         ; APPCOMMAND_MEDIA_NEXTTRACK
        je      .appact
        mov     ecx, H_PREV
        cmp     eax, 12                         ; APPCOMMAND_MEDIA_PREVIOUSTRACK
        je      .appact
        jmp     .def
.appact: xor    edx, edx
        call    ui_activate
        mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        mov     eax, 1                          ; handled
        jmp     .out

.timer: mov     rax, loc(2)
        cmp     eax, TIMER_SEARCH
        je      .search_timer
        cmp     dword [cli_run_ms], 0           ; tests: --run-ms N lets the app run N ms, then dumps its state and exits
        je      .norun
        call    GetTickCount64
        sub     rax, [run_t0]
        cmp     eax, [cli_run_ms]
        jb      .norun
        call    dump_state
        xor     ecx, ecx
        call    ExitProcess
.norun:
        mov     r12, [banner_text]              ; edge_tick may raise a banner: notice that
        call    player_tick
        mov     ebx, eax                        ; 1 = playing: the player bar's progress moved
        call    auth_tick
        mov     r13d, eax                       ; 1 = something else changed: repaint everything
        call    edge_tick
        call    queue_tick
        cmp     r12, [banner_text]
        je      .tk1
        mov     r13d, 1
.tk1:   cmp     qword [toast_text], 0
        je      .tk2
        mov     r13d, 1
.tk2:   test    ebx, ebx
        jz      .tk3
        cmp     dword [fullscreen], 0           ; the full-screen view and the queue panel show progress too
        jne     .tkfull
        cmp     dword [queue_open], 0
        je      .tk3
.tkfull: mov    r13d, 1
.tk3:   test    r13d, r13d
        jnz     .tkall
        test    ebx, ebx
        jz      .zero
        lea     rcx, [bar_rect]                 ; playback progress only: invalidate just the player bar
        mov     dword [rcx], 0
        mov     eax, [lay_bar_y]
        mov     [rcx+4], eax
        mov     eax, [ui_w]
        mov     [rcx+8], eax
        mov     eax, [lay_bar_y]
        add     eax, [lay_bar_h]
        mov     [rcx+12], eax
        mov     rdx, rcx
        mov     rcx, loc(0)
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero
.tkall: mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero
.search_timer:
        mov     rcx, loc(0)
        mov     edx, TIMER_SEARCH
        call    KillTimer
        call    ui_run_search
        mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero

.size:  mov     rax, loc(3)
        movzx   ecx, ax
        shr     rax, 16
        movzx   edx, ax
        test    ecx, ecx
        jz      .zero
        test    edx, edx
        jz      .zero
        call    bb_create
        mov     dword [edit_vis], 0
        mov     dword [edit_vis+4], 0
        mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero

.command:
        mov     rax, loc(2)
        mov     rcx, rax
        shr     rcx, 16
        cmp     ecx, EN_CHANGE
        jne     .zero
        movzx   eax, ax
        cmp     eax, ID_EDIT_CLIENT
        je      .client_changed
        cmp     eax, ID_EDIT_PORT
        je      .port_changed
        cmp     eax, ID_EDIT_SEARCH
        jne     .zero
        mov     rcx, [edit_search]
        lea     rdx, [search_buf]
        mov     r8d, 256
        call    GetWindowTextW
        mov     rcx, loc(0)
        mov     edx, TIMER_SEARCH
        mov     r8d, 350
        xor     r9d, r9d
        call    SetTimer
        jmp     .zero

.client_changed:
        call    on_client_changed
        jmp     .zero
.port_changed:
        call    on_port_changed
        jmp     .zero

.ctlcolor:
        mov     ecx, [th+4*T_FG]
        call    argb_to_cr
        mov     rcx, loc(2)
        mov     edx, eax
        call    SetTextColor
        mov     ecx, [th+4*T_SURFACE]
        call    argb_to_cr
        mov     rcx, loc(2)
        mov     edx, eax
        call    SetBkColor
        mov     rax, [edit_brush]
        jmp     .out

.minmax:
        S       900
        mov     rcx, loc(3)
        mov     [rcx+24], eax                   ; ptMinTrackSize.x
        S       560
        mov     rcx, loc(3)
        mov     [rcx+28], eax
        ; Windows clamps a window to the screen by default; lift that so --size is honoured on small desktops
        ; (CI machines are 1024x768) and the layout can be tested at any size.
        mov     rcx, loc(3)
        mov     dword [rcx+8], 8192             ; ptMaxSize
        mov     dword [rcx+12], 8192
        mov     dword [rcx+32], 8192            ; ptMaxTrackSize
        mov     dword [rcx+36], 8192
        jmp     .zero

.dpi:   mov     rax, loc(2)
        movzx   eax, ax                         ; new DPI
        imul    eax, 65536
        xor     edx, edx
        mov     ecx, 96
        div     ecx
        mov     loc(4), rax
        mov     ecx, eax
        call    ui_metrics
        mov     ecx, dword loc(4)
        call    gfx_set_scale
        call    ui_make_fonts
        mov     rax, loc(3)                     ; suggested window rectangle
        mov     r8d, [rax]
        mov     r9d, [rax+4]
        mov     edx, [rax+8]
        sub     edx, r8d
        mov     ecx, [rax+12]
        sub     ecx, r9d
        mov     outarg(5), rdx
        mov     outarg(6), rcx
        mov     qword outarg(7), 0x14           ; SWP_NOZORDER | SWP_NOACTIVATE
        mov     rcx, loc(0)
        xor     edx, edx
        call    SetWindowPos
        jmp     .zero

.destroy:
        xor     ecx, ecx
        call    PostQuitMessage
        jmp     .zero

.app:   mov     rcx, loc(2)
        mov     rdx, loc(3)
        mov     r8d, dword loc(1)
        call    app_message
        mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        jmp     .zero
.out:   EPROC

; reads the search box and runs the query
PROC ui_run_search, 0
        mov     rcx, [edit_search]
        test    rcx, rcx
        jz      .out
        lea     rdx, [search_buf]
        mov     r8d, 256
        call    GetWindowTextW
        lea     rcx, [search_buf]
        cmp     dword [g_demo], 0
        je      .real
        call    app_search_demo
        jmp     .out
.real:  call    real_search
.out:   EPROC

; writes the back buffer as a top-down 32-bit BMP to the --screenshot path
PROC write_screenshot, 6
        mov     rcx, [cli_shot]
        mov     edx, 0x40000000                 ; GENERIC_WRITE
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword outarg(5), 2              ; CREATE_ALWAYS
        mov     qword outarg(6), 0x80
        mov     qword outarg(7), 0
        call    CreateFileW
        mov     loc(0), rax
        cmp     rax, -1
        je      .out
        ; BITMAPFILEHEADER (14) + BITMAPINFOHEADER (40) assembled in bmi_buf+... use a stack block
        mov     eax, [bb_w]
        imul    eax, [bb_h]
        shl     eax, 2
        mov     loc(1), rax                     ; pixel bytes
        lea     rdi, [shot_hdr]
        mov     word [rdi], 0x4D42              ; 'BM'
        lea     eax, [rax+54]
        mov     [rdi+2], eax
        mov     dword [rdi+6], 0
        mov     dword [rdi+10], 54
        mov     dword [rdi+14], 40
        mov     eax, [bb_w]
        mov     [rdi+18], eax
        mov     eax, [bb_h]
        neg     eax
        mov     [rdi+22], eax
        mov     word [rdi+26], 1
        mov     word [rdi+28], 32
        mov     dword [rdi+30], 0
        mov     rax, loc(1)
        mov     [rdi+34], eax
        mov     dword [rdi+38], 2835
        mov     dword [rdi+42], 2835
        mov     dword [rdi+46], 0
        mov     dword [rdi+50], 0
        mov     rcx, loc(0)
        lea     rdx, [shot_hdr]
        mov     r8d, 54
        lea     r9, loc(2)
        mov     qword outarg(5), 0
        call    WriteFile
        mov     rcx, loc(0)
        mov     rdx, [bb_bits]
        mov     r8, loc(1)
        lea     r9, loc(2)
        mov     qword outarg(5), 0
        call    WriteFile
        mov     rcx, loc(0)
        call    CloseHandle
.out:   EPROC

; creates the class, the main window and the child controls
; ecx = client width, edx = client height, r8d = scale (16.16)
PROC window_create, 8
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        xor     ecx, ecx
        call    GetModuleHandleW
        mov     [hinst], rax
        xor     ecx, ecx
        mov     edx, IDC_ARROW
        call    LoadCursorW
        mov     [h_arrow], rax
        xor     ecx, ecx
        mov     edx, IDC_HAND
        call    LoadCursorW
        mov     [h_hand], rax
        lea     rdi, [wc]
        mov     dword [rdi], 80
        mov     dword [rdi+4], 0x0003           ; CS_HREDRAW | CS_VREDRAW
        lea     rax, [wndproc]
        mov     [rdi+8], rax
        mov     rax, [hinst]
        mov     [rdi+24], rax
        mov     rax, [h_arrow]
        mov     [rdi+40], rax
        lea     rax, [cls_name]
        mov     [rdi+64], rax
        lea     rcx, [wc]
        call    RegisterClassExW
        ; outer size from the wanted client size
        mov     dword [rc_buf], 0
        mov     dword [rc_buf+4], 0
        mov     eax, dword loc(0)
        mov     [rc_buf+8], eax
        mov     eax, dword loc(1)
        mov     [rc_buf+12], eax
        lea     rcx, [rc_buf]
        mov     edx, WS_OVERLAPPEDWINDOW
        xor     r8d, r8d
        xor     r9d, r9d
        call    AdjustWindowRectEx
        mov     eax, [rc_buf+8]
        sub     eax, [rc_buf]
        mov     loc(3), rax                     ; outer width
        mov     eax, [rc_buf+12]
        sub     eax, [rc_buf+4]
        mov     loc(4), rax                     ; outer height
        xor     ecx, ecx
        lea     rdx, [cls_name]
        lea     r8, [win_title]
        mov     r9d, WS_OVERLAPPEDWINDOW
        mov     eax, CW_USEDEFAULT
        mov     outarg(5), rax
        mov     outarg(6), rax
        mov     rax, loc(3)
        mov     outarg(7), rax
        mov     rax, loc(4)
        mov     outarg(8), rax
        mov     qword outarg(9), 0
        mov     qword outarg(10), 0
        mov     rax, [hinst]
        mov     outarg(11), rax
        mov     qword outarg(12), 0
        call    CreateWindowExW
        mov     [hwnd], rax
        EPROC

; ---------------------------------------------------------------- setup inputs -> settings
PROC redir_refresh, 4
        mov     rcx, [redir_w]
        call    mem_free
        mov     qword loc(1), 0                 ; Buf based at &loc(3)
        mov     qword loc(2), 0
        mov     qword loc(3), 0
        lea     rcx, loc(3)
        call    redirect_uri_append
        mov     rcx, loc(3)
        mov     rdx, -1
        call    u8_to_w
        mov     [redir_w], rax
        lea     rcx, loc(3)
        call    buf_free
        EPROC

; the Client ID box changed: trim, store, save
PROC on_client_changed, 2
        cmp     dword [edit_syncing], 0
        jne     .out
        mov     rcx, [edit_client]
        lea     rdx, [edit_text]
        mov     r8d, 190
        call    GetWindowTextW
        lea     rcx, [edit_text]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(0), rax
        mov     rsi, rax                        ; trim leading blanks
.lead:  cmp     byte [rsi], ' '
        jne     .copy
        inc     rsi
        jmp     .lead
.copy:  lea     rdi, [set_client_id]
        xor     ecx, ecx
.cp:    cmp     ecx, 150
        jae     .end
        mov     al, [rsi+rcx]
        test    al, al
        jz      .end
        mov     [rdi+rcx], al
        inc     ecx
        jmp     .cp
.end:   mov     byte [rdi+rcx], 0
.trim:  test    ecx, ecx                        ; trim trailing blanks
        jz      .done
        cmp     byte [rdi+rcx-1], ' '
        jne     .done
        dec     ecx
        mov     byte [rdi+rcx], 0
        jmp     .trim
.done:  mov     rcx, loc(0)
        call    mem_free
        call    settings_save
.out:   EPROC

; the Port box changed: accept 1024..65535, refresh the displayed redirect URI, save
PROC on_port_changed, 2
        cmp     dword [edit_syncing], 0
        jne     .out
        mov     rcx, [edit_port]
        lea     rdx, [edit_text]
        mov     r8d, 12
        call    GetWindowTextW
        lea     rcx, [edit_text]
        call    w_atoi
        cmp     eax, 1024
        jb      .out
        cmp     eax, 65535
        ja      .out
        mov     [set_port], eax
        call    redir_refresh
        call    settings_save
.out:   EPROC

; puts the stored settings into the inputs without triggering saves
PROC edit_fill_from_settings, 4
        mov     dword [edit_syncing], 1
        lea     rcx, [set_client_id]
        mov     rdx, -1
        call    u8_to_w
        mov     loc(0), rax
        mov     rcx, [edit_client]
        mov     rdx, rax
        call    SetWindowTextW
        mov     rcx, loc(0)
        call    mem_free
        lea     rcx, [edit_text]
        mov     edx, [set_port]
        call    w_put_u64
        mov     word [rax], 0
        mov     rcx, [edit_port]
        lea     rdx, [edit_text]
        call    SetWindowTextW
        mov     dword [edit_syncing], 0
        call    redir_refresh
        EPROC
