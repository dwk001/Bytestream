; gfx.asm - thin helpers over the GDI+ flat API (anti-aliased shapes, text, images).
;
; State is global ("current colour / font / alignment") so draw calls stay short.
; All coordinates are device pixels.

extern GdiplusStartup, GdipCreateFromHDC, GdipDeleteGraphics, GdipSetSmoothingMode, GdipSetTextRenderingHint
extern GdipSetInterpolationMode, GdipCreateSolidFill, GdipSetSolidFillColor, GdipDeleteBrush
extern GdipFillRectangleI, GdipFillEllipseI, GdipFillPath, GdipFillPolygonI, GdipCreatePath, GdipDeletePath
extern GdipAddPathArcI, GdipClosePathFigure, GdipCreatePen1, GdipDeletePen, GdipDrawLineI, GdipDrawEllipseI
extern GdipDrawPath, GdipCreateFontFamilyFromName, GdipDeleteFontFamily, GdipGetGenericFontFamilySansSerif
extern GdipCreateFont, GdipDeleteFont, GdipCreateStringFormat, GdipDeleteStringFormat, GdipSetStringFormatAlign
extern GdipSetStringFormatLineAlign, GdipSetStringFormatTrimming, GdipSetStringFormatFlags, GdipDrawString
extern GdipCreateBitmapFromStream, GdipCreateBitmapFromScan0, GdipDisposeImage, GdipDrawImageRectI
extern GdipGetImageWidth, GdipGetImageHeight, GdipGetImageGraphicsContext, GdipBitmapGetPixel
extern GdipSetClipRectI, GdipResetClip, GdipGraphicsClear, GdipSetPenStartCap, GdipSetPenEndCap
extern GdipSetPixelOffsetMode, GdipSetCompositingQuality, GdipMeasureString, GdipSetClipPath
extern GdipFillPie, GdipDrawArcI, GdipCreateLineBrushI

%define F_BODY      0
%define F_BODY_B    1
%define F_SMALL     2
%define F_SMALL_B   3
%define F_CAPTION   4
%define F_H2        5
%define F_H1        6
%define F_HERO      7
%define NFONTS      8

section .bss
g_gdip_tok:     resq 1
g_g:            resq 1                  ; current GpGraphics*
g_brush:        resq 1
g_family:       resq 1
g_fonts:        resq NFONTS
g_fmt:          resq 3                  ; left, centre, right
g_cur_font:     resd 1
g_cur_align:    resd 1
g_cur_color:    resd 1
g_gdip_in:      resd 6

section .data
WSTR gfx_font_name, "Segoe UI"
gfx_font_px:    dd 14, 14, 12, 12, 11, 20, 32, 46
gfx_font_style: dd 0, 1, 0, 1, 0, 1, 1, 1

section .text

; ---------------------------------------------------------------- setup
PROC gfx_init, 2
        mov     dword [g_gdip_in], 1            ; GdiplusVersion
        lea     rcx, [g_gdip_tok]
        lea     rdx, [g_gdip_in]
        xor     r8d, r8d
        call    GdiplusStartup
        mov     ecx, 0xFFFFFFFF
        lea     rdx, [g_brush]
        call    GdipCreateSolidFill
        ; string formats: left / centre / right, vertically centred, single line, ellipsis
        xor     ebx, ebx
.fmt:   xor     ecx, ecx
        xor     edx, edx
        lea     r8, [g_fmt]
        lea     r8, [r8+rbx*8]
        call    GdipCreateStringFormat
        lea     rax, [g_fmt]
        mov     rcx, [rax+rbx*8]
        mov     edx, ebx                        ; 0 near, 1 centre, 2 far
        call    GdipSetStringFormatAlign
        lea     rax, [g_fmt]
        mov     rcx, [rax+rbx*8]
        mov     edx, StringAlignmentCenter
        call    GdipSetStringFormatLineAlign
        lea     rax, [g_fmt]
        mov     rcx, [rax+rbx*8]
        mov     edx, StringTrimmingEllipsisCharacter
        call    GdipSetStringFormatTrimming
        lea     rax, [g_fmt]
        mov     rcx, [rax+rbx*8]
        mov     edx, StringFormatFlagsNoWrap
        call    GdipSetStringFormatFlags
        inc     ebx
        cmp     ebx, 3
        jb      .fmt
        ; font family: Segoe UI, falling back to the generic sans-serif family
        lea     rcx, [gfx_font_name]
        xor     edx, edx
        lea     r8, [g_family]
        call    GdipCreateFontFamilyFromName
        test    eax, eax
        jz      .fam
        lea     rcx, [g_family]
        call    GdipGetGenericFontFamilySansSerif
.fam:   EPROC

; ecx = UI scale in 16.16 fixed point (0x10000 = 100%): (re)creates the font table
PROC gfx_set_scale, 2
        mov     loc(0), rcx
        xor     ebx, ebx
.f:     lea     rax, [g_fonts]
        mov     rcx, [rax+rbx*8]
        test    rcx, rcx
        jz      .make
        call    GdipDeleteFont
.make:  lea     rax, [gfx_font_px]
        mov     eax, [rax+rbx*4]
        imul    rax, loc(0)
        shr     rax, 16
        cvtsi2ss xmm1, eax
        lea     rax, [gfx_font_style]
        mov     r8d, [rax+rbx*4]
        mov     r9d, UnitPixel
        mov     rcx, [g_family]
        lea     rax, [g_fonts]
        lea     rax, [rax+rbx*8]
        mov     outarg(5), rax
        call    GdipCreateFont
        inc     ebx
        cmp     ebx, NFONTS
        jb      .f
        EPROC

; rcx = GpGraphics* to draw into
PROC gfx_attach, 0
        mov     [g_g], rcx
        mov     edx, SmoothingModeAntiAlias
        call    GdipSetSmoothingMode
        mov     rcx, [g_g]
        mov     edx, TextRenderingHintAntiAlias
        call    GdipSetTextRenderingHint
        mov     rcx, [g_g]
        mov     edx, InterpolationModeHighQualityBicubic
        call    GdipSetInterpolationMode
        mov     rcx, [g_g]
        mov     edx, 2                          ; PixelOffsetModeHighQuality
        call    GdipSetPixelOffsetMode
        EPROC

; ---------------------------------------------------------------- state
PROC gfx_color, 0                       ; ecx = 0xAARRGGBB
        mov     [g_cur_color], ecx
        mov     edx, ecx
        mov     rcx, [g_brush]
        call    GdipSetSolidFillColor
        EPROC

gfx_font:                               ; ecx = font index
        mov     [g_cur_font], ecx
        ret

gfx_align:                              ; ecx = 0 left, 1 centre, 2 right
        mov     [g_cur_align], ecx
        ret

; ---------------------------------------------------------------- shapes
; ecx = x, edx = y, r8d = w, r9d = h  (current colour)
PROC gfx_rect, 0
        mov     r10d, ecx
        mov     r11d, edx
        mov     outarg(5), r8
        mov     outarg(6), r9
        mov     r8d, r10d
        mov     r9d, r11d
        mov     rcx, [g_g]
        mov     rdx, [g_brush]
        call    GdipFillRectangleI
        EPROC

PROC gfx_ellipse, 0
        mov     r10d, ecx
        mov     r11d, edx
        mov     outarg(5), r8
        mov     outarg(6), r9
        mov     r8d, r10d
        mov     r9d, r11d
        mov     rcx, [g_g]
        mov     rdx, [g_brush]
        call    GdipFillEllipseI
        EPROC

; Builds a rounded-rectangle path. ecx = x, edx = y, r8d = w, r9d = h, [rbp+48] = radius -> rax = GpPath*
PROC gfx_rrect_path, 8
        movsxd  rax, ecx
        mov     loc(1), rax                     ; x
        movsxd  rax, edx
        mov     loc(2), rax                     ; y
        movsxd  rax, r8d
        mov     loc(3), rax                     ; w
        movsxd  rax, r9d
        mov     loc(4), rax                     ; h
        mov     eax, stk5
        add     eax, eax                        ; diameter
        mov     rcx, loc(3)
        cmp     rax, rcx
        cmova   rax, rcx
        mov     rcx, loc(4)
        cmp     rax, rcx
        cmova   rax, rcx
        cmp     rax, 2
        jae     .d
        mov     eax, 2
.d:     mov     loc(5), rax                     ; d
        xor     ecx, ecx                        ; FillModeAlternate
        lea     rdx, loc(0)
        call    GdipCreatePath
        ; top-left
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        mov     r8, loc(2)
        mov     r9, loc(5)
        mov     rax, loc(5)
        mov     outarg(5), rax
        mov     qword outarg(6), 0x43340000     ; 180.0f
        mov     qword outarg(7), 0x42B40000     ; 90.0f
        call    GdipAddPathArcI
        ; top-right
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        add     rdx, loc(3)
        sub     rdx, loc(5)
        mov     r8, loc(2)
        mov     r9, loc(5)
        mov     rax, loc(5)
        mov     outarg(5), rax
        mov     qword outarg(6), 0x43870000     ; 270.0f
        mov     qword outarg(7), 0x42B40000
        call    GdipAddPathArcI
        ; bottom-right
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        add     rdx, loc(3)
        sub     rdx, loc(5)
        mov     r8, loc(2)
        add     r8, loc(4)
        sub     r8, loc(5)
        mov     r9, loc(5)
        mov     rax, loc(5)
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        mov     qword outarg(7), 0x42B40000
        call    GdipAddPathArcI
        ; bottom-left
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        mov     r8, loc(2)
        add     r8, loc(4)
        sub     r8, loc(5)
        mov     r9, loc(5)
        mov     rax, loc(5)
        mov     outarg(5), rax
        mov     qword outarg(6), 0x42B40000
        mov     qword outarg(7), 0x42B40000
        call    GdipAddPathArcI
        mov     rcx, loc(0)
        call    GdipClosePathFigure
        mov     rax, loc(0)
        EPROC

; ecx = x, edx = y, r8d = w, r9d = h, [rbp+48] = radius (current colour)
PROC gfx_rrect, 1
        mov     eax, stk5
        mov     outarg(5), rax
        call    gfx_rrect_path
        mov     loc(0), rax
        mov     rcx, [g_g]
        mov     rdx, [g_brush]
        mov     r8, rax
        call    GdipFillPath
        mov     rcx, loc(0)
        call    GdipDeletePath
        EPROC

; Outline of a rounded rectangle, 1px pen in the current colour.
; ecx = x, edx = y, r8d = w, r9d = h, [rbp+48] = radius
PROC gfx_rrect_line, 2
        mov     eax, stk5
        mov     outarg(5), rax
        call    gfx_rrect_path
        mov     loc(0), rax
        mov     ecx, [g_cur_color]
        movss   xmm1, [gfx_one]
        mov     r8d, UnitPixel
        lea     r9, loc(1)
        call    GdipCreatePen1
        mov     rcx, [g_g]
        mov     rdx, loc(1)
        mov     r8, loc(0)
        call    GdipDrawPath
        mov     rcx, loc(1)
        call    GdipDeletePen
        mov     rcx, loc(0)
        call    GdipDeletePath
        EPROC

; Line with round caps. ecx = x1, edx = y1, r8d = x2, r9d = y2, [rbp+48] = width in pixels
PROC gfx_line, 3
        mov     home3, r8
        mov     home4, r9
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     ecx, [g_cur_color]
        cvtsi2ss xmm1, dword stk5
        mov     r8d, UnitPixel
        lea     r9, loc(2)
        call    GdipCreatePen1
        mov     rcx, loc(2)
        mov     edx, 2                          ; LineCapRound
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
        call    GdipDrawLineI
        mov     rcx, loc(2)
        call    GdipDeletePen
        EPROC

; Ring (ellipse outline). ecx = x, edx = y, r8d = w, r9d = h, [rbp+48] = width
PROC gfx_ring, 3
        mov     home3, r8
        mov     home4, r9
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     ecx, [g_cur_color]
        cvtsi2ss xmm1, dword stk5
        mov     r8d, UnitPixel
        lea     r9, loc(2)
        call    GdipCreatePen1
        mov     rcx, [g_g]
        mov     rdx, loc(2)
        mov     r8d, dword loc(0)
        mov     r9d, dword loc(1)
        mov     eax, home3
        mov     outarg(5), rax
        mov     eax, home4
        mov     outarg(6), rax
        call    GdipDrawEllipseI
        mov     rcx, loc(2)
        call    GdipDeletePen
        EPROC

; rcx = POINT[] (int x,y pairs), edx = count (current colour)
PROC gfx_poly, 0
        mov     r8, rcx
        mov     r9d, edx
        mov     qword outarg(5), 0
        mov     rcx, [g_g]
        mov     rdx, [g_brush]
        call    GdipFillPolygonI
        EPROC

; ---------------------------------------------------------------- text
; rcx = UTF-16 string, edx = x, r8d = y, r9d = w, [rbp+48] = h  (current font / colour / alignment)
PROC gfx_text, 2
        mov     r10, rcx
        cvtsi2ss xmm0, edx
        movss   [rbp-80], xmm0                  ; RectF at loc(1): x y w h
        cvtsi2ss xmm0, r8d
        movss   [rbp-76], xmm0
        cvtsi2ss xmm0, r9d
        movss   [rbp-72], xmm0
        cvtsi2ss xmm0, dword stk5
        movss   [rbp-68], xmm0
        lea     rax, [g_fonts]
        mov     ecx, [g_cur_font]
        mov     r9, [rax+rcx*8]
        lea     rax, [g_fmt]
        mov     ecx, [g_cur_align]
        mov     rax, [rax+rcx*8]
        lea     rcx, loc(1)
        mov     outarg(5), rcx
        mov     outarg(6), rax
        mov     rax, [g_brush]
        mov     outarg(7), rax
        mov     rcx, [g_g]
        mov     rdx, r10
        mov     r8d, -1
        call    GdipDrawString
        EPROC

; rcx = string -> eax = width in pixels of the string in the current font (single line)
PROC gfx_text_w, 10
        mov     loc(9), rcx
        mov     qword [rbp-80], 0               ; layout RectF = 0,0,10000,10000
        mov     dword [rbp-72], 0x461C4000      ; 10000.0f
        mov     dword [rbp-68], 0x461C4000
        mov     dword [rbp-96], 0               ; result RectF at loc(3)
        mov     dword [rbp-92], 0
        mov     dword [rbp-88], 0
        mov     dword [rbp-84], 0
        lea     rax, [g_fonts]
        mov     ecx, [g_cur_font]
        mov     r9, [rax+rcx*8]
        lea     rax, [g_fmt]
        mov     rax, [rax]
        lea     rcx, loc(1)                     ; layout rect
        mov     outarg(5), rcx
        mov     outarg(6), rax
        lea     rcx, loc(3)                     ; bounding box out
        mov     outarg(7), rcx
        mov     qword outarg(8), 0
        mov     qword outarg(9), 0
        mov     rcx, [g_g]
        mov     rdx, loc(9)
        mov     r8d, -1
        call    GdipMeasureString
        movss   xmm0, [rbp-88]                  ; bounding width
        cvttss2si eax, xmm0
        add     eax, 1
        EPROC

; ---------------------------------------------------------------- images / clipping
; rcx = GpImage*, edx = x, r8d = y, r9d = w, [rbp+48] = h
PROC gfx_image, 0
        mov     outarg(5), r9
        mov     eax, stk5
        mov     outarg(6), rax
        mov     r9d, r8d
        mov     r8d, edx
        mov     rdx, rcx
        mov     rcx, [g_g]
        call    GdipDrawImageRectI
        EPROC

; image clipped to a rounded rectangle. rcx = GpImage*, edx = x, r8d = y, r9d = w, [rbp+48] = h, [rbp+56] = radius
PROC gfx_image_round, 6
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        mov     eax, stk5
        mov     loc(4), rax
        mov     ecx, dword loc(1)
        mov     edx, dword loc(2)
        mov     r8d, dword loc(3)
        mov     r9d, dword loc(4)
        mov     eax, stk6
        mov     outarg(5), rax
        call    gfx_rrect_path
        mov     loc(5), rax
        mov     rcx, [g_g]
        mov     rdx, rax
        xor     r8d, r8d                        ; CombineModeReplace
        call    GdipSetClipPath
        mov     rcx, loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        mov     eax, dword loc(4)
        mov     outarg(5), rax
        call    gfx_image
        mov     rcx, [g_g]
        call    GdipResetClip
        mov     rcx, loc(5)
        call    GdipDeletePath
        EPROC

PROC gfx_clip, 0                        ; ecx = x, edx = y, r8d = w, r9d = h
        mov     r10d, r8d                       ; w
        mov     r11d, r9d                       ; h
        mov     r8d, edx                        ; y
        mov     edx, ecx                        ; x
        mov     r9d, r10d
        mov     outarg(5), r11
        mov     qword outarg(6), 0              ; CombineModeReplace
        mov     rcx, [g_g]
        call    GdipSetClipRectI
        EPROC

gfx_unclip:
        sub     rsp, 40
        mov     rcx, [g_g]
        call    GdipResetClip
        add     rsp, 40
        ret

section .data
gfx_one:        dd 1.0
section .text

; Vertical gradient fill. ecx = x, edx = y, r8d = w, r9d = h, [rbp+48] = colour at top, [rbp+56] = colour at bottom
PROC gfx_gradient, 8
        mov     home3, r8
        mov     home4, r9
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     dword [rbp-96], ecx             ; POINT p1 = (x, y)
        mov     dword [rbp-92], edx
        mov     dword [rbp-104], ecx            ; POINT p2 = (x, y + h)
        lea     eax, [rdx+r9]
        mov     dword [rbp-100], eax
        lea     rcx, [rbp-96]
        lea     rdx, [rbp-104]
        mov     r8d, stk5
        mov     r9d, stk6
        mov     qword outarg(5), 0
        lea     rax, loc(2)
        mov     outarg(6), rax
        call    GdipCreateLineBrushI
        mov     rcx, [g_g]
        mov     rdx, loc(2)
        mov     r8d, dword loc(0)
        mov     r9d, dword loc(1)
        mov     eax, home3
        mov     outarg(5), rax
        mov     eax, home4
        mov     outarg(6), rax
        call    GdipFillRectangleI
        mov     rcx, loc(2)
        call    GdipDeleteBrush
        EPROC
