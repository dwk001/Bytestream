; img.asm - cover-art cache keyed by URL.
;
;   "demo:<n>"  procedural artwork (used by --demo and the tests; no network needed)
;   anything else is fetched by the HTTP worker and delivered to img_set_data()

extern GdipCreateLineBrushI, GetLocalTime, SHCreateMemStream, GdipBitmapLockBits, GdipBitmapUnlockBits

; An entry: url* (0), GpImage* (8), state (16), FNV-1a hash of the url (20), pixel bytes (24), frame last drawn (28),
; last use stamp (32).
; Decoded covers are kept up to IMG_BUDGET bytes; the least recently drawn ones are dropped first and simply
; downloaded again if they come back on screen.
%define IMG_ENT   40
%define IMG_MAX   400
%define IMG_FREE    0
%define IMG_LOADING 1
%define IMG_READY   2
%define IMG_FAILED  3
%define IMG_BUDGET  (48*1024*1024)

section .bss
                align 8
img_tab:        resb IMG_MAX*IMG_ENT
img_cnt:        resd 1
img_bytes:      resq 1                  ; pixel bytes held by READY entries
img_clock:      resq 1                  ; bumped on every lookup: "last use" stamps
img_frame:      resd 1                  ; bumped by every paint (hit_reset): covers drawn in this or the last frame stay
img_own_n:      resd 1                  ; covers decoded by our own decoders / handed to GDI+ (--dump)
img_gdip_n:     resd 1

section .data
align 8
img_budget:     dq IMG_BUDGET
section .text

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

; rcx = data, rdx = length -> rax = {width, height, BGRA pixels} on the heap, or 0.  The program's own decoders: PNG
; and baseline JPEG; anything else (progressive JPEG, GIF ...) comes back 0 and is left to GDI+.
PROC img_decode_pixels, 2
        cmp     rdx, 16
        jb      .none
        cmp     dword [rcx], 0x474E5089         ; 89 'P' 'N' 'G'
        je      .png
        cmp     word [rcx], 0xD8FF
        jne     .none
        jmp     .jpg
.png:   call    png_decode
        jmp     .out
.jpg:   call    jpeg_decode
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC

; rcx = {w, h, BGRA} block -> rax = a 32bpp ARGB GpBitmap holding those pixels (GDI+ owns its own copy), or 0
PROC img_from_pixels, 12
        mov     loc(0), rcx
        mov     edx, [rcx+4]                    ; h
        mov     ecx, [rcx]                      ; w
        xor     r8d, r8d
        mov     r9d, 0x26200A                   ; PixelFormat32bppARGB
        mov     qword outarg(5), 0
        lea     rax, loc(1)
        mov     outarg(6), rax
        call    GdipCreateBitmapFromScan0
        test    eax, eax
        jnz     .fail
        mov     rax, loc(0)
        lea     rcx, loc(3)                     ; GpRect {0, 0, w, h}
        mov     dword [rcx], 0
        mov     dword [rcx+4], 0
        mov     edx, [rax]
        mov     [rcx+8], edx
        mov     edx, [rax+4]
        mov     [rcx+12], edx
        mov     rcx, loc(1)
        lea     rdx, loc(3)
        mov     r8d, 2                          ; ImageLockModeWrite
        mov     r9d, 0x26200A
        lea     rax, loc(7)                     ; BitmapData {w, h, stride, format, scan0, reserved}
        mov     outarg(5), rax
        call    GdipBitmapLockBits
        test    eax, eax
        jnz     .dispose
        mov     rax, loc(0)
        mov     r14d, [rax]                     ; w
        mov     r13d, [rax+4]                   ; h
        lea     rsi, [rax+8]
        lea     r10, loc(7)
        mov     r12, [r10+16]                   ; first destination row
        movsxd  r15, dword [r10+8]              ; stride in bytes
        xor     ebx, ebx
.row:   cmp     ebx, r13d
        jae     .rows
        mov     rdi, r12
        mov     ecx, r14d
        rep     movsd
        add     r12, r15
        inc     ebx
        jmp     .row
.rows:  mov     rcx, loc(1)
        lea     rdx, loc(7)
        call    GdipBitmapUnlockBits
        mov     rax, loc(1)
        jmp     .out
.dispose:
        mov     rcx, loc(1)
        call    GdipDisposeImage
.fail:  xor     eax, eax
.out:   EPROC

; rcx = data, rdx = length -> rax = detached 32bpp GpBitmap (or 0).  GDI+ decodes lazily from the
; stream, so the pixels are copied into a fresh bitmap and the stream is released straight away.
PROC img_decode, 10
        mov     loc(7), rcx
        mov     loc(8), rdx
        call    img_decode_pixels               ; our own PNG / JPEG decoders first
        test    rax, rax
        jz      .gdip
        mov     loc(9), rax
        mov     rcx, rax
        call    img_from_pixels
        mov     loc(4), rax
        mov     rcx, loc(9)
        call    mem_free
        inc     dword [img_own_n]
        mov     rax, loc(4)
        jmp     .out
.gdip:  inc     dword [img_gdip_n]              ; anything else (progressive JPEG, GIF, BMP ...) is GDI+'s
        mov     rcx, loc(7)
        mov     rdx, loc(8)
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

; rcx = URL (UTF-8) -> eax = FNV-1a hash
img_hash:
        mov     eax, 0x811C9DC5
.l:     movzx   edx, byte [rcx]
        test    edx, edx
        jz      .r
        xor     eax, edx
        imul    eax, eax, 0x01000193
        inc     rcx
        jmp     .l
.r:     ret

; rcx = URL (UTF-8) -> rax = the entry for it, or 0.   Entries are compared by hash first, then by text.
PROC img_find, 4
        mov     loc(0), rcx
        call    img_hash
        mov     dword loc(1), eax
        lea     rsi, [img_tab]
        xor     ebx, ebx
.scan:  cmp     ebx, [img_cnt]
        jae     .none
        cmp     dword [rsi+16], IMG_FREE
        je      .next
        mov     eax, dword loc(1)
        cmp     [rsi+20], eax
        jne     .next
        mov     rcx, [rsi]
        mov     rdx, loc(0)
        call    u8_eq
        test    eax, eax
        jnz     .hit
.next:  add     rsi, IMG_ENT
        inc     ebx
        jmp     .scan
.hit:   mov     rax, rsi
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC

; rcx = URL (UTF-8) -> rax = GpImage* when ready, else 0 (a download is queued on first request)
PROC img_get, 4
        test    rcx, rcx
        jz      .none
        cmp     byte [rcx], 0
        je      .none
        mov     loc(0), rcx
        call    img_find
        test    rax, rax
        jz      .new
        inc     qword [img_clock]
        mov     rcx, [img_clock]
        mov     [rax+32], rcx
        mov     ecx, [img_frame]
        mov     [rax+28], ecx
        mov     rax, [rax+8]
        jmp     .out
.new:   call    img_slot                        ; rax = a free table slot
        mov     rsi, rax
        mov     loc(1), rsi
        mov     rcx, loc(0)
        call    u8_dup
        mov     rsi, loc(1)
        mov     [rsi], rax
        mov     qword [rsi+8], 0
        mov     dword [rsi+16], IMG_LOADING
        mov     qword [rsi+24], 0
        inc     qword [img_clock]
        mov     rcx, [img_clock]
        mov     [rsi+32], rcx
        mov     ecx, [img_frame]
        mov     [rsi+28], ecx
        mov     rcx, loc(0)
        call    img_hash
        mov     rsi, loc(1)
        mov     [rsi+20], eax
        mov     rcx, [rsi]
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
        mov     rcx, rax
        call    img_account                     ; counts its bytes, evicts the oldest if over budget
        mov     rsi, loc(1)
        mov     rax, [rsi+8]
        jmp     .out
.remote:
        mov     rcx, [rsi]
        call    fetch_image_async               ; defined by the HTTP layer
        xor     eax, eax
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC

; -> rax = a table slot that is free to use: an unused one, else the least recently used finished entry
; (its image and url are released), else - every slot is downloading - the last slot
PROC img_slot, 2
        lea     rsi, [img_tab]
        xor     ebx, ebx
.free:  cmp     ebx, [img_cnt]
        jae     .grow
        cmp     dword [rsi+16], IMG_FREE
        je      .got
        add     rsi, IMG_ENT
        inc     ebx
        jmp     .free
.grow:  cmp     dword [img_cnt], IMG_MAX
        jae     .evict
        inc     dword [img_cnt]
        mov     rax, rsi
        jmp     .out
.evict: lea     rsi, [img_tab]
        xor     ebx, ebx
        xor     r12d, r12d                      ; best slot so far
        mov     r13, -1                         ; its stamp
.ev:    cmp     ebx, IMG_MAX
        jae     .pick
        cmp     dword [rsi+16], IMG_LOADING
        je      .evn
        cmp     [rsi+32], r13
        jae     .evn
        mov     r13, [rsi+32]
        mov     r12, rsi
.evn:   add     rsi, IMG_ENT
        inc     ebx
        jmp     .ev
.pick:  test    r12, r12
        jnz     .have
        lea     r12, [img_tab+(IMG_MAX-1)*IMG_ENT]
.have:  mov     rsi, r12
        call    img_release
.got:   mov     rax, rsi
.out:   EPROC

; rsi = entry: disposes its image, frees its url, marks it free (rsi is still the entry afterwards)
PROC img_release, 0
        mov     rcx, [rsi+8]
        test    rcx, rcx
        jz      .nodisp
        call    GdipDisposeImage
        mov     eax, [rsi+24]
        sub     [img_bytes], rax
.nodisp:
        mov     rcx, [rsi]
        call    mem_free
        mov     qword [rsi], 0
        mov     qword [rsi+8], 0
        mov     dword [rsi+16], IMG_FREE
        mov     dword [rsi+24], 0
        EPROC

; rcx = GpImage*: adds the entry's pixel bytes to the total and drops the least recently used covers
; while the budget is exceeded.   The entry whose image this is must be the newest one (highest stamp).
PROC img_account, 6
        mov     loc(0), rcx
        mov     qword loc(4), 0
        lea     rdx, loc(1)
        call    GdipGetImageWidth
        mov     rcx, loc(0)
        lea     rdx, loc(2)
        call    GdipGetImageHeight
        mov     eax, dword loc(1)
        imul    eax, dword loc(2)
        shl     rax, 2
        mov     loc(3), rax
        ; find the entry that owns this image and record its size
        lea     rsi, [img_tab]
        xor     ebx, ebx
.f:     cmp     ebx, [img_cnt]
        jae     .total
        mov     rax, [rsi+8]
        cmp     rax, loc(0)
        jne     .fn
        mov     rax, loc(3)
        mov     [rsi+24], eax
        mov     loc(4), rsi
        jmp     .total
.fn:    add     rsi, IMG_ENT
        inc     ebx
        jmp     .f
.total: mov     rax, loc(3)
        add     [img_bytes], rax
.over:  mov     rax, [img_budget]
        cmp     [img_bytes], rax
        jbe     .out
        lea     rsi, [img_tab]
        xor     ebx, ebx
        xor     r12d, r12d
        mov     r13, -1
.v:     cmp     ebx, [img_cnt]
        jae     .drop
        cmp     dword [rsi+16], IMG_READY
        jne     .vn
        cmp     rsi, loc(4)
        je      .vn                             ; never the one just added
        mov     eax, [rsi+28]
        inc     eax
        cmp     eax, [img_frame]
        jae     .vn                             ; drawn in the current or the previous frame: still on screen
        cmp     [rsi+32], r13
        jae     .vn
        mov     r13, [rsi+32]
        mov     r12, rsi
.vn:    add     rsi, IMG_ENT
        inc     ebx
        jmp     .v
.drop:  test    r12, r12
        jz      .out
        mov     rsi, r12
        call    img_release
        jmp     .over
.out:   EPROC

; rcx = URL, rdx = encoded image bytes (0 = the download failed), r8 = length, r9 = pixels the worker already decoded
; ({w, h, BGRA}, or 0).  Called on the UI thread when a download finishes.
PROC img_set_data, 4
        mov     loc(0), rcx
        xor     eax, eax
        test    rdx, rdx
        jz      .nodata                         ; remember the failure instead of retrying forever
        test    r9, r9
        jz      .slow
        mov     rcx, r9
        call    img_from_pixels
        inc     dword [img_own_n]
        jmp     .nodata
.slow:  mov     rcx, rdx
        mov     rdx, r8
        call    img_decode
.nodata:
        mov     loc(1), rax
        mov     rcx, loc(0)
        call    img_find
        test    rax, rax
        jz      .gone
        mov     rsi, rax
        mov     rax, loc(1)
        test    rax, rax
        jz      .bad
        mov     [rsi+8], rax
        mov     dword [rsi+16], IMG_READY
        inc     qword [img_clock]
        mov     rcx, [img_clock]
        mov     [rsi+32], rcx
        mov     ecx, [img_frame]
        mov     [rsi+28], ecx
        mov     rcx, rax
        call    img_account
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
