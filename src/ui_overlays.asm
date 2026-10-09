; ui_overlays.asm - queue panel, full-screen Now Playing view, toast.

section .bss
fs_gen:         resd 1                  ; np_gen the cached tint belongs to
fs_tint:        resd 1

section .data
WSTR w_signin_hint, "Sign in to see your queue"

section .text

; A compact track line: cover, title, artist.
; rcx = Track*, edx = x, r8d = y, r9d = w, [rbp+48] = row height, [rbp+56] = hit id (0 = none), [rbp+64] = hit arg
PROC draw_mini_track, 8
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        mov     eax, stk5
        mov     loc(4), rax
        S       40
        mov     r12d, eax                       ; cover size
        mov     eax, dword loc(4)
        sub     eax, r12d
        shr     eax, 1
        add     eax, dword loc(2)
        mov     r8d, eax
        mov     rcx, loc(0)
        mov     rcx, [rcx+TR_IMG_S]
        mov     edx, dword loc(1)
        mov     r9d, r12d
        mov     qword outarg(5), 6
        call    draw_cover
        S       12
        lea     r13d, [r12+rax]
        add     r13d, dword loc(1)              ; text x
        mov     eax, dword loc(3)
        sub     eax, r12d
        S       12
        mov     ecx, eax
        mov     eax, dword loc(3)
        sub     eax, r12d
        sub     eax, ecx
        mov     r14d, eax                       ; text width
        SETFONT F_BODY_B
        SETCOL  T_FG
        mov     eax, dword loc(4)
        shr     eax, 1
        S       19
        mov     ecx, eax
        mov     eax, dword loc(4)
        shr     eax, 1
        sub     eax, ecx
        add     eax, dword loc(2)
        mov     r8d, eax
        mov     rcx, loc(0)
        mov     rcx, [rcx+TR_TITLE]
        mov     edx, r13d
        mov     r9d, r14d
        S       19
        mov     outarg(5), rax
        call    gfx_text
        SETFONT F_SMALL
        SETCOL  T_MUTED_FG
        mov     eax, dword loc(4)
        shr     eax, 1
        add     eax, dword loc(2)
        inc     eax
        mov     r8d, eax
        mov     rcx, loc(0)
        mov     rcx, [rcx+TR_ARTIST]
        mov     edx, r13d
        mov     r9d, r14d
        S       17
        mov     outarg(5), rax
        call    gfx_text
        mov     eax, [rbp+56]
        test    eax, eax
        jz      .out
        mov     [rsp+32], rax
        mov     eax, [rbp+64]
        mov     [rsp+40], rax
        mov     ecx, dword loc(1)
        mov     edx, dword loc(2)
        mov     r8d, dword loc(3)
        mov     r9d, dword loc(4)
        call    hit_add
.out:   EPROC

; ---------------------------------------------------------------- queue
PROC paint_queue, 16
        cmp     dword [queue_open], 0
        je      .out
        mov     eax, [lay_q_x]
        mov     loc(0), rax
        mov     eax, [lay_q_w]
        mov     loc(1), rax
        mov     eax, [lay_bar_y]
        mov     loc(2), rax
        SETCOL  T_SIDEBAR
        RECT    dword loc(0), 0, dword loc(1), dword loc(2)
        SETCOL  T_SIDEBAR_BORDER
        RECT    dword loc(0), 0, 1, dword loc(2)
        HIT     dword loc(0), 0, dword loc(1), dword loc(2), H_SHELL, 0
        S       20
        mov     r12d, eax                       ; padding
        mov     eax, dword loc(0)
        add     eax, r12d
        mov     r13d, eax                       ; content x
        mov     eax, dword loc(1)
        sub     eax, r12d
        sub     eax, r12d
        mov     r14d, eax                       ; content width
        SETFONT F_H2
        SETCOL  T_FG
        S       32
        mov     ebx, eax
        TXTL    w_queue, r13d, r12d, r14d, ebx
        lea     r15d, [r12+rbx]
        S       12
        add     r15d, eax                       ; y cursor
        ; now playing
        SETFONT F_CAPTION
        SETCOL  T_HEAD_FG
        S       18
        mov     ebx, eax
        TXTL    w_now_playing, r13d, r15d, r14d, ebx
        add     r15d, ebx
        S       56
        mov     esi, eax                        ; row height
        cmp     dword [np_valid], 0
        je      .nonp
        ; build a Track view of the current song on the stack
        lea     rdi, loc(15)                    ; 56-byte Track view: loc(15)..loc(9)
        mov     rax, [np_title]
        mov     [rdi+TR_TITLE], rax
        mov     rax, [np_artist]
        mov     [rdi+TR_ARTIST], rax
        mov     rax, [np_img_s]
        mov     [rdi+TR_IMG_S], rax
        mov     rcx, rdi
        mov     edx, r13d
        mov     r8d, r15d
        mov     r9d, r14d
        mov     outarg(5), rsi
        mov     qword outarg(6), 0
        mov     qword outarg(7), 0
        call    draw_mini_track
.nonp:  add     r15d, esi
        S       12
        add     r15d, eax
        SETFONT F_CAPTION
        SETCOL  T_HEAD_FG
        S       18
        mov     ebx, eax
        TXTL    w_next_up, r13d, r15d, r14d, ebx
        add     r15d, ebx
        ; scrolling list of what's next
        mov     eax, dword loc(2)
        sub     eax, r15d
        S       8
        mov     ecx, eax
        mov     eax, dword loc(2)
        sub     eax, r15d
        sub     eax, ecx
        mov     dword loc(8), eax               ; viewport height
        mov     rax, [q_up+LS_COUNT]
        imul    eax, esi
        mov     [queue_h], eax
        sub     eax, dword loc(8)
        jns     .mx
        xor     eax, eax
.mx:    cmp     [scroll_queue], eax
        jle     .lo
        mov     [scroll_queue], eax
.lo:    cmp     dword [scroll_queue], 0
        jge     .clip
        mov     dword [scroll_queue], 0
.clip:  mov     ecx, dword loc(0)
        mov     edx, r15d
        mov     r8d, dword loc(1)
        mov     r9d, dword loc(8)
        call    ui_clip
        cmp     qword [q_up+LS_COUNT], 0
        jne     .rows
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        TXTL    w_queue_empty, r13d, r15d, r14d, esi
        jmp     .end
.rows:  xor     ebx, ebx
.row:   cmp     rbx, [q_up+LS_COUNT]
        jae     .end
        mov     eax, esi
        imul    eax, ebx
        add     eax, r15d
        sub     eax, [scroll_queue]
        mov     r12d, eax                       ; row y
        add     eax, esi
        cmp     eax, r15d
        jle     .nx
        mov     eax, r15d
        add     eax, dword loc(8)
        cmp     r12d, eax
        jge     .end
        cmp     dword [hover_id], H_QUEUE_ROW
        jne     .draw
        cmp     dword [hover_arg], ebx
        jne     .draw
        SETCOL  T_SIDEBAR_ACC
        mov     ecx, r13d
        mov     edx, r12d
        mov     r8d, r14d
        mov     r9d, esi
        mov     qword outarg(5), 8
        call    gfx_rrect
.draw:  mov     rax, rbx
        imul    rax, TR_SIZE
        add     rax, [q_up+LS_PTR]
        mov     rcx, rax
        mov     edx, r13d
        mov     r8d, r12d
        mov     r9d, r14d
        mov     outarg(5), rsi
        mov     qword outarg(6), H_QUEUE_ROW
        mov     outarg(7), rbx
        call    draw_mini_track
.nx:    inc     rbx
        jmp     .row
.end:   call    ui_unclip
.out:   EPROC

; ---------------------------------------------------------------- full-screen Now Playing
%define fs_cx    loc(0)
%define fs_cy    loc(1)
%define fs_cs    loc(2)
%define fs_ix    loc(3)
%define fs_iy    loc(4)
%define fs_iw    loc(5)
%define fs_pad   loc(6)

PROC paint_fullscreen, 12
        cmp     dword [fullscreen], 0
        je      .out
        ; ambient background tinted from the cover (cached per track)
        mov     eax, [np_gen]
        cmp     eax, [fs_gen]
        je      .tinted
        mov     [fs_gen], eax
        mov     rcx, [np_img_l]
        test    rcx, rcx
        jnz     .gotu
        mov     rcx, [np_img_s]
.gotu:  call    img_get
        mov     rcx, rax
        call    img_avg_color
        mov     [fs_tint], eax
.tinted:
        mov     eax, [fs_tint]
        shr     eax, 1
        and     eax, 0x007F7F7F
        mov     ecx, [th+4*T_BG]
        shr     ecx, 1
        and     ecx, 0x007F7F7F
        add     eax, ecx
        or      eax, 0xFF000000
        mov     r8d, [th+4*T_BG]
        xor     ecx, ecx
        xor     edx, edx
        mov     r9d, [ui_h]
        mov     outarg(5), rax
        mov     eax, r8d
        mov     outarg(6), rax
        mov     r8d, [ui_w]
        call    gfx_gradient
        HIT     0, 0, dword [ui_w], dword [ui_h], H_SHELL, 0
        S       40
        mov     fs_pad, rax
        ; layout
        mov     eax, [ui_w]
        imul    eax, 100
        mov     ecx, [ui_h]
        imul    ecx, 125
        cmp     eax, ecx
        jl      .narrow
        ; --- wide: cover left, info right
        mov     eax, [ui_w]
        sub     eax, dword fs_pad
        sub     eax, dword fs_pad
        imul    eax, 44
        xor     edx, edx
        mov     ecx, 100
        div     ecx
        mov     ebx, eax
        S       240
        mov     ecx, [ui_h]
        sub     ecx, eax
        cmp     ebx, ecx
        cmova   ebx, ecx
        S       160
        cmp     ebx, eax
        jae     .cs1
        mov     ebx, eax
.cs1:   mov     fs_cs, rbx
        S       64
        mov     esi, eax                        ; gap
        S       520
        mov     edi, [ui_w]
        sub     edi, dword fs_pad
        sub     edi, dword fs_pad
        sub     edi, ebx
        sub     edi, esi
        cmp     edi, eax
        cmova   edi, eax                        ; info width
        mov     fs_iw, rdi
        lea     eax, [rbx+rsi]
        add     eax, edi
        mov     ecx, [ui_w]
        sub     ecx, eax
        shr     ecx, 1
        mov     fs_cx, rcx
        add     ecx, ebx
        add     ecx, esi
        mov     fs_ix, rcx
        mov     eax, [ui_h]
        sub     eax, ebx
        shr     eax, 1
        mov     fs_cy, rax
        S       360
        mov     ecx, [ui_h]
        sub     ecx, eax
        shr     ecx, 1
        mov     fs_iy, rcx
        jmp     .draw
.narrow:
        mov     eax, [ui_w]
        sub     eax, dword fs_pad
        sub     eax, dword fs_pad
        mov     ebx, eax
        mov     eax, [ui_h]
        imul    eax, 38
        xor     edx, edx
        mov     ecx, 100
        div     ecx
        cmp     ebx, eax
        cmova   ebx, eax
        mov     fs_cs, rbx
        mov     eax, [ui_w]
        sub     eax, ebx
        shr     eax, 1
        mov     fs_cx, rax
        S       80
        mov     fs_cy, rax
        mov     rax, fs_pad
        mov     fs_ix, rax
        mov     eax, [ui_w]
        sub     eax, dword fs_pad
        sub     eax, dword fs_pad
        mov     fs_iw, rax
        mov     eax, dword fs_cy
        add     eax, ebx
        S       24
        add     eax, dword fs_cy
        add     eax, ebx
        mov     fs_iy, rax
.draw:  ; close button
        SETCOL  T_FG
        S       44
        mov     r12d, eax
        S       24
        mov     r13d, eax
        S       20
        IBTN    ic_chevd, r13d, r13d, r12d, H_FS_CLOSE, 0, eax, 0, 0
        ; cover
        cmp     dword [np_valid], 0
        jne     .have
        SETFONT F_H2
        SETCOL  T_MUTED_FG
        SETALIGN 1
        TXTL    w_nothing, 0, 0, dword [ui_w], dword [ui_h]
        SETALIGN 0
        jmp     .out
.have:  mov     rcx, [np_img_l]
        test    rcx, rcx
        jnz     .gotl
        mov     rcx, [np_img_s]
.gotl:  mov     edx, dword fs_cx
        mov     r8d, dword fs_cy
        mov     r9d, dword fs_cs
        S       18
        mov     outarg(5), rax
        call    draw_cover
        ; info column
        mov     r12d, dword fs_ix
        mov     r13d, dword fs_iy
        mov     r14d, dword fs_iw
        SETFONT F_CAPTION
        SETCOL  T_MUTED_FG
        S       18
        mov     ebx, eax
        TXTL    w_np_cap, r12d, r13d, r14d, ebx
        S       28
        add     r13d, eax
        SETFONT F_HERO
        SETCOL  T_FG
        S       62
        mov     esi, eax
        mov     rcx, [np_title]
        TXT     rcx, r12d, r13d, r14d, esi
        S       66
        add     r13d, eax
        SETFONT F_H2
        SETCOL  T_FG
        S       34
        mov     esi, eax
        mov     rcx, [np_artist]
        TXT     rcx, r12d, r13d, r14d, esi
        S       40
        add     r13d, eax
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        S       24
        mov     esi, eax
        mov     rcx, [np_album]
        TXT     rcx, r12d, r13d, r14d, esi
        S       44
        add     r13d, eax
        ; seek bar + times
        S       10
        lea     edx, [r13+rax]
        mov     ecx, r12d
        mov     r8d, r14d
        call    draw_seekbar
        SETFONT F_CAPTION
        SETCOL  T_MUTED_FG
        S       22
        lea     r15d, [r13+rax]
        S       18
        mov     ebx, eax
        call    np_position
        mov     edx, eax
        lea     rcx, loc(8)
        call    w_fmt_time
        lea     rcx, loc(8)
        mov     edx, r12d
        mov     r8d, r15d
        S       60
        mov     r9d, eax
        mov     outarg(5), rbx
        call    gfx_text
        SETALIGN 2
        lea     rcx, loc(8)
        mov     edx, [np_dur]
        call    w_fmt_time
        S       60
        mov     r9d, eax
        lea     edx, [r12+r14]
        sub     edx, eax
        lea     rcx, loc(8)
        mov     r8d, r15d
        mov     outarg(5), rbx
        call    gfx_text
        SETALIGN 0
        S       56
        add     r13d, eax
        ; transport + volume
        mov     ecx, r14d
        shr     ecx, 1
        add     ecx, r12d
        mov     edx, r13d
        S       52
        mov     r8d, eax
        S       72
        mov     r9d, eax
        call    draw_transport
        S       72
        add     r13d, eax
        S       36
        add     r13d, eax
        S       200
        mov     esi, eax                        ; slider width
        mov     eax, r14d
        sub     eax, esi
        shr     eax, 1
        add     eax, r12d
        mov     edi, eax                        ; slider x
        mov     ecx, edi
        mov     edx, r13d
        mov     r8d, esi
        call    draw_volume
        SETCOL  T_MUTED_FG
        S       20
        mov     ebx, eax
        shr     eax, 1
        sub     r13d, eax
        S       30
        mov     ecx, edi
        sub     ecx, eax
        mov     edx, r13d
        mov     r8d, ebx
        lea     r9, [ic_volume]
        call    icon_draw
.out:   EPROC

; ---------------------------------------------------------------- toast
PROC paint_toast, 6
        mov     rcx, [toast_text]
        test    rcx, rcx
        jz      .out
        call    GetTickCount64
        cmp     rax, [toast_until]
        jae     .gone
        SETFONT F_BODY_B
        mov     rcx, [toast_text]
        call    gfx_text_w
        mov     ebx, eax
        S       36
        lea     r12d, [rbx+rax]                 ; width = text + 2 * 18
        S       44
        mov     r13d, eax                       ; height
        mov     eax, [ui_w]
        sub     eax, r12d
        shr     eax, 1
        mov     r14d, eax                       ; x
        S       16
        mov     r15d, [lay_bar_y]
        sub     r15d, r13d
        sub     r15d, eax                       ; y
        SETCOL  T_POPOVER
        mov     eax, r13d
        shr     eax, 1
        mov     outarg(5), rax
        mov     ecx, r14d
        mov     edx, r15d
        mov     r8d, r12d
        mov     r9d, r13d
        call    gfx_rrect_fill_border
        SETCOL  T_FG
        SETALIGN 1
        mov     rcx, [toast_text]
        TXT     rcx, r14d, r15d, r12d, r13d
        SETALIGN 0
        jmp     .out
.gone:  mov     rcx, [toast_text]
        call    mem_free
        mov     qword [toast_text], 0
.out:   EPROC

; popover surface with a hairline border: ecx = x, edx = y, r8d = w, r9d = h, [rbp+48] = radius
PROC gfx_rrect_fill_border, 8
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        mov     eax, stk5
        mov     loc(4), rax
        mov     outarg(5), rax
        call    gfx_rrect
        SETCOL  T_BORDER
        mov     rax, loc(4)
        mov     outarg(5), rax
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        call    gfx_rrect_line
        EPROC

; rcx = UTF-16 message: shown for three seconds
PROC ui_toast, 1
        mov     loc(0), rcx
        mov     rcx, [toast_text]
        call    mem_free
        mov     rcx, loc(0)
        call    w_dup
        mov     [toast_text], rax
        call    GetTickCount64
        add     rax, 3500
        mov     [toast_until], rax
        EPROC
