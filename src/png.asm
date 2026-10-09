; png.asm - DEFLATE (RFC 1951) and a PNG decoder (RFC 2083), written here instead of using GDI+.
;
;   inflate(src, len, dst, cap)   -> bytes written, or -1
;   png_decode(data, len)         -> block {width, height, BGRA pixels} on the heap, or 0 (unsupported / damaged)
;
; Handles every colour type and bit depth (1..16) with palette / tRNS transparency and Adam7 interlacing.  Chunk CRCs and
; the zlib Adler-32 are not checked: a damaged picture simply decodes as damaged pixels.

; ---- Huffman table (one per alphabet): the stb_image layout - a 9-bit fast table plus canonical-code arrays
%define HT_FAST     0                   ; u16[512]: (length << 9) | symbol, 0 = longer than 9 bits
%define HT_FIRSTC   1024                ; u32[17]
%define HT_FIRSTS   1092                ; u32[17]
%define HT_MAXC     1160                ; u32[18]
%define HT_SIZEA    1232                ; u8[288]
%define HT_VAL      1520                ; u16[288]
%define HT_BYTES    2112

; ---- inflate state
%define IS_SRC      0
%define IS_END      8
%define IS_BITS     16
%define IS_CNT      24                  ; dword: bits in IS_BITS
%define IS_OVER     28                  ; dword: bytes read past the end of the input
%define IS_DST      32
%define IS_DPOS     40
%define IS_DEND     48
%define IS_SCRA     64                  ; u32[17] code counts per length
%define IS_SCRB     136                 ; u32[17] next code per length
%define IS_LENS     208                 ; u8[320]
%define IS_LIT      528
%define IS_DIST     2640
%define IS_CL       4752
%define IS_BYTES    6912

section .data
                align 8
inf_len_base:   dw 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
inf_len_ext:    db 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
inf_dist_base:  dw 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
inf_dist_ext:   db 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
inf_cl_order:   db 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15

section .text

; ---------------------------------------------------------------- bit reader (rbx = inflate state)
; Tops the bit buffer up to at least 57 bits (zeros past the end of the input, counted in IS_OVER).
; Clobbers rax, rcx, r8, r9, r10.
inf_fill:
        mov     r8, [rbx+IS_BITS]
        mov     r9d, [rbx+IS_CNT]
        mov     r10, [rbx+IS_SRC]
.l:     cmp     r9d, 56
        ja      .done
        xor     eax, eax
        cmp     r10, [rbx+IS_END]
        jae     .z
        movzx   eax, byte [r10]
        inc     r10
        jmp     .a
.z:     inc     dword [rbx+IS_OVER]
.a:     mov     ecx, r9d
        shl     rax, cl
        or      r8, rax
        add     r9d, 8
        jmp     .l
.done:  mov     [rbx+IS_BITS], r8
        mov     [rbx+IS_CNT], r9d
        mov     [rbx+IS_SRC], r10
        ret

; ecx = n (0 .. 32) -> eax = the next n bits, least significant first.  Clobbers rcx, rdx, r8-r11.
inf_bits:
        mov     r11d, ecx
        cmp     [rbx+IS_CNT], ecx
        jae     .have
        call    inf_fill
.have:  mov     ecx, r11d
        mov     rax, [rbx+IS_BITS]
        mov     edx, 1
        shl     rdx, cl
        dec     rdx
        and     rax, rdx
        shr     qword [rbx+IS_BITS], cl
        sub     [rbx+IS_CNT], ecx
        ret

; rdi = HT* -> eax = the next symbol, or -1.  Clobbers rcx, rdx, r8-r11.
inf_decode:
        cmp     dword [rbx+IS_CNT], 16
        jae     .ok
        call    inf_fill
.ok:    mov     rax, [rbx+IS_BITS]
        mov     edx, eax
        and     edx, 511
        movzx   r8d, word [rdi+rdx*2+HT_FAST]
        test    r8d, r8d
        jz      .slow
        mov     ecx, r8d
        shr     ecx, 9                          ; code length
        and     r8d, 511                        ; symbol
        shr     qword [rbx+IS_BITS], cl
        sub     [rbx+IS_CNT], ecx
        mov     eax, r8d
        ret
.slow:  movzx   edx, ax                         ; the next 16 bits, reversed: the codes are stored most significant bit first
        mov     eax, edx
        shr     eax, 1
        and     eax, 0x5555
        and     edx, 0x5555
        add     edx, edx
        or      edx, eax
        mov     eax, edx
        shr     eax, 2
        and     eax, 0x3333
        and     edx, 0x3333
        shl     edx, 2
        or      edx, eax
        mov     eax, edx
        shr     eax, 4
        and     eax, 0x0F0F
        and     edx, 0x0F0F
        shl     edx, 4
        or      edx, eax
        mov     r8d, edx
        shr     r8d, 8
        shl     edx, 8
        or      r8d, edx
        and     r8d, 0xFFFF                     ; r8d = reversed 16 bits
        mov     ecx, 10
.s:     cmp     r8d, [rdi+rcx*4+HT_MAXC]
        jb      .found
        inc     ecx
        cmp     ecx, 16
        jbe     .s
        jmp     .bad
.found: mov     r10d, ecx                       ; code length
        mov     eax, r8d
        mov     ecx, 16
        sub     ecx, r10d
        shr     eax, cl
        sub     eax, [rdi+r10*4+HT_FIRSTC]
        add     eax, [rdi+r10*4+HT_FIRSTS]
        cmp     eax, 288
        jae     .bad
        movzx   edx, byte [rdi+rax+HT_SIZEA]
        cmp     edx, r10d
        jne     .bad
        movzx   eax, word [rdi+rax*2+HT_VAL]
        mov     ecx, r10d
        shr     qword [rbx+IS_BITS], cl
        sub     [rbx+IS_CNT], ecx
        ret
.bad:   mov     eax, -1
        ret

; ---------------------------------------------------------------- Huffman table construction
; eax = code, ecx = bit count (<= 9) -> eax = the code with its bits in reverse order
inf_rev:
        xor     edx, edx
.l:     test    ecx, ecx
        jz      .d
        shr     eax, 1
        adc     edx, edx
        dec     ecx
        jmp     .l
.d:     mov     eax, edx
        ret

; rdi = HT*, rsi = code lengths (bytes), edx = how many symbols -> eax = 0, or -1 for an impossible set of lengths
PROC inf_build, 2
        mov     loc(0), rdi
        mov     r14, rdi
        mov     r15, rsi
        mov     r12d, edx
        xor     eax, eax                        ; clear the fast table
        mov     ecx, 128
        rep     stosq
        lea     rdi, [rbx+IS_SCRA]              ; code counts per length
        mov     ecx, 17
        rep     stosd
        xor     ecx, ecx
.cnt:   cmp     ecx, r12d
        jae     .cd
        movzx   eax, byte [r15+rcx]
        inc     dword [rbx+IS_SCRA+rax*4]
        inc     ecx
        jmp     .cnt
.cd:    mov     dword [rbx+IS_SCRA], 0          ; length 0 means "unused"
        xor     r8d, r8d                        ; code
        xor     r9d, r9d                        ; k
        mov     r13d, 1
.fc:    mov     [rbx+IS_SCRB+r13*4], r8d
        mov     [r14+r13*4+HT_FIRSTC], r8d
        mov     [r14+r13*4+HT_FIRSTS], r9d
        mov     eax, [rbx+IS_SCRA+r13*4]
        add     r8d, eax
        test    eax, eax
        jz      .nz
        mov     ecx, r13d
        mov     edx, 1
        shl     edx, cl
        lea     r10d, [r8-1]
        cmp     r10d, edx
        jae     .err                            ; more codes of this length than fit
.nz:    mov     ecx, 16
        sub     ecx, r13d
        mov     edx, r8d
        shl     edx, cl
        mov     [r14+r13*4+HT_MAXC], edx
        add     r8d, r8d
        add     r9d, eax
        inc     r13d
        cmp     r13d, 15
        jbe     .fc
        mov     dword [r14+16*4+HT_MAXC], 0x10000
        xor     r13d, r13d                      ; symbol
.sym:   cmp     r13d, r12d
        jae     .ok
        movzx   r10d, byte [r15+r13]            ; its length
        test    r10d, r10d
        jz      .sn
        mov     eax, [rbx+IS_SCRB+r10*4]
        sub     eax, [r14+r10*4+HT_FIRSTC]
        add     eax, [r14+r10*4+HT_FIRSTS]      ; index in the canonical order
        cmp     eax, 288
        jae     .err
        mov     [r14+rax+HT_SIZEA], r10b
        mov     [r14+rax*2+HT_VAL], r13w
        cmp     r10d, 9
        ja      .nx
        mov     eax, [rbx+IS_SCRB+r10*4]
        mov     ecx, r10d
        call    inf_rev
        mov     r11d, r13d
        mov     ecx, r10d
        shl     ecx, 9
        or      r11d, ecx                       ; the fast entry
        mov     ecx, r10d
        mov     edx, 1
        shl     edx, cl                         ; step between the table slots of this code
.fill:  cmp     eax, 512
        jae     .nx
        mov     [r14+rax*2+HT_FAST], r11w
        add     eax, edx
        jmp     .fill
.nx:    inc     dword [rbx+IS_SCRB+r10*4]
.sn:    inc     r13d
        jmp     .sym
.ok:    xor     eax, eax
        jmp     .out
.err:   mov     eax, -1
.out:   EPROC

; ---------------------------------------------------------------- inflate
; The literal / length and distance codes of one block.  rbx = state -> eax = 0, or -1
PROC inf_codes, 4
.next:  lea     rdi, [rbx+IS_LIT]
        call    inf_decode
        test    eax, eax
        js      .err
        cmp     eax, 256
        jb      .lit
        je      .end
        sub     eax, 257
        cmp     eax, 29
        jae     .err
        mov     r12d, eax                       ; length symbol
        lea     rdx, [inf_len_ext]
        movzx   ecx, byte [rdx+r12]
        call    inf_bits
        lea     rdx, [inf_len_base]
        movzx   edx, word [rdx+r12*2]
        add     eax, edx
        mov     r13d, eax                       ; length
        lea     rdi, [rbx+IS_DIST]
        call    inf_decode
        test    eax, eax
        js      .err
        cmp     eax, 30
        jae     .err
        mov     r12d, eax
        lea     rdx, [inf_dist_ext]
        movzx   ecx, byte [rdx+r12]
        call    inf_bits
        lea     rdx, [inf_dist_base]
        movzx   edx, word [rdx+r12*2]
        add     eax, edx                        ; distance
        mov     r14, [rbx+IS_DPOS]
        mov     rcx, r14
        sub     rcx, [rbx+IS_DST]
        cmp     rax, rcx
        ja      .err                            ; reaches back before the start of the output
        lea     rcx, [r14+r13]
        cmp     rcx, [rbx+IS_DEND]
        ja      .err
        mov     rsi, r14
        sub     rsi, rax
        mov     rdi, r14
        mov     ecx, r13d
        rep     movsb                           ; byte by byte forwards: a distance shorter than the length repeats
        mov     [rbx+IS_DPOS], rdi
        jmp     .next
.lit:   mov     rdx, [rbx+IS_DPOS]
        cmp     rdx, [rbx+IS_DEND]
        jae     .err
        mov     [rdx], al
        inc     rdx
        mov     [rbx+IS_DPOS], rdx
        cmp     dword [rbx+IS_OVER], 8
        jbe     .next
        jmp     .err                            ; far past the input: truncated data
.end:   xor     eax, eax
        jmp     .out
.err:   mov     eax, -1
.out:   EPROC

; rbx = state: fixed Huffman codes
PROC inf_fixed, 2
        lea     rdi, [rbx+IS_LENS]
        mov     eax, 0x08080808
        mov     ecx, 36                         ; 144 symbols of length 8
        rep     stosd
        mov     eax, 0x09090909
        mov     ecx, 28                         ; 112 of length 9
        rep     stosd
        mov     eax, 0x07070707
        mov     ecx, 6                          ; 24 of length 7
        rep     stosd
        mov     eax, 0x08080808
        mov     ecx, 2                          ; 8 of length 8
        rep     stosd
        lea     rdi, [rbx+IS_LIT]
        lea     rsi, [rbx+IS_LENS]
        mov     edx, 288
        call    inf_build
        test    eax, eax
        jnz     .out
        lea     rdi, [rbx+IS_LENS]
        mov     eax, 0x05050505
        mov     ecx, 8
        rep     stosd
        lea     rdi, [rbx+IS_DIST]
        lea     rsi, [rbx+IS_LENS]
        mov     edx, 30
        call    inf_build
.out:   EPROC

; rbx = state: reads the code lengths of a dynamic block and builds both tables -> eax = 0 / -1
PROC inf_dynamic, 4
        mov     ecx, 5
        call    inf_bits
        add     eax, 257
        mov     r12d, eax                       ; literal / length codes
        mov     ecx, 5
        call    inf_bits
        inc     eax
        mov     r13d, eax                       ; distance codes
        mov     ecx, 4
        call    inf_bits
        add     eax, 4
        mov     r14d, eax                       ; code length codes
        cmp     r12d, 286
        ja      .err
        cmp     r13d, 30
        ja      .err
        lea     rdi, [rbx+IS_LENS]
        xor     eax, eax
        mov     ecx, 40
        rep     stosq                           ; 320 bytes
        xor     r15d, r15d
.cl:    cmp     r15d, r14d
        jae     .clb
        mov     ecx, 3
        call    inf_bits
        lea     rdx, [inf_cl_order]
        movzx   edx, byte [rdx+r15]
        mov     [rbx+IS_LENS+rdx], al
        inc     r15d
        jmp     .cl
.clb:   lea     rdi, [rbx+IS_CL]
        lea     rsi, [rbx+IS_LENS]
        mov     edx, 19
        call    inf_build
        test    eax, eax
        jnz     .err
        lea     rdi, [rbx+IS_LENS]              ; now the real lengths
        xor     eax, eax
        mov     ecx, 40
        rep     stosq
        lea     r15d, [r12+r13]                 ; total
        xor     esi, esi                        ; filled so far
.ln:    cmp     esi, r15d
        jae     .lb
        lea     rdi, [rbx+IS_CL]
        call    inf_decode
        test    eax, eax
        js      .err
        cmp     eax, 16
        jb      .one
        je      .rep16
        cmp     eax, 17
        je      .rep17
        mov     ecx, 7                          ; 18: 11 .. 138 zeros
        call    inf_bits
        add     eax, 11
        xor     edx, edx
        jmp     .fill
.rep17: mov     ecx, 3                          ; 17: 3 .. 10 zeros
        call    inf_bits
        add     eax, 3
        xor     edx, edx
        jmp     .fill
.rep16: test    esi, esi
        jz      .err
        mov     ecx, 2                          ; 16: repeat the previous length 3 .. 6 times
        call    inf_bits
        add     eax, 3
        movzx   edx, byte [rbx+IS_LENS+rsi-1]
        jmp     .fill
.one:   mov     [rbx+IS_LENS+rsi], al
        inc     esi
        jmp     .ln
.fill:  lea     ecx, [rsi+rax]
        cmp     ecx, r15d
        ja      .err
.fl:    test    eax, eax
        jz      .ln
        mov     [rbx+IS_LENS+rsi], dl
        inc     esi
        dec     eax
        jmp     .fl
.lb:    lea     rdi, [rbx+IS_LIT]
        lea     rsi, [rbx+IS_LENS]
        mov     edx, r12d
        call    inf_build
        test    eax, eax
        jnz     .err
        lea     rdi, [rbx+IS_DIST]
        lea     rsi, [rbx+IS_LENS]
        mov     eax, r12d
        add     rsi, rax
        mov     edx, r13d
        call    inf_build
        jmp     .out
.err:   mov     eax, -1
.out:   EPROC

; rcx = src, rdx = length, r8 = dst, r9 = capacity -> rax = bytes written, or -1.  Raw DEFLATE (no zlib header).
PROC inflate, 8
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        mov     ecx, IS_BYTES
        call    mem_alloc
        mov     rbx, rax
        mov     loc(4), rax
        mov     rax, loc(0)
        mov     [rbx+IS_SRC], rax
        add     rax, loc(1)
        mov     [rbx+IS_END], rax
        mov     rax, loc(2)
        mov     [rbx+IS_DST], rax
        mov     [rbx+IS_DPOS], rax
        add     rax, loc(3)
        mov     [rbx+IS_DEND], rax
.block: mov     ecx, 1
        call    inf_bits
        mov     r12d, eax                       ; final block?
        mov     ecx, 2
        call    inf_bits
        test    eax, eax
        jz      .stored
        cmp     eax, 1
        je      .fixed
        cmp     eax, 2
        jne     .err
        call    inf_dynamic
        test    eax, eax
        jnz     .err
        jmp     .codes
.fixed: call    inf_fixed
        test    eax, eax
        jnz     .err
.codes: call    inf_codes
        test    eax, eax
        jnz     .err
        jmp     .after
.stored: mov    ecx, [rbx+IS_CNT]               ; drop the bits up to the next byte boundary
        and     ecx, 7
        call    inf_bits
        mov     ecx, 16
        call    inf_bits
        mov     r13d, eax                       ; LEN
        mov     ecx, 16
        call    inf_bits
        not     eax
        and     eax, 0xFFFF
        cmp     eax, r13d
        jne     .err                            ; NLEN must be the complement
.sb:    test    r13d, r13d
        jz      .after
        mov     ecx, 8
        call    inf_bits
        mov     rdx, [rbx+IS_DPOS]
        cmp     rdx, [rbx+IS_DEND]
        jae     .err
        mov     [rdx], al
        inc     rdx
        mov     [rbx+IS_DPOS], rdx
        dec     r13d
        jmp     .sb
.after: cmp     dword [rbx+IS_OVER], 8
        ja      .err
        test    r12d, r12d
        jz      .block
        mov     rax, [rbx+IS_DPOS]
        sub     rax, [rbx+IS_DST]
        jmp     .done
.err:   mov     rax, -1
.done:  mov     loc(5), rax
        mov     rcx, loc(4)
        call    mem_free
        mov     rax, loc(5)
        EPROC

; ---------------------------------------------------------------- PNG
%define PN_W        0                   ; decoder state (one heap block)
%define PN_H        4
%define PN_DEPTH    8
%define PN_CTYPE    12
%define PN_INTER    16
%define PN_BPP      20                  ; bytes per pixel for filtering (at least 1)
%define PN_BITSPP   24                  ; bits per pixel
%define PN_TKEY     28                  ; tRNS colour key present (1) / absent (0)
%define PN_KR       32                  ; the key (16-bit samples; a grey key is in PN_KR)
%define PN_KG       34
%define PN_KB       36
%define PN_OUT      40                  ; qword: output block {w, h, pixels}
%define PN_IDAT     48                  ; Buf: concatenated IDAT payload
%define PN_PAL      80                  ; u32[256] BGRA palette (ends at 1104)
%define PN_ZERO     1104                ; qword: an all-zero row (the "row above" the first one)
%define PN_RAW      1112                ; qword: cursor in the inflated data
%define PN_SIZE     1152

section .data
png_adam_x0:    db 0, 4, 0, 2, 0, 1, 0
png_adam_y0:    db 0, 0, 4, 0, 2, 0, 1
png_adam_dx:    db 8, 8, 4, 4, 2, 2, 1
png_adam_dy:    db 8, 8, 8, 4, 4, 2, 2
section .text

; r12 = state, ecx = pass (0 .. 6) -> eax = pass width, edx = pass height   (clobbers r8, r9, r10, r11)
png_pass_dims:
        lea     r10, [png_adam_x0]
        movzx   r8d, byte [r10+rcx]
        lea     r10, [png_adam_dx]
        movzx   r9d, byte [r10+rcx]
        mov     eax, [r12+PN_W]
        sub     eax, r8d
        add     eax, r9d
        dec     eax
        xor     edx, edx
        div     r9d                             ; (w - x0 + dx - 1) / dx
        mov     r11d, eax
        lea     r10, [png_adam_y0]
        movzx   r8d, byte [r10+rcx]
        lea     r10, [png_adam_dy]
        movzx   r9d, byte [r10+rcx]
        mov     eax, [r12+PN_H]
        sub     eax, r8d
        add     eax, r9d
        dec     eax
        xor     edx, edx
        div     r9d
        mov     edx, eax
        mov     eax, r11d
        ret

; r12 = state, rsi = row, ebx = pixel number -> eax = the sample (depth 16: its high byte), ecx = the raw sample value
png_sample:
        mov     r10d, [r12+PN_DEPTH]
        cmp     r10d, 8
        je      .b8
        ja      .b16
        mov     eax, ebx                        ; 1, 2 or 4 bits per sample, packed from the high bit
        imul    eax, r10d                       ; bit offset
        mov     edx, eax
        shr     edx, 3
        movzx   edx, byte [rsi+rdx]
        and     eax, 7
        mov     ecx, 8
        sub     ecx, r10d
        sub     ecx, eax                        ; shift
        shr     edx, cl
        mov     ecx, r10d
        mov     eax, 1
        shl     eax, cl
        dec     eax
        and     eax, edx
        mov     ecx, eax
        ret
.b8:    movzx   eax, byte [rsi+rbx]
        mov     ecx, eax
        ret
.b16:   movzx   ecx, word [rsi+rbx*2]
        xchg    cl, ch                          ; big endian
        mov     eax, ecx
        shr     eax, 8
        ret

; r12 = state, rsi = unfiltered row, ebx = pixel number -> eax = 0xAARRGGBB.  Clobbers rcx, rdx, r8, r10.
png_px:
        mov     eax, [r12+PN_CTYPE]
        cmp     eax, 6
        je      .rgba
        cmp     eax, 2
        je      .rgb
        cmp     eax, 3
        je      .pal
        cmp     eax, 4
        je      .ga
        ; ---- grey, 1 .. 16 bits
        call    png_sample
        mov     r8d, eax                        ; 8-bit value (as stored for depths 8, 16)
        mov     edx, [r12+PN_DEPTH]
        cmp     edx, 8
        jae     .gs
        cmp     edx, 1
        jne     .g2
        imul    r8d, r8d, 255
        jmp     .gs
.g2:    cmp     edx, 2
        jne     .g4
        imul    r8d, r8d, 85
        jmp     .gs
.g4:    imul    r8d, r8d, 17
.gs:    mov     eax, 0xFF000000
        cmp     dword [r12+PN_TKEY], 0
        je      .gout
        cmp     cx, [r12+PN_KR]
        jne     .gout
        xor     eax, eax                        ; the colour key: transparent
.gout:  mov     edx, r8d
        shl     edx, 8
        or      edx, r8d
        shl     edx, 8
        or      edx, r8d
        or      eax, edx
        ret
.pal:   call    png_sample
        mov     eax, [r12+PN_PAL+rax*4]
        ret
.ga:    mov     r8d, [r12+PN_DEPTH]
        shr     r8d, 3                          ; bytes per sample
        mov     eax, ebx
        add     eax, eax
        imul    eax, r8d                        ; offset of this pixel
        movzx   ecx, byte [rsi+rax]             ; grey (high byte)
        add     eax, r8d
        movzx   eax, byte [rsi+rax]             ; alpha
        shl     eax, 24
        mov     edx, ecx
        shl     edx, 8
        or      edx, ecx
        shl     edx, 8
        or      edx, ecx
        or      eax, edx
        ret
.rgba:  mov     r8d, [r12+PN_DEPTH]
        shr     r8d, 3
        mov     eax, ebx
        shl     eax, 2
        imul    eax, r8d
        movzx   ecx, byte [rsi+rax]             ; R
        add     eax, r8d
        movzx   edx, byte [rsi+rax]             ; G
        add     eax, r8d
        movzx   r10d, byte [rsi+rax]            ; B
        add     eax, r8d
        movzx   eax, byte [rsi+rax]             ; A
        shl     eax, 24
        shl     ecx, 16
        shl     edx, 8
        or      eax, ecx
        or      eax, edx
        or      eax, r10d
        ret
.rgb:   mov     r8d, [r12+PN_DEPTH]
        shr     r8d, 3
        lea     eax, [rbx+rbx*2]
        imul    eax, r8d
        movzx   ecx, byte [rsi+rax]             ; R (high byte)
        lea     r10d, [rax+r8]
        movzx   edx, byte [rsi+r10]             ; G
        lea     r10d, [rax+r8*2]
        movzx   r10d, byte [rsi+r10]            ; B
        cmp     dword [r12+PN_TKEY], 0
        je      .rgbo
        cmp     r8d, 2
        je      .k16
        cmp     cx, [r12+PN_KR]                 ; 8-bit samples against the key
        jne     .rgbo
        cmp     dx, [r12+PN_KG]
        jne     .rgbo
        cmp     r10w, [r12+PN_KB]
        jne     .rgbo
        jmp     .keyed
.k16:   movzx   r8d, word [rsi+rax]             ; 16-bit samples: the whole value, big endian
        rol     r8w, 8
        cmp     r8w, [r12+PN_KR]
        jne     .rgbo
        movzx   r8d, word [rsi+rax+2]
        rol     r8w, 8
        cmp     r8w, [r12+PN_KG]
        jne     .rgbo
        movzx   r8d, word [rsi+rax+4]
        rol     r8w, 8
        cmp     r8w, [r12+PN_KB]
        jne     .rgbo
.keyed: shl     ecx, 16
        shl     edx, 8
        mov     eax, ecx
        or      eax, edx
        or      eax, r10d
        ret                                     ; alpha 0
.rgbo:  shl     ecx, 16
        shl     edx, 8
        mov     eax, 0xFF000000
        or      eax, ecx
        or      eax, edx
        or      eax, r10d
        ret

; Unfilters one pass in place and writes its pixels into the output block.
; r12 = state, ecx = pass width, edx = pass height, r8d = x0, r9d = y0, [rbp+48] = dx, [rbp+56] = dy.
; The raw cursor lives in PN_RAW.
PROC png_pass, 8
        mov     loc(0), rcx                     ; pass width
        mov     loc(1), rdx                     ; pass height
        mov     loc(2), r8                      ; x0
        mov     loc(3), r9                      ; y0
        mov     eax, stk5
        mov     loc(4), rax                     ; dx
        mov     eax, stk6
        mov     loc(5), rax                     ; dy
        mov     eax, ecx
        imul    eax, [r12+PN_BITSPP]
        add     eax, 7
        shr     eax, 3
        mov     r13d, eax                       ; bytes per row without the filter byte
        mov     r15d, [r12+PN_BPP]
        mov     r14, [r12+PN_ZERO]              ; the row above
        mov     rsi, [r12+PN_RAW]
        mov     qword loc(6), 0                 ; row number
.row:   mov     rax, loc(6)
        cmp     eax, dword loc(1)
        jae     .done
        movzx   eax, byte [rsi]
        inc     rsi
        mov     rdi, rsi                        ; this row
        cmp     eax, 1
        je      .sub
        cmp     eax, 2
        je      .up
        cmp     eax, 3
        je      .avg
        cmp     eax, 4
        je      .paeth
        jmp     .filtered                       ; 0: nothing to undo (unknown types are left as they are)
.sub:   mov     r8d, r15d
.s1:    cmp     r8d, r13d
        jae     .filtered
        mov     eax, r8d
        sub     eax, r15d
        mov     al, [rdi+rax]
        add     [rdi+r8], al
        inc     r8d
        jmp     .s1
.up:    xor     r8d, r8d
.u1:    cmp     r8d, r13d
        jae     .filtered
        mov     al, [r14+r8]
        add     [rdi+r8], al
        inc     r8d
        jmp     .u1
.avg:   xor     r8d, r8d
.a1:    cmp     r8d, r13d
        jae     .filtered
        xor     eax, eax
        cmp     r8d, r15d
        jb      .a2
        mov     r9d, r8d
        sub     r9d, r15d
        movzx   eax, byte [rdi+r9]
.a2:    movzx   r9d, byte [r14+r8]
        add     eax, r9d
        shr     eax, 1
        add     [rdi+r8], al
        inc     r8d
        jmp     .a1
.paeth: xor     r8d, r8d
.p1:    cmp     r8d, r13d
        jae     .filtered
        xor     eax, eax                        ; a = left
        xor     r11d, r11d                      ; c = up-left
        cmp     r8d, r15d
        jb      .p2
        mov     r9d, r8d
        sub     r9d, r15d
        movzx   eax, byte [rdi+r9]
        movzx   r11d, byte [r14+r9]
.p2:    movzx   r9d, byte [r14+r8]              ; b = up
        mov     edx, r9d                        ; pa = |b - c|
        sub     edx, r11d
        mov     ebx, edx
        sar     ebx, 31
        xor     edx, ebx
        sub     edx, ebx
        mov     ecx, eax                        ; pb = |a - c|
        sub     ecx, r11d
        mov     ebx, ecx
        sar     ebx, 31
        xor     ecx, ebx
        sub     ecx, ebx
        lea     r10d, [rax+r9]                  ; pc = |a + b - 2c|
        sub     r10d, r11d
        sub     r10d, r11d
        mov     ebx, r10d
        sar     ebx, 31
        xor     r10d, ebx
        sub     r10d, ebx
        cmp     edx, ecx
        jg      .pb
        cmp     edx, r10d
        jg      .pc
        jmp     .pd                             ; a
.pb:    cmp     ecx, r10d
        jg      .pc
        mov     eax, r9d                        ; b
        jmp     .pd
.pc:    mov     eax, r11d                       ; c
.pd:    add     [rdi+r8], al
        inc     r8d
        jmp     .p1
.filtered:
        mov     rsi, rdi                        ; png_px reads the row through rsi
        ; first destination pixel: out + 8 + ((y0 + row * dy) * W + x0) * 4
        mov     rax, loc(6)
        imul    eax, dword loc(5)
        add     eax, dword loc(3)
        imul    eax, [r12+PN_W]
        add     eax, dword loc(2)
        mov     r9, [r12+PN_OUT]
        lea     r9, [r9+8+rax*4]
        mov     r11d, dword loc(4)
        shl     r11d, 2                         ; bytes between destination pixels
        xor     ebx, ebx
.px:    cmp     ebx, dword loc(0)
        jae     .pxd
        call    png_px
        mov     [r9], eax
        add     r9, r11
        inc     ebx
        jmp     .px
.pxd:   mov     r14, rdi                        ; this row is the next one's row above
        lea     rsi, [rdi+r13]
        inc     qword loc(6)
        jmp     .row
.done:  mov     [r12+PN_RAW], rsi
        EPROC

; rcx = data, rdx = length -> rax = {w, h, BGRA...} heap block, or 0
PROC png_decode, 12
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     qword loc(3), 0                 ; inflated bytes
        cmp     rdx, 33
        jb      .nostate
        mov     rax, 0x0A1A0A0D474E5089
        cmp     [rcx], rax
        jne     .nostate
        mov     ecx, PN_SIZE
        call    mem_alloc
        mov     r12, rax
        xor     r13d, r13d                      ; seen IHDR
        mov     r14, loc(0)
        add     r14, 8                          ; chunk cursor
        mov     r15, loc(0)
        add     r15, loc(1)                     ; end of the data
.chunk: lea     rax, [r14+12]
        cmp     rax, r15
        ja      .chunks_done
        mov     eax, [r14]
        bswap   eax
        mov     ebx, eax                        ; chunk length
        mov     esi, [r14+4]                    ; type
        lea     rdi, [r14+8]                    ; payload
        lea     rax, [rdi+rbx+4]
        cmp     rax, r15
        ja      .chunks_done                    ; truncated: decode what there is
        cmp     esi, 0x52444849                 ; IHDR
        je      .ihdr
        cmp     esi, 0x45544C50                 ; PLTE
        je      .plte
        cmp     esi, 0x534E5274                 ; tRNS
        je      .trns
        cmp     esi, 0x54414449                 ; IDAT
        je      .idat
        cmp     esi, 0x444E4549                 ; IEND
        je      .chunks_done
        jmp     .nextc
.ihdr:  cmp     ebx, 13
        jb      .fail
        mov     eax, [rdi]
        bswap   eax
        mov     [r12+PN_W], eax
        mov     eax, [rdi+4]
        bswap   eax
        mov     [r12+PN_H], eax
        movzx   eax, byte [rdi+8]
        mov     [r12+PN_DEPTH], eax
        movzx   eax, byte [rdi+9]
        mov     [r12+PN_CTYPE], eax
        cmp     byte [rdi+10], 0
        jne     .fail
        cmp     byte [rdi+11], 0
        jne     .fail
        movzx   eax, byte [rdi+12]
        cmp     eax, 1
        ja      .fail
        mov     [r12+PN_INTER], eax
        mov     r13d, 1
        jmp     .nextc
.plte:  xor     ecx, ecx
.pl:    cmp     ecx, 256
        jae     .nextc
        lea     eax, [rcx+rcx*2]
        add     eax, 3
        cmp     eax, ebx
        ja      .nextc
        lea     eax, [rcx+rcx*2]
        movzx   edx, byte [rdi+rax]             ; R
        movzx   r8d, byte [rdi+rax+1]           ; G
        movzx   r9d, byte [rdi+rax+2]           ; B
        shl     edx, 16
        shl     r8d, 8
        or      edx, r8d
        or      edx, r9d
        or      edx, 0xFF000000
        mov     [r12+PN_PAL+rcx*4], edx
        inc     ecx
        jmp     .pl
.trns:  mov     eax, [r12+PN_CTYPE]
        cmp     eax, 3
        je      .tpal
        test    eax, eax
        jz      .tgray
        cmp     eax, 2
        jne     .nextc
        cmp     ebx, 6
        jb      .nextc
        movzx   eax, word [rdi]
        xchg    al, ah
        mov     [r12+PN_KR], ax
        movzx   eax, word [rdi+2]
        xchg    al, ah
        mov     [r12+PN_KG], ax
        movzx   eax, word [rdi+4]
        xchg    al, ah
        mov     [r12+PN_KB], ax
        mov     dword [r12+PN_TKEY], 1
        jmp     .nextc
.tgray: cmp     ebx, 2
        jb      .nextc
        movzx   eax, word [rdi]
        xchg    al, ah
        mov     [r12+PN_KR], ax
        mov     dword [r12+PN_TKEY], 1
        jmp     .nextc
.tpal:  xor     ecx, ecx
.tp:    cmp     ecx, ebx
        jae     .nextc
        cmp     ecx, 256
        jae     .nextc
        movzx   eax, byte [rdi+rcx]
        shl     eax, 24
        mov     edx, [r12+PN_PAL+rcx*4]
        and     edx, 0x00FFFFFF
        or      edx, eax
        mov     [r12+PN_PAL+rcx*4], edx
        inc     ecx
        jmp     .tp
.idat:  lea     rcx, [r12+PN_IDAT]
        mov     rdx, rdi
        mov     r8d, ebx
        call    buf_append
.nextc: lea     r14, [r14+rbx+12]
        jmp     .chunk
.chunks_done:
        test    r13d, r13d
        jz      .fail
        ; ---- geometry and sanity
        mov     eax, [r12+PN_W]
        mov     ecx, [r12+PN_H]
        test    eax, eax
        jz      .fail
        test    ecx, ecx
        jz      .fail
        cmp     eax, 16384
        ja      .fail
        cmp     ecx, 16384
        ja      .fail
        mov     rdx, rax
        imul    rdx, rcx
        cmp     rdx, 16000000                   ; pictures are cover art: more than 16 megapixels is not one
        ja      .fail
        mov     eax, [r12+PN_DEPTH]
        mov     ecx, [r12+PN_CTYPE]
        mov     edx, 1                          ; channels
        test    ecx, ecx
        jz      .depth
        cmp     ecx, 3
        je      .depth
        mov     edx, 3
        cmp     ecx, 2
        je      .depth
        mov     edx, 2
        cmp     ecx, 4
        je      .depth
        mov     edx, 4
        cmp     ecx, 6
        jne     .fail
.depth: cmp     eax, 1
        je      .dok
        cmp     eax, 2
        je      .dok
        cmp     eax, 4
        je      .dok
        cmp     eax, 8
        je      .dok
        cmp     eax, 16
        jne     .fail
.dok:   cmp     ecx, 3                          ; palette: 1 .. 8 bits; colour and alpha types: 8 or 16
        jne     .nopal
        cmp     eax, 16
        je      .fail
        jmp     .depth_ok
.nopal: test    ecx, ecx
        jz      .depth_ok                       ; grey takes any depth
        cmp     eax, 8
        jb      .fail
.depth_ok:
        imul    eax, edx
        mov     [r12+PN_BITSPP], eax
        add     eax, 7
        shr     eax, 3
        mov     [r12+PN_BPP], eax
        ; ---- the inflated size
        cmp     dword [r12+PN_INTER], 0
        jne     .adam
        mov     eax, [r12+PN_W]
        imul    eax, [r12+PN_BITSPP]
        add     eax, 7
        shr     eax, 3
        inc     eax
        mov     ecx, [r12+PN_H]
        imul    rax, rcx
        mov     r13, rax
        jmp     .alloc
.adam:  xor     r13d, r13d
        xor     ebx, ebx
.ps:    mov     ecx, ebx
        call    png_pass_dims                   ; eax = width, edx = height
        test    eax, eax
        jz      .psn
        test    edx, edx
        jz      .psn
        imul    eax, [r12+PN_BITSPP]
        add     eax, 7
        shr     eax, 3
        inc     eax
        imul    rax, rdx
        add     r13, rax
.psn:   inc     ebx
        cmp     ebx, 7
        jb      .ps
.alloc: cmp     r13, 134217728
        ja      .fail
        mov     loc(2), r13                     ; size
        mov     rcx, r13
        add     rcx, 16
        call    mem_alloc
        mov     loc(3), rax
        mov     rax, [r12+PN_IDAT+BUF_LEN]
        cmp     rax, 7
        jb      .fail
        mov     rcx, [r12+PN_IDAT+BUF_PTR]
        add     rcx, 2                          ; skip the zlib header
        lea     rdx, [rax-2]
        mov     r8, loc(3)
        mov     r9, loc(2)
        call    inflate
        cmp     rax, loc(2)
        jne     .fail
        ; ---- the output block and the zero row
        mov     eax, [r12+PN_W]
        mov     ecx, [r12+PN_H]
        imul    rax, rcx
        shl     rax, 2
        lea     rcx, [rax+8]
        call    mem_alloc
        mov     [r12+PN_OUT], rax
        mov     ecx, [r12+PN_W]
        mov     [rax], ecx
        mov     ecx, [r12+PN_H]
        mov     [rax+4], ecx
        mov     eax, [r12+PN_W]
        imul    eax, [r12+PN_BITSPP]
        add     eax, 7
        shr     eax, 3
        lea     rcx, [rax+16]
        call    mem_alloc
        mov     [r12+PN_ZERO], rax
        mov     rax, loc(3)
        mov     [r12+PN_RAW], rax
        cmp     dword [r12+PN_INTER], 0
        jne     .passes
        mov     ecx, [r12+PN_W]
        mov     edx, [r12+PN_H]
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword outarg(5), 1
        mov     qword outarg(6), 1
        call    png_pass
        jmp     .good
.passes: xor    ebx, ebx
.pp:    mov     ecx, ebx
        call    png_pass_dims
        test    eax, eax
        jz      .ppn
        test    edx, edx
        jz      .ppn
        mov     ecx, eax
        lea     r10, [png_adam_x0]
        movzx   r8d, byte [r10+rbx]
        lea     r10, [png_adam_y0]
        movzx   r9d, byte [r10+rbx]
        lea     r10, [png_adam_dx]
        movzx   eax, byte [r10+rbx]
        mov     outarg(5), rax
        lea     r10, [png_adam_dy]
        movzx   eax, byte [r10+rbx]
        mov     outarg(6), rax
        call    png_pass
.ppn:   inc     ebx
        cmp     ebx, 7
        jb      .pp
.good:  mov     rcx, loc(3)
        call    mem_free
        mov     rcx, [r12+PN_ZERO]
        call    mem_free
        lea     rcx, [r12+PN_IDAT]
        call    buf_free
        mov     rax, [r12+PN_OUT]
        mov     loc(4), rax
        mov     rcx, r12
        call    mem_free
        mov     rax, loc(4)
        jmp     .out
.fail:  mov     rcx, loc(3)
        call    mem_free
        mov     rcx, [r12+PN_OUT]
        call    mem_free
        mov     rcx, [r12+PN_ZERO]
        call    mem_free
        lea     rcx, [r12+PN_IDAT]
        call    buf_free
        mov     rcx, r12
        call    mem_free
.nostate:
        xor     eax, eax
.out:   EPROC
