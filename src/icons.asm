; icons.asm - tiny vector icon interpreter. Icons are programs over a 0..100 grid, drawn with the
; current colour.  Ops:
;   1 LINE x1 y1 x2 y2           stroked, round caps
;   2 POLY n x y ...             filled polygon
;   3 RRECT x y w h r            filled rounded rect
;   4 RING x y w h               stroked ellipse
;   5 DISC x y w h               filled ellipse
;   6 RRECTL x y w h r           stroked rounded rect
;   7 ARC x y w h a0/2 sweep/2   stroked arc (angles are signed bytes, doubled)
;   0 END

%define OP_END    0
%define OP_LINE   1
%define OP_POLY   2
%define OP_RRECT  3
%define OP_RING   4
%define OP_DISC   5
%define OP_RRECTL 6
%define OP_ARC    7

extern GdipDrawArcI

section .data
ic_home:   db OP_LINE,12,48,50,14, OP_LINE,50,14,88,48, OP_LINE,24,42,24,86, OP_LINE,76,42,76,86
           db OP_LINE,24,86,76,86, OP_LINE,40,86,40,60, OP_LINE,60,86,60,60, OP_LINE,40,60,60,60, OP_END
ic_search: db OP_RING,14,14,50,50, OP_LINE,56,56,84,84, OP_END
ic_lib:    db OP_RRECT,14,16,13,68,3, OP_RRECT,34,16,13,68,3, OP_LINE,60,20,82,80, OP_END
ic_sliders: db OP_LINE,14,28,86,28, OP_LINE,14,50,86,50, OP_LINE,14,72,86,72
           db OP_DISC,52,18,20,20, OP_DISC,26,40,20,20, OP_DISC,62,62,20,20, OP_END
ic_play:   db OP_POLY,3, 30,14, 30,86, 86,50, OP_END
ic_pause:  db OP_RRECT,22,14,20,72,4, OP_RRECT,58,14,20,72,4, OP_END
ic_prev:   db OP_RRECT,16,16,10,68,3, OP_POLY,3, 84,16, 84,84, 32,50, OP_END
ic_next:   db OP_RRECT,74,16,10,68,3, OP_POLY,3, 16,16, 16,84, 68,50, OP_END
ic_shuffle: db OP_LINE,8,30,30,30, OP_LINE,30,30,58,70, OP_LINE,58,70,78,70
           db OP_LINE,8,70,30,70, OP_LINE,30,70,58,30, OP_LINE,58,30,78,30
           db OP_POLY,3, 76,18, 94,30, 76,42, OP_POLY,3, 76,58, 94,70, 76,82, OP_END
ic_repeat: db OP_RRECTL,10,28,80,46,16, OP_POLY,3, 60,8, 80,28, 60,48, OP_END
ic_queue:  db OP_LINE,10,24,62,24, OP_LINE,10,46,62,46, OP_LINE,10,68,38,68
           db OP_POLY,3, 62,52, 62,86, 92,69, OP_END
ic_volume: db OP_POLY,6, 10,38, 28,38, 50,18, 50,82, 28,62, 10,62
           db OP_ARC,34,32,36,36,-23,45, OP_ARC,20,18,64,64,-23,45, OP_END
ic_expand: db OP_LINE,12,38,12,12, OP_LINE,12,12,38,12, OP_LINE,62,12,88,12, OP_LINE,88,12,88,38
           db OP_LINE,12,62,12,88, OP_LINE,12,88,38,88, OP_LINE,88,62,88,88, OP_LINE,62,88,88,88, OP_END
ic_back:   db OP_LINE,64,16,30,50, OP_LINE,30,50,64,84, OP_END
ic_close:  db OP_LINE,22,22,78,78, OP_LINE,78,22,22,78, OP_END
ic_chevd:  db OP_LINE,16,34,50,68, OP_LINE,50,68,84,34, OP_END
ic_note:   db OP_DISC,22,56,28,24, OP_LINE,48,66,48,18, OP_LINE,48,18,78,30, OP_END
ic_check:  db OP_LINE,18,52,40,74, OP_LINE,40,74,84,26, OP_END
ic_plus:   db OP_LINE,50,18,50,82, OP_LINE,18,50,82,50, OP_END
; a heart: 34 points around the classic parametric curve, as a filled shape and as an outline
ic_heart_f: db OP_POLY,34, 50,30,52,23,56,18,62,14,69,12,76,13,83,16,89,22,92,29,92,37,89,45,83,52,76,59,69,66,62,72,56,77,52,83,50,88,48,83,44,77,38,72,31,66,24,59,17,52,11,45,8,37,8,29,11,22,17,16,24,13,31,12,38,14,44,18,48,23, OP_END
ic_heart: db OP_LINE,50,30,52,23, OP_LINE,52,23,56,18, OP_LINE,56,18,62,14, OP_LINE,62,14,69,12, OP_LINE,69,12,76,13, OP_LINE,76,13,83,16, OP_LINE,83,16,89,22, OP_LINE,89,22,92,29, OP_LINE,92,29,92,37, OP_LINE,92,37,89,45, OP_LINE,89,45,83,52, OP_LINE,83,52,76,59, OP_LINE,76,59,69,66, OP_LINE,69,66,62,72, OP_LINE,62,72,56,77, OP_LINE,56,77,52,83, OP_LINE,52,83,50,88, OP_LINE,50,88,48,83, OP_LINE,48,83,44,77, OP_LINE,44,77,38,72, OP_LINE,38,72,31,66, OP_LINE,31,66,24,59, OP_LINE,24,59,17,52, OP_LINE,17,52,11,45, OP_LINE,11,45,8,37, OP_LINE,8,37,8,29, OP_LINE,8,29,11,22, OP_LINE,11,22,17,16, OP_LINE,17,16,24,13, OP_LINE,24,13,31,12, OP_LINE,31,12,38,14, OP_LINE,38,14,44,18, OP_LINE,44,18,48,23, OP_LINE,48,23,50,30, OP_END

section .bss
ic_x:   resd 1
ic_y:   resd 1
ic_s:   resd 1
ic_pts: resd 128                        ; polygon scratch: up to 64 POINTs

section .text

; eax = 0..100 -> eax = ic_x + eax * size / 100
ic_px:
        imul    eax, [ic_s]
        xor     edx, edx
        mov     ecx, 100
        div     ecx
        add     eax, [ic_x]
        ret

ic_py:
        imul    eax, [ic_s]
        xor     edx, edx
        mov     ecx, 100
        div     ecx
        add     eax, [ic_y]
        ret

; reads one coordinate byte (x axis / y axis) from the program at rsi, advancing it
ic_rdx:
        movzx   eax, byte [rsi]
        inc     rsi
        jmp     ic_px
ic_rdy:
        movzx   eax, byte [rsi]
        inc     rsi
        jmp     ic_py

; reads a size (w or h) byte: scaled but not offset
ic_rds:
        movzx   eax, byte [rsi]
        inc     rsi
        imul    eax, [ic_s]
        xor     edx, edx
        mov     ecx, 100
        div     ecx
        ret

; ecx = x, edx = y, r8d = size in pixels, r9 = icon program.  Uses the current colour.
PROC icon_draw, 12
        mov     [ic_x], ecx
        mov     [ic_y], edx
        mov     [ic_s], r8d
        mov     rsi, r9
        lea     eax, [r8+4]
        xor     edx, edx
        mov     ecx, 10
        div     ecx
        cmp     eax, 2
        jae     .w
        mov     eax, 2
.w:     mov     r15d, eax                       ; stroke width
.op:    movzx   eax, byte [rsi]
        inc     rsi
        test    eax, eax
        jz      .done
        cmp     eax, OP_LINE
        je      .line
        cmp     eax, OP_POLY
        je      .poly
        cmp     eax, OP_RRECT
        je      .rrect
        cmp     eax, OP_RING
        je      .ring
        cmp     eax, OP_DISC
        je      .disc
        cmp     eax, OP_RRECTL
        je      .rrectl
        cmp     eax, OP_ARC
        je      .arc
        jmp     .done
.line:  call    ic_rdx
        mov     loc(0), rax
        call    ic_rdy
        mov     loc(1), rax
        call    ic_rdx
        mov     loc(2), rax
        call    ic_rdy
        mov     loc(3), rax
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        mov     outarg(5), r15
        call    gfx_line
        jmp     .op
.poly:  movzx   ebx, byte [rsi]                 ; n points (at most 64)
        inc     rsi
        xor     edi, edi
        lea     r12, [ic_pts]
.pp:    call    ic_rdx
        mov     [r12+rdi*8], eax
        call    ic_rdy
        mov     [r12+rdi*8+4], eax
        inc     edi
        cmp     edi, ebx
        jb      .pp
        mov     rcx, r12
        mov     edx, ebx
        call    gfx_poly
        jmp     .op
.rrect: call    ic_rdx
        mov     loc(0), rax
        call    ic_rdy
        mov     loc(1), rax
        call    ic_rds
        mov     loc(2), rax
        call    ic_rds
        mov     loc(3), rax
        call    ic_rds
        mov     outarg(5), rax
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        call    gfx_rrect
        jmp     .op
.rrectl: call   ic_rdx
        mov     loc(0), rax
        call    ic_rdy
        mov     loc(1), rax
        call    ic_rds
        mov     loc(2), rax
        call    ic_rds
        mov     loc(3), rax
        call    ic_rds
        mov     outarg(5), rax
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        call    gfx_rrect_line
        jmp     .op
.ring:  call    ic_rdx
        mov     loc(0), rax
        call    ic_rdy
        mov     loc(1), rax
        call    ic_rds
        mov     loc(2), rax
        call    ic_rds
        mov     loc(3), rax
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        mov     outarg(5), r15
        call    gfx_ring
        jmp     .op
.disc:  call    ic_rdx
        mov     loc(0), rax
        call    ic_rdy
        mov     loc(1), rax
        call    ic_rds
        mov     loc(2), rax
        call    ic_rds
        mov     loc(3), rax
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        call    gfx_ellipse
        jmp     .op
.arc:   call    ic_rdx
        mov     loc(0), rax
        call    ic_rdy
        mov     loc(1), rax
        call    ic_rds
        mov     loc(2), rax
        call    ic_rds
        mov     loc(3), rax
        movsx   eax, byte [rsi]
        add     eax, eax
        mov     outarg(5), rax                  ; start angle
        movsx   eax, byte [rsi+1]
        add     eax, eax
        mov     outarg(6), rax                  ; sweep angle
        add     rsi, 2
        mov     outarg(7), r15                  ; width
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        call    gfx_arc
        jmp     .op
.done:  EPROC

; Arc outline with round caps. ecx = x, edx = y, r8d = w, r9d = h, [5] = start deg, [6] = sweep deg, [7] = width
PROC gfx_arc, 4
        mov     home3, r8
        mov     home4, r9
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     ecx, [g_cur_color]
        cvtsi2ss xmm1, dword [rbp+64]
        mov     r8d, UnitPixel
        lea     r9, loc(2)
        call    GdipCreatePen1
        mov     rcx, loc(2)
        mov     edx, 2
        call    GdipSetPenStartCap
        mov     rcx, loc(2)
        mov     edx, 2
        call    GdipSetPenEndCap
        mov     rcx, [g_g]
        mov     rdx, loc(2)
        mov     r8d, dword loc(0)
        mov     r9d, dword loc(1)
        mov     eax, home3
        mov     outarg(5), rax
        mov     eax, home4
        mov     outarg(6), rax
        cvtsi2ss xmm0, dword [rbp+48]
        movd    eax, xmm0
        mov     outarg(7), rax
        cvtsi2ss xmm0, dword [rbp+56]
        movd    eax, xmm0
        mov     outarg(8), rax
        call    GdipDrawArcI
        mov     rcx, loc(2)
        call    GdipDeletePen
        EPROC

%macro ICON 4                           ; ICON prog, x, y, size   (current colour)
        mov     ecx, %2
        mov     edx, %3
        mov     r8d, %4
        lea     r9, [%1]
        call    icon_draw
%endmacro
