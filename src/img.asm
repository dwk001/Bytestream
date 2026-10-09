; img.asm - cover-art cache keyed by URL.
;
;   "demo:<n>"  procedural artwork (used by --demo and the tests; no network needed)
;   anything else is fetched by the HTTP worker and delivered to img_set_data()

extern GdipCreateLineBrushI, GetLocalTime, SHCreateMemStream

%define IMG_ENT   24                    ; url*, image*, state
%define IMG_MAX   400
%define IMG_LOADING 1
%define IMG_READY   2
%define IMG_FAILED  3

section .bss
img_tab:        resb IMG_MAX*IMG_ENT
img_cnt:        resd 1
img_victim:     resd 1

section .data
ZSTR s_demo_prefix, "demo:"
align 4
demo_pal:
        dd 0xFF6D28D9, 0xFFDB2777, 0xFF0EA5E9, 0xFF22C55E, 0xFFF97316, 0xFFEF4444
        dd 0xFF14B8A6, 0xFF3B82F6, 0xFFEAB308, 0xFFEC4899, 0xFF8B5CF6, 0xFF06B6D4
        dd 0xFFF43F5E, 0xFFF59E0B, 0xFF10B981, 0xFF6366F1, 0xFF84CC16, 0xFF0EA5E9
        dd 0xFFA855F7, 0xFFF97316, 0xFF2DD4BF, 0xFF4F46E5, 0xFFFB7185, 0xFFFACC15

section .text

; ecx = demo number -> rax = 256x256 GpBitmap with generated artwork
PROC img_make_demo, 12
        mov     loc(0), rcx                     ; n
        mov     ecx, 256
        mov     edx, 256
        xor     r8d, r8d
        mov     r9d, 0x26200A                   ; PixelFormat32bppARGB
        mov     qword outarg(5), 0
        lea     rax, loc(1)
        mov     outarg(6), rax
        call    GdipCreateBitmapFromScan0
        mov     rcx, loc(1)
        lea     rdx, loc(2)
        call    GdipGetImageGraphicsContext
        mov     rax, [g_g]
        mov     loc(3), rax                     ; remember the real target
        mov     rcx, loc(2)
        call    gfx_attach
        ; two-colour diagonal gradient
        mov     eax, dword loc(0)
        xor     edx, edx
        mov     ecx, 12
        div     ecx
        lea     rax, [demo_pal]
        mov     r8d, [rax+rdx*8]
        mov     r9d, [rax+rdx*8+4]
        mov     qword loc(4), 0                 ; POINT p1 = (0,0)
        mov     dword loc(5), 256               ; POINT p2 = (256,256): low dword at loc(5), high dword above it
        mov     dword [rbp-108], 256
        lea     rcx, loc(4)
        lea     rdx, loc(5)
        mov     qword outarg(5), 0              ; WrapModeTile
        lea     rax, loc(6)
        mov     outarg(6), rax
        call    GdipCreateLineBrushI
        mov     rcx, loc(2)
        mov     rdx, loc(6)
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword outarg(5), 256
        mov     qword outarg(6), 256
        call    GdipFillRectangleI
        mov     rcx, loc(6)
        call    GdipDeleteBrush
        ; soft highlights that vary with n
        mov     ecx, 0x30FFFFFF
        call    gfx_color
        mov     eax, dword loc(0)
        and     eax, 3
        imul    eax, 28
        add     eax, 90
        mov     ecx, eax
        mov     edx, 8
        mov     r8d, 180
        mov     r9d, 180
        call    gfx_ellipse
        mov     ecx, 0x38000000
        call    gfx_color
        mov     eax, dword loc(0)
        and     eax, 1
        imul    eax, 60
        sub     eax, 70
        mov     ecx, eax
        mov     edx, 130
        mov     r8d, 230
        mov     r9d, 230
        call    gfx_ellipse
        mov     ecx, 0x55FFFFFF
        call    gfx_color
        mov     ecx, 150
        mov     edx, 150
        mov     r8d, 64
        mov     r9d, 64
        call    gfx_ellipse
        ; restore drawing state
        mov     rcx, loc(2)
        call    GdipDeleteGraphics
        mov     rcx, loc(3)
        call    gfx_attach
        mov     ecx, [g_cur_color]
        call    gfx_color
        mov     rax, loc(1)
        EPROC

; rcx = data, rdx = length -> rax = detached 32bpp GpBitmap (or 0).  GDI+ decodes lazily from the
; stream, so the pixels are copied into a fresh bitmap and the stream is released straight away.
PROC img_decode, 10
        mov     qword loc(4), 0
        call    SHCreateMemStream
        mov     loc(0), rax                     ; IStream*
        test    rax, rax
        jz      .fail
        mov     rcx, rax
        lea     rdx, loc(1)
        call    GdipCreateBitmapFromStream
        test    eax, eax
        jnz     .rel
        mov     rcx, loc(1)
        lea     rdx, loc(2)
        call    GdipGetImageWidth
        mov     rcx, loc(1)
        lea     rdx, loc(3)
        call    GdipGetImageHeight
        mov     ecx, dword loc(2)
        mov     edx, dword loc(3)
        xor     r8d, r8d
        mov     r9d, 0x26200A
        mov     qword outarg(5), 0
        lea     rax, loc(4)
        mov     outarg(6), rax
        call    GdipCreateBitmapFromScan0
        mov     rcx, loc(4)
        lea     rdx, loc(5)
        call    GdipGetImageGraphicsContext
        mov     rax, [g_g]
        mov     loc(6), rax
        mov     rcx, loc(5)
        call    gfx_attach
        mov     rcx, loc(1)
        xor     edx, edx
        xor     r8d, r8d
        mov     r9d, dword loc(2)
        mov     eax, dword loc(3)
        mov     outarg(5), rax
        call    gfx_image
        mov     rcx, loc(5)
        call    GdipDeleteGraphics
        mov     rcx, loc(6)
        call    gfx_attach
        mov     rcx, loc(1)
        call    GdipDisposeImage
.rel:   mov     rcx, loc(0)
        mov     rax, [rcx]
        call    [rax+16]                        ; IUnknown::Release
        mov     rax, loc(4)
        jmp     .out
.fail:  xor     eax, eax
.out:   EPROC

; rcx = URL (UTF-8) -> rax = GpImage* when ready, else 0 (a download is queued on first request)
PROC img_get, 4
        test    rcx, rcx
        jz      .none
        cmp     byte [rcx], 0
        je      .none
        mov     loc(0), rcx
        lea     rsi, [img_tab]
        xor     ebx, ebx
.scan:  cmp     ebx, [img_cnt]
        jae     .new
        mov     rcx, [rsi]
        mov     rdx, loc(0)
        call    u8_eq
        test    eax, eax
        jnz     .hit
        add     rsi, IMG_ENT
        inc     ebx
        jmp     .scan
.hit:   mov     rax, [rsi+8]
        jmp     .out
.new:   mov     eax, [img_cnt]
        cmp     eax, IMG_MAX
        jb      .fresh
        mov     eax, [img_victim]               ; table full: recycle the oldest slot
        lea     ecx, [rax+1]
        xor     edx, edx
        cmp     ecx, IMG_MAX
        cmovae  ecx, edx
        mov     [img_victim], ecx
        imul    rsi, rax, IMG_ENT
        lea     rcx, [img_tab]
        add     rsi, rcx
        mov     rcx, [rsi+8]
        test    rcx, rcx
        jz      .nodisp
        call    GdipDisposeImage
.nodisp: mov    rcx, [rsi]
        call    mem_free
        jmp     .fill
.fresh: imul    rsi, rax, IMG_ENT
        lea     rcx, [img_tab]
        add     rsi, rcx
        inc     dword [img_cnt]
.fill:  mov     loc(1), rsi
        mov     rcx, loc(0)
        call    u8_dup
        mov     rsi, loc(1)
        mov     [rsi], rax
        mov     qword [rsi+8], 0
        mov     dword [rsi+16], IMG_LOADING
        mov     rcx, rax
        lea     rdx, [s_demo_prefix]
        call    u8_starts
        test    eax, eax
        jz      .remote
        ; demo:<n>
        mov     rcx, loc(0)
        add     rcx, 5
        call    json_int
        mov     ecx, eax
        call    img_make_demo
        mov     rsi, loc(1)
        mov     [rsi+8], rax
        mov     dword [rsi+16], IMG_READY
        jmp     .out
.remote:
        mov     rcx, [rsi]
        call    fetch_image_async               ; defined by the HTTP layer
        xor     eax, eax
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC

; rcx = URL, rdx = encoded image bytes, r8 = length.  Called on the UI thread when a download finishes.
PROC img_set_data, 4
        mov     loc(0), rcx
        mov     rcx, rdx
        mov     rdx, r8
        call    img_decode
        mov     loc(1), rax
        lea     rsi, [img_tab]
        xor     ebx, ebx
.scan:  cmp     ebx, [img_cnt]
        jae     .gone
        mov     rcx, [rsi]
        mov     rdx, loc(0)
        call    u8_eq
        test    eax, eax
        jnz     .set
        add     rsi, IMG_ENT
        inc     ebx
        jmp     .scan
.set:   mov     rax, loc(1)
        test    rax, rax
        jz      .bad
        mov     [rsi+8], rax
        mov     dword [rsi+16], IMG_READY
        jmp     .out
.bad:   mov     dword [rsi+16], IMG_FAILED
        jmp     .out
.gone:  mov     rcx, loc(1)                     ; entry was recycled meanwhile
        test    rcx, rcx
        jz      .out
        call    GdipDisposeImage
.out:   EPROC

; rcx = GpImage* -> eax = average colour (0xFFRRGGBB), sampled from a 4x4 downscale
PROC img_avg_color, 14
        test    rcx, rcx
        jz      .def
        mov     loc(0), rcx
        mov     ecx, 4
        mov     edx, 4
        xor     r8d, r8d
        mov     r9d, 0x26200A
        mov     qword outarg(5), 0
        lea     rax, loc(1)
        mov     outarg(6), rax
        call    GdipCreateBitmapFromScan0
        mov     rcx, loc(1)
        lea     rdx, loc(2)
        call    GdipGetImageGraphicsContext
        mov     rax, [g_g]
        mov     loc(3), rax
        mov     rcx, loc(2)
        call    gfx_attach
        mov     rcx, loc(0)
        xor     edx, edx
        xor     r8d, r8d
        mov     r9d, 4
        mov     qword outarg(5), 4
        call    gfx_image
        mov     rcx, loc(2)
        call    GdipDeleteGraphics
        mov     rcx, loc(3)
        call    gfx_attach
        xor     r12d, r12d                      ; sum R
        xor     r13d, r13d                      ; sum G
        xor     r14d, r14d                      ; sum B
        xor     ebx, ebx
.px:    mov     rcx, loc(1)
        mov     eax, ebx
        and     eax, 3
        mov     edx, eax
        mov     eax, ebx
        shr     eax, 2
        mov     r8d, eax
        lea     r9, loc(4)
        call    GdipBitmapGetPixel
        mov     eax, dword loc(4)
        movzx   ecx, al
        add     r14d, ecx
        movzx   ecx, ah
        add     r13d, ecx
        shr     eax, 16
        movzx   ecx, al
        add     r12d, ecx
        inc     ebx
        cmp     ebx, 16
        jb      .px
        mov     rcx, loc(1)
        call    GdipDisposeImage
        shr     r12d, 4
        shr     r13d, 4
        shr     r14d, 4
        mov     eax, 0xFF000000
        shl     r12d, 16
        or      eax, r12d
        shl     r13d, 8
        or      eax, r13d
        or      eax, r14d
        jmp     .out
.def:   mov     eax, 0xFF202020
.out:   EPROC
