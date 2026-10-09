; ui_widgets.asm - reusable painters: covers, track tables, card grids, pills, buttons.
; Every painter also appends its clickable rectangles to the hit list.

section .bss
lay_main_x:     resd 1                  ; main content area (between sidebar and queue)
lay_main_w:     resd 1
lay_main_h:     resd 1                  ; = player bar top
lay_pad:        resd 1
lay_q_x:        resd 1
lay_q_w:        resd 1                  ; visible width of the queue panel (it slides in and out)
lay_q_full:     resd 1                  ; its full width
lay_sb_w:       resd 1
lay_bar_y:      resd 1
lay_bar_h:      resd 1

section .data
WSTR w_hash, "#"
WSTR w_title_col, "TITLE"
WSTR w_album_col, "ALBUM"
WSTR w_time_col, "TIME"

section .text

; S n : eax = n scaled by the UI scale factor (clobbers eax, flags)
%macro S 1
        mov     eax, %1
        imul    eax, [ui_scale]
        shr     eax, 16
%endmacro

; Draw text: operands must not use rcx/rdx/r8/r9/rax.
%macro TXT 5                            ; TXT ptr, x, y, w, h
        mov     rcx, %1
        mov     edx, %2
        mov     r8d, %3
        mov     r9d, %4
        mov     eax, %5
        mov     outarg(5), rax
        call    gfx_text
%endmacro

%macro TXTL 5                           ; TXTL label, x, y, w, h
        lea     rcx, [%1]
        mov     edx, %2
        mov     r8d, %3
        mov     r9d, %4
        mov     eax, %5
        mov     outarg(5), rax
        call    gfx_text
%endmacro

%macro RECT 4
        mov     ecx, %1
        mov     edx, %2
        mov     r8d, %3
        mov     r9d, %4
        call    gfx_rect
%endmacro

%macro RRECT 5                          ; RRECT x, y, w, h, radius
        mov     eax, %5
        mov     outarg(5), rax
        mov     ecx, %1
        mov     edx, %2
        mov     r8d, %3
        mov     r9d, %4
        call    gfx_rrect
%endmacro

; ---------------------------------------------------------------- clip
; ecx = x, edx = y, r8d = w, r9d = h : clips both drawing and hit-testing
PROC ui_clip, 0
        mov     [clip_x0], ecx
        mov     [clip_y0], edx
        lea     eax, [rcx+r8]
        mov     [clip_x1], eax
        lea     eax, [rdx+r9]
        mov     [clip_y1], eax
        call    gfx_clip
        EPROC

PROC ui_unclip, 0
        mov     dword [clip_x0], 0
        mov     dword [clip_y0], 0
        mov     eax, [ui_w]
        mov     [clip_x1], eax
        mov     eax, [ui_h]
        mov     [clip_y1], eax
        call    gfx_unclip
        EPROC

; ---------------------------------------------------------------- layout for the frame
PROC lay_compute, 0
        xor     eax, eax
        cmp     qword [banner_text], 0
        je      .nob
        S       48
.nob:   mov     [banner_h], eax
        MET     eax, M_SB
        mov     [lay_sb_w], eax
        MET     eax, M_BAR
        mov     [lay_bar_h], eax
        mov     ecx, [ui_h]
        sub     ecx, eax
        mov     [lay_bar_y], ecx
        mov     [lay_main_h], ecx
        MET     eax, M_PAD
        mov     [lay_pad], eax
        mov     eax, [lay_sb_w]
        mov     [lay_main_x], eax
        mov     ecx, [ui_w]
        sub     ecx, eax
        cmp     dword [page], PAGE_LOGIN
        jne     .withsb
        mov     dword [lay_main_x], 0
        mov     ecx, [ui_w]
        mov     eax, [ui_h]
        mov     [lay_main_h], eax         ; login covers the whole window
.withsb:
        mov     [lay_main_w], ecx
        mov     eax, [ui_w]
        mov     [lay_q_x], eax
        mov     dword [lay_q_w], 0
        MET     eax, M_QW
        mov     [lay_q_full], eax
        cmp     dword [page], PAGE_LOGIN
        je      .out
        mov     ecx, AC_QUEUE                   ; the panel slides in from the right edge
        call    anim_get
        imul    eax, [lay_q_full]
        shr     eax, 8
        jz      .out
        mov     [lay_q_w], eax
        mov     ecx, [ui_w]
        sub     ecx, eax
        mov     [lay_q_x], ecx
        sub     [lay_main_w], eax
.out:   EPROC

; ---------------------------------------------------------------- cover
; rcx = URL (UTF-8, may be 0), edx = x, r8d = y, r9d = size, [rbp+48] = corner radius
PROC draw_cover, 6
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        mov     eax, stk5
        mov     loc(4), rax
        call    img_get
        test    rax, rax
        jz      .ph
        mov     rcx, rax
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        mov     outarg(5), r9
        mov     rax, loc(4)
        mov     outarg(6), rax
        call    gfx_image_round
        jmp     .out
.ph:    SETCOL  T_SURFACE
        mov     rax, loc(4)
        mov     outarg(5), rax
        mov     ecx, dword loc(1)
        mov     edx, dword loc(2)
        mov     r8d, dword loc(3)
        mov     r9d, r8d
        call    gfx_rrect
.out:   EPROC

; ---------------------------------------------------------------- pills & buttons
; rcx = label, edx = x, r8d = y, r9d = selected, [rbp+48] = id, [rbp+56] = arg -> eax = width used
PROC draw_pill, 8
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        mov     eax, stk5
        mov     loc(4), rax
        mov     eax, stk6
        mov     loc(5), rax
        SETFONT F_BODY_B
        mov     rcx, loc(0)
        call    gfx_text_w
        mov     ebx, eax                        ; text width
        S       36
        mov     esi, eax                        ; height
        S       18
        lea     edi, [rbx+rax*2]                ; width = text + 2 * padding
        cmp     dword loc(3), 0
        je      .off
        SETCOL  T_PRIMARY
        jmp     .fill
.off:   mov     ecx, dword loc(4)
        mov     edx, dword loc(5)
        call    anim_hv                         ; surface fades into the pressed colour under the mouse
        SETCOL_MIX T_SURFACE, T_ACTIVE, eax
.fill:  mov     eax, esi
        shr     eax, 1
        mov     outarg(5), rax
        mov     ecx, dword loc(1)
        mov     edx, dword loc(2)
        mov     r8d, edi
        mov     r9d, esi
        call    gfx_rrect
        cmp     dword loc(3), 0
        je      .t1
        SETCOL  T_PRIMARY_FG
        jmp     .t2
.t1:    SETCOL  T_FG
.t2:    SETALIGN 1
        SETFONT F_BODY_B
        mov     rcx, loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, edi
        mov     outarg(5), rsi
        call    gfx_text
        SETALIGN 0
        mov     eax, dword loc(4)
        mov     [rsp+32], rax
        mov     eax, dword loc(5)
        mov     [rsp+40], rax
        mov     ecx, dword loc(1)
        mov     edx, dword loc(2)
        mov     r8d, edi
        mov     r9d, esi
        call    hit_add
        mov     eax, edi
        EPROC

; Filled pill button with a centred label.
; rcx = label, edx = x, r8d = y, r9d = w, [rbp+48] = h, [rbp+56] = id, [rbp+64] = arg,
; [rbp+72] = style (0 primary, 1 surface, 2 danger)
PROC draw_button, 6
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        mov     eax, stk5
        mov     loc(4), rax
        mov     eax, [rbp+72]
        cmp     eax, 1
        je      .sf
        cmp     eax, 2
        je      .dg
        mov     esi, T_PRIMARY
        mov     ebx, T_PRIMARY_FG
        jmp     .go
.sf:    mov     esi, T_SURFACE
        mov     ebx, T_FG
        jmp     .go
.dg:    mov     esi, T_DANGER
        mov     ebx, T_FG
.go:    mov     ecx, [rbp+56]
        mov     edx, [rbp+64]
        call    anim_hv                         ; hover fade 0 .. 256
        mov     r12d, eax
        cmp     dword [rbp+72], 0
        jne     .hv
        imul    eax, 39                         ; primary: opaque -> alpha 0xD8 under the mouse
        shr     eax, 8
        mov     edx, 256
        sub     edx, eax
        SETCOL_F T_PRIMARY, edx
        jmp     .draw
.hv:    lea     rax, [th]
        mov     ecx, [rax+rsi*4]
        mov     edx, [th+4*T_ACTIVE]
        mov     r8d, r12d
        call    col_lerp
        mov     ecx, eax
        call    gfx_color
.draw:  mov     rax, loc(4)
        shr     eax, 1
        mov     outarg(5), rax
        mov     ecx, dword loc(1)
        mov     edx, dword loc(2)
        mov     r8d, dword loc(3)
        mov     r9d, dword loc(4)
        call    gfx_rrect
        lea     rax, [th]
        mov     ecx, [rax+rbx*4]
        call    gfx_color
        SETALIGN 1
        SETFONT F_BODY_B
        mov     rcx, loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        mov     rax, loc(4)
        mov     outarg(5), rax
        call    gfx_text
        SETALIGN 0
        mov     eax, [rbp+56]
        mov     [rsp+32], rax
        mov     eax, [rbp+64]
        mov     [rsp+40], rax
        mov     ecx, dword loc(1)
        mov     edx, dword loc(2)
        mov     r8d, dword loc(3)
        mov     r9d, dword loc(4)
        call    hit_add
        EPROC

; Round icon button: rcx = icon program, edx = x, r8d = y, r9d = box size, [rbp+48] = id, [rbp+56] = arg,
; [rbp+64] = icon size, [rbp+72] = filled circle colour token + 1 (0 = none),
; [rbp+80] = icon colour token + 1 (0 = keep the current colour)
PROC draw_icon_button, 6
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        mov     rax, [rbp+72]
        test    eax, eax
        jz      .nofill
        dec     eax
        lea     rcx, [th]
        mov     ecx, [rcx+rax*4]
        call    gfx_color
        mov     ecx, dword loc(1)
        mov     edx, dword loc(2)
        mov     r8d, dword loc(3)
        mov     r9d, r8d
        call    gfx_ellipse
        jmp     .icon
.nofill:
        mov     ecx, [rbp+48]
        mov     edx, [rbp+56]
        call    anim_hv
        test    eax, eax
        jz      .icon
        SETCOL_F T_HOVER, eax
        mov     ecx, dword loc(1)
        mov     edx, dword loc(2)
        mov     r8d, dword loc(3)
        mov     r9d, r8d
        call    gfx_ellipse
.icon:  mov     rax, [rbp+80]
        test    eax, eax
        jz      .keepcol
        dec     eax
        lea     rcx, [th]
        mov     ecx, [rcx+rax*4]
        call    gfx_color
.keepcol:
        mov     eax, dword loc(3)               ; centre the icon in the box
        sub     eax, [rbp+64]
        shr     eax, 1
        mov     r12d, eax
        mov     ecx, dword loc(1)
        add     ecx, r12d
        mov     edx, dword loc(2)
        add     edx, r12d
        mov     r8d, [rbp+64]
        mov     r9, loc(0)
        call    icon_draw
        mov     eax, [rbp+48]
        mov     [rsp+32], rax
        mov     eax, [rbp+56]
        mov     [rsp+40], rax
        mov     ecx, dword loc(1)
        mov     edx, dword loc(2)
        mov     r8d, dword loc(3)
        mov     r9d, r8d
        call    hit_add
        EPROC

; ---------------------------------------------------------------- track table
%define dt_list  loc(0)
%define dt_src   loc(1)
%define dt_x     loc(2)
%define dt_y0    loc(3)
%define dt_w     loc(4)
%define dt_hdr   loc(5)
%define dt_rowh  loc(6)
%define dt_hh    loc(7)
%define dt_tx    loc(10)                ; title column x / width
%define dt_tw    loc(11)
%define dt_ax    loc(12)                ; album column x / width (0 = hidden)
%define dt_aw    loc(13)
%define dt_cs    loc(14)                ; cover size
%define dt_dw    loc(15)                ; duration column width
%define dt_buf   loc(9)                 ; 16-byte wide-char scratch: loc(9)..loc(8)

; rcx = List* of Track, edx = source id, r8d = x, r9d = y, [rbp+48] = width, [rbp+56] = show header (0/1)
; -> eax = y below the table
PROC draw_tracks, 16
        mov     dt_list, rcx
        mov     dt_src, rdx
        mov     dt_x, r8
        mov     dt_y0, r9
        mov     eax, stk5
        mov     dt_w, rax
        mov     eax, stk6
        mov     dt_hdr, rax
        MET     eax, M_ROW
        mov     dt_rowh, rax
        S       30
        mov     dt_hh, rax
        S       40
        mov     dt_cs, rax
        S       64
        mov     dt_dw, rax
        ; columns
        S       44
        add     eax, dword dt_x
        S       44
        mov     ecx, eax
        S       14
        add     ecx, eax
        add     ecx, dword dt_cs
        add     ecx, dword dt_x
        mov     dword dt_tx, ecx
        S       640
        mov     qword dt_ax, 0
        mov     qword dt_aw, 0
        cmp     dword dt_w, eax
        jl      .narrow
        mov     eax, dword dt_w
        imul    eax, 58
        xor     edx, edx
        mov     ecx, 100
        div     ecx
        add     eax, dword dt_x
        mov     dword dt_ax, eax
        mov     eax, dword dt_w
        imul    eax, 24
        xor     edx, edx
        mov     ecx, 100
        div     ecx
        mov     dword dt_aw, eax
        mov     eax, dword dt_ax
        sub     eax, dword dt_tx
        S       16
        mov     ecx, eax
        mov     eax, dword dt_ax
        sub     eax, dword dt_tx
        sub     eax, ecx
        mov     dword dt_tw, eax
        jmp     .cols_done
.narrow:
        mov     eax, dword dt_x
        add     eax, dword dt_w
        sub     eax, dword dt_dw
        sub     eax, dword dt_tx
        S       24
        mov     ecx, eax
        mov     eax, dword dt_x
        add     eax, dword dt_w
        sub     eax, dword dt_dw
        sub     eax, dword dt_tx
        sub     eax, ecx
        mov     dword dt_tw, eax
.cols_done:
        mov     rax, dt_list
        mov     r12, [rax+LS_COUNT]
        mov     r14d, dword dt_y0               ; running y
        cmp     dword dt_hdr, 0
        je      .rows
        SETCOL  T_HEAD_FG
        SETFONT F_CAPTION
        SETALIGN 1
        TXTL    w_hash, dword dt_x, r14d, 36, dword dt_hh
        SETALIGN 0
        TXTL    w_title_col, dword dt_tx, r14d, 300, dword dt_hh
        cmp     dword dt_ax, 0
        je      .noalb
        TXTL    w_album_col, dword dt_ax, r14d, dword dt_aw, dword dt_hh
.noalb: SETALIGN 2
        mov     eax, dword dt_x
        add     eax, dword dt_w
        sub     eax, dword dt_dw
        mov     edx, eax
        S       14
        sub     edx, eax
        TXTL    w_time_col, edx, r14d, dword dt_dw, dword dt_hh
        SETALIGN 0
        SETCOL  T_ROW_BORDER
        mov     eax, dword dt_hh
        lea     edx, [r14+rax-1]
        RECT    dword dt_x, edx, dword dt_w, 1
        mov     eax, dword dt_hh
        add     r14d, eax
.rows:  xor     ebx, ebx
.row:   cmp     rbx, r12
        jae     .done
        mov     eax, dword dt_rowh
        imul    eax, ebx
        lea     r13d, [r14+rax]                 ; ry
        add     eax, dword dt_rowh
        add     eax, r14d
        jle     .next                           ; above the viewport
        cmp     r13d, [lay_main_h]
        jge     .done                           ; below the viewport
        mov     rax, rbx
        imul    rax, TR_SIZE
        mov     rcx, dt_list
        add     rax, [rcx+LS_PTR]
        mov     rsi, rax                        ; Track*
        xor     edi, edi                        ; edi = is the current track
        cmp     dword [np_valid], 0
        je      .notcur
        mov     rcx, [np_uri]
        mov     rdx, [rsi+TR_URI]
        test    rcx, rcx
        jz      .notcur
        test    rdx, rdx
        jz      .notcur
        call    u8_eq
        mov     edi, eax
.notcur:
        mov     eax, dword dt_src
        shl     eax, 16
        or      eax, ebx
        mov     r15d, eax                       ; hit arg
        test    edi, edi
        jz      .nplay
        SETCOL  T_ROW_ACTIVE
        RECT    dword dt_x, r13d, dword dt_w, dword dt_rowh
        SETCOL  T_ACCENT
        S       3
        mov     r8d, eax
        RECT    dword dt_x, r13d, r8d, dword dt_rowh
        jmp     .cols
.nplay: mov     ecx, H_TRACK                    ; the heart belongs to the row (anim_step folds H_LIKE into H_TRACK)
        mov     edx, r15d
        call    anim_hv
        test    eax, eax
        jz      .cols
        SETCOL_F T_HOVER, eax
        RRECT   dword dt_x, r13d, dword dt_w, dword dt_rowh, 8
.cols:  SETFONT F_SMALL
        SETALIGN 1
        SETCOL  T_MUTED_FG
        test    edi, edi
        jz      .num
        SETCOL  T_ACCENT
.num:   lea     rcx, dt_buf
        lea     edx, [rbx+1]
        call    w_put_u64
        mov     word [rax], 0
        lea     rcx, dt_buf
        TXT     rcx, dword dt_x, r13d, 36, dword dt_rowh
        SETALIGN 0
        ; cover, vertically centred
        mov     eax, dword dt_rowh
        sub     eax, dword dt_cs
        shr     eax, 1
        add     eax, r13d
        mov     r8d, eax
        S       44
        mov     edx, dword dt_x
        add     edx, eax
        mov     r9d, dword dt_cs
        mov     rcx, [rsi+TR_IMG_S]
        mov     qword outarg(5), 6
        call    draw_cover
        ; title / artist (an unplayable track is shown muted)
        SETFONT F_BODY
        SETCOL  T_FG
        test    dword [rsi+TR_FLAGS], TF_UNPLAYABLE
        jz      .tcol
        SETCOL  T_MUTED_FG
.tcol:
        mov     eax, dword dt_rowh
        shr     eax, 1
        S       19
        mov     ecx, eax
        mov     eax, dword dt_rowh
        shr     eax, 1
        sub     eax, ecx
        add     eax, r13d
        mov     r8d, eax
        mov     edx, dword dt_tx
        mov     r9d, dword dt_tw
        mov     rcx, [rsi+TR_TITLE]
        S       19
        mov     outarg(5), rax
        call    gfx_text
        SETFONT F_SMALL
        SETCOL  T_MUTED_FG
        mov     eax, dword dt_rowh
        shr     eax, 1
        add     eax, r13d
        inc     eax
        mov     r8d, eax
        mov     edx, dword dt_tx
        mov     r9d, dword dt_tw
        mov     rcx, [rsi+TR_ARTIST]
        S       17
        mov     outarg(5), rax
        call    gfx_text
        cmp     dword dt_ax, 0
        je      .dur
        mov     rcx, [rsi+TR_ALBUM]
        TXT     rcx, dword dt_ax, r13d, dword dt_aw, dword dt_rowh
.dur:   lea     rcx, dt_buf                     ; duration, right aligned
        mov     edx, [rsi+TR_DUR]
        call    w_fmt_time
        SETALIGN 2
        mov     eax, dword dt_x
        add     eax, dword dt_w
        sub     eax, dword dt_dw
        mov     edx, eax
        S       14
        sub     edx, eax
        lea     rcx, dt_buf
        TXT     rcx, edx, r13d, dword dt_dw, dword dt_rowh
        SETALIGN 0
        mov     eax, H_TRACK
        mov     [rsp+32], rax
        mov     eax, r15d
        mov     [rsp+40], rax
        mov     ecx, dword dt_x
        mov     edx, r13d
        mov     r8d, dword dt_w
        mov     r9d, dword dt_rowh
        call    hit_add
        ; heart, just left of the duration; its outline shows on the hovered row, a saved track always shows it
        S       28
        mov     r8d, eax                        ; box
        S       14
        mov     ecx, dword dt_x
        add     ecx, dword dt_w
        sub     ecx, dword dt_dw
        sub     ecx, eax
        sub     ecx, r8d
        mov     edx, dword dt_rowh
        sub     edx, r8d
        shr     edx, 1
        add     edx, r13d
        mov     r9d, r15d
        mov     rax, [rsi+TR_URI]
        mov     outarg(5), rax
        xor     eax, eax
        cmp     dword [hover_id], H_TRACK
        je      .hv1
        cmp     dword [hover_id], H_LIKE
        jne     .hv2
.hv1:   cmp     dword [hover_arg], r15d
        sete    al
.hv2:   mov     outarg(6), rax
        call    draw_heart
.next:  inc     rbx
        jmp     .row
.done:  mov     eax, dword dt_rowh
        imul    eax, r12d
        add     eax, dword dt_y0
        cmp     dword dt_hdr, 0
        je      .ret
        add     eax, dword dt_hh
.ret:   EPROC

; ---------------------------------------------------------------- card grid
%define cd_list  loc(0)
%define cd_src   loc(1)
%define cd_x     loc(2)
%define cd_y0    loc(3)
%define cd_w     loc(4)
%define cd_max   loc(5)
%define cd_cw    loc(6)                 ; card width (= cover size)
%define cd_ch    loc(7)                 ; card height
%define cd_cx    loc(8)
%define cd_cy    loc(9)
%define cd_pb    loc(10)                ; play button size

; rcx = List* of Card, edx = source id, r8d = x, r9d = y, [rbp+48] = width, [rbp+56] = max cards (0 = all)
; -> eax = y below the grid
PROC draw_cards, 12
        mov     cd_list, rcx
        mov     cd_src, rdx
        mov     cd_x, r8
        mov     cd_y0, r9
        mov     eax, stk5
        mov     cd_w, rax
        mov     eax, stk6
        mov     cd_max, rax
        mov     r12, [rcx+LS_COUNT]
        mov     rax, cd_max
        test    eax, eax
        jz      .cnt
        cmp     r12, rax
        jbe     .cnt
        mov     r12, rax
.cnt:   test    r12, r12
        jz      .none
        MET     r13d, M_GAP
        MET     eax, M_CARD
        lea     ecx, [rax+r13]
        mov     eax, dword cd_w
        add     eax, r13d
        xor     edx, edx
        div     ecx
        cmp     eax, 1
        jae     .cols
        mov     eax, 1
.cols:  mov     r14d, eax                       ; columns
        test    dword cd_max, 0x80000000        ; bit 31: show one row only
        jz      .rowsok
        cmp     r12d, r14d
        jbe     .rowsok
        mov     r12d, r14d
.rowsok:
        mov     eax, r14d
        dec     eax
        imul    eax, r13d
        mov     ecx, dword cd_w
        sub     ecx, eax
        mov     eax, ecx
        xor     edx, edx
        div     r14d
        mov     cd_cw, rax
        S       58
        add     eax, dword cd_cw
        mov     cd_ch, rax
        S       44
        mov     cd_pb, rax
        xor     ebx, ebx
.card:  cmp     rbx, r12
        jae     .end
        mov     eax, ebx
        xor     edx, edx
        div     r14d                            ; eax = row, edx = col
        mov     r15d, edx
        mov     ecx, dword cd_ch
        add     ecx, r13d
        imul    ecx, eax
        add     ecx, dword cd_y0
        mov     dword cd_cy, ecx
        mov     eax, dword cd_cw
        add     eax, r13d
        imul    eax, r15d
        add     eax, dword cd_x
        mov     dword cd_cx, eax
        mov     eax, dword cd_cy                ; skip cards outside the viewport
        add     eax, dword cd_ch
        jle     .nextc
        mov     eax, dword cd_cy
        cmp     eax, [lay_main_h]
        jge     .nextc
        mov     rax, rbx
        imul    rax, CD_SIZE
        mov     rcx, cd_list
        add     rax, [rcx+LS_PTR]
        mov     rsi, rax
        mov     eax, dword cd_src
        shl     eax, 16
        or      eax, ebx
        mov     edi, eax                        ; hit arg
        mov     ecx, H_CARD                     ; r15d = hover fade 0 .. 256 (the play button belongs to the card)
        mov     edx, edi
        call    anim_hv
        mov     r15d, eax
        mov     eax, [rsi+CD_KIND]
        mov     rcx, [rsi+CD_IMG_M]
        mov     edx, dword cd_cx
        mov     r8d, dword cd_cy
        mov     r9d, dword cd_cw
        cmp     eax, KIND_ARTIST
        jne     .sq
        mov     eax, dword cd_cw
        shr     eax, 1
        jmp     .rad
.sq:    S       10
.rad:   mov     outarg(5), rax
        call    draw_cover
        SETFONT F_BODY_B
        SETCOL  T_FG
        S       10
        mov     r8d, dword cd_cy
        add     r8d, dword cd_cw
        add     r8d, eax
        mov     edx, dword cd_cx
        mov     r9d, dword cd_cw
        mov     rcx, [rsi+CD_NAME]
        S       22
        mov     outarg(5), rax
        call    gfx_text
        SETFONT F_SMALL
        SETCOL  T_MUTED_FG
        S       32
        mov     r8d, dword cd_cy
        add     r8d, dword cd_cw
        add     r8d, eax
        mov     edx, dword cd_cx
        mov     r9d, dword cd_cw
        mov     rcx, [rsi+CD_SUB]
        S       18
        mov     outarg(5), rax
        call    gfx_text
        mov     eax, H_CARD                     ; whole card first, so the play button added later wins
        mov     [rsp+32], rax
        mov     [rsp+40], rdi
        mov     ecx, dword cd_cx
        mov     edx, dword cd_cy
        mov     r8d, dword cd_cw
        mov     r9d, dword cd_ch
        call    hit_add
        test    r15d, r15d
        jz      .nextc
        cmp     dword [rsi+CD_KIND], KIND_ARTIST
        je      .nextc
        S       10                              ; hover play button, bottom-right of the cover
        mov     ecx, dword cd_cx
        add     ecx, dword cd_cw
        sub     ecx, dword cd_pb
        sub     ecx, eax
        mov     edx, dword cd_cy
        add     edx, dword cd_cw
        sub     edx, dword cd_pb
        sub     edx, eax
        mov     dword cd_cx, ecx
        mov     dword cd_cy, edx
        mov     [gfx_alpha], r15d               ; the play button fades in
        SETCOL  T_PRIMARY
        mov     ecx, dword cd_cx
        mov     edx, dword cd_cy
        mov     r8d, dword cd_pb
        mov     r9d, r8d
        call    gfx_ellipse
        SETCOL  T_PRIMARY_FG
        mov     eax, dword cd_pb
        shr     eax, 2
        mov     ecx, dword cd_cx
        add     ecx, eax
        mov     edx, dword cd_cy
        add     edx, eax
        mov     r8d, dword cd_pb
        shr     r8d, 1
        lea     r9, [ic_play]
        call    icon_draw
        mov     dword [gfx_alpha], 256
        mov     eax, H_CARD_PLAY
        mov     [rsp+32], rax
        mov     [rsp+40], rdi
        mov     ecx, dword cd_cx
        mov     edx, dword cd_cy
        mov     r8d, dword cd_pb
        mov     r9d, r8d
        call    hit_add
.nextc: inc     rbx
        jmp     .card
.end:   mov     eax, r12d                       ; rows used
        dec     eax
        xor     edx, edx
        div     r14d
        inc     eax
        mov     ecx, dword cd_ch
        add     ecx, r13d
        imul    eax, ecx
        add     eax, dword cd_y0
        jmp     .ret
.none:  mov     eax, dword cd_y0
.ret:   EPROC

; section heading. rcx = label, edx = x, r8d = y, r9d = w -> eax = y below the heading
PROC draw_section, 4
        mov     loc(0), r8
        mov     loc(1), rcx
        mov     loc(2), rdx
        mov     loc(3), r9
        SETFONT F_H2
        SETCOL  T_FG
        SETALIGN 0
        mov     rcx, loc(1)
        mov     edx, dword loc(2)
        mov     r8d, dword loc(0)
        mov     r9d, dword loc(3)
        S       36
        mov     outarg(5), rax
        call    gfx_text
        S       44
        add     eax, dword loc(0)
        EPROC

; IBTN prog, x, y, box, id, arg, iconsize, fill, iconcol   (operands: constants, locals or callee-saved regs)
%macro IBTN 9
        mov     eax, %5
        mov     outarg(5), rax
        mov     eax, %6
        mov     outarg(6), rax
        mov     eax, %7
        mov     outarg(7), rax
        mov     eax, %8
        mov     outarg(8), rax
        mov     eax, %9
        mov     outarg(9), rax
        lea     rcx, [%1]
        mov     edx, %2
        mov     r8d, %3
        mov     r9d, %4
        call    draw_icon_button
%endmacro
