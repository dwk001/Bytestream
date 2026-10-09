; jpeg.asm - baseline / extended-sequential JPEG decoder (ITU T.81), written here instead of using GDI+.
;
;   jpeg_decode(data, len) -> block {width, height, BGRA pixels} on the heap, or 0
;
; Handles 8-bit Huffman JPEGs with 1 (grey) or 3 (YCbCr / RGB) components, any sampling factors, restart intervals,
; interleaved and non-interleaved scans.  Progressive, arithmetic-coded, lossless, 12-bit and 4-component files return
; 0 and are left to GDI+.  The IDCT is the accurate integer one of the Independent JPEG Group (jidctint), the colour
; conversion rounds like libjpeg's and 4:2:2 / 4:2:0 chroma is interpolated with libjpeg's "fancy" triangle filters, so the
; output is bit for bit what libjpeg produces (tests compare against it); other sampling ratios are replicated.

%define JS_SRC      0
%define JS_END      8
%define JS_POS      16
%define JS_W        24
%define JS_H        28
%define JS_NCOMP    32
%define JS_HMAX     36
%define JS_VMAX     40
%define JS_MCUX     44
%define JS_MCUY     48
%define JS_RI       52                  ; restart interval in MCUs (0 = none)
%define JS_ADOBE    56                  ; Adobe transform byte, -1 when there is no Adobe marker
%define JS_FRAME    60                  ; a SOF was read
%define JS_SCANS    64                  ; scans decoded
%define JS_MARKER   68                  ; marker byte met while reading entropy-coded data (0 = none)
%define JS_BITS     72                  ; qword bit buffer (most significant bit first, valid bits in the low JS_CNT)
%define JS_CNT      80
%define JS_COMP     128                 ; 4 components
%define JS_QT       384                 ; 4 tables x 64 dwords, natural order
%define JS_HT       1408                ; 8 Huffman tables: DC 0..3, AC 4..7
%define JS_COEF     13696               ; 64 dwords: the block being decoded
%define JS_WS       13952               ; 64 dwords: IDCT workspace
%define JS_TMP      14208               ; 8 dwords: one 1-D transform
%define JS_DEF      14240               ; 8 bytes: Huffman table defined
%define JS_SLOTS    14248               ; 4 dwords: scan component slot -> component index
%define JS_XMAP     14264               ; 4 qwords: input column of every output column, per component
%define JS_SIZE     14336

%define JC_ID       0
%define JC_H        4
%define JC_V        8
%define JC_TQ       12
%define JC_TD       16
%define JC_TA       20
%define JC_PRED     24
%define JC_PLANE    32                  ; qword
%define JC_STRIDE   40
%define JC_PH       44                  ; plane height (rows)
%define JC_BW       48                  ; blocks per row in a non-interleaved scan
%define JC_BH       52
%define JC_SIZE     64

%define JH_FAST     0                   ; u16[512]: (length << 8) | symbol, 0 = longer than 9 bits
%define JH_MAXC     1024                ; s32[18]: largest code of each length, -1 when there is none
%define JH_VALP     1096                ; s32[17]: index of the first symbol of each length
%define JH_MINC     1164                ; s32[17]: smallest code of each length
%define JH_VAL      1232                ; u8[256]: symbols in code order
%define JH_SIZE     1536

section .data
                align 8
jp_zz:  db 0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28
        db 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
section .text

; ---------------------------------------------------------------- bit reader (rbx = state)
; Tops the buffer up to more than 56 bits.  Bytes after an 0xFF 0x00 stuffing are data; a marker stops the supply
; (zeros are fed instead and the marker is remembered).  Clobbers rax, rcx, rdx, r10.
jb_fill:
.l:     cmp     dword [rbx+JS_CNT], 56
        ja      .done
        mov     r10, [rbx+JS_POS]
        xor     eax, eax
        cmp     r10, [rbx+JS_END]
        jae     .add
        movzx   eax, byte [r10]
        cmp     eax, 0xFF
        jne     .take
        lea     rcx, [r10+1]
        cmp     rcx, [rbx+JS_END]
        jae     .zero
        movzx   edx, byte [rcx]
        test    edx, edx
        jz      .stuffed
        mov     [rbx+JS_MARKER], edx
.zero:  xor     eax, eax
        jmp     .add
.stuffed:
        add     r10, 2
        mov     [rbx+JS_POS], r10
        mov     eax, 0xFF
        jmp     .add
.take:  inc     r10
        mov     [rbx+JS_POS], r10
.add:   shl     qword [rbx+JS_BITS], 8
        or      [rbx+JS_BITS], rax
        add     dword [rbx+JS_CNT], 8
        jmp     .l
.done:  ret

; ecx = n (1 .. 16) -> eax = the next n bits.  Clobbers rcx, rdx, r8, r10.
jb_getbits:
        mov     r8d, ecx
        cmp     [rbx+JS_CNT], ecx
        jae     .ok
        call    jb_fill
        mov     ecx, r8d
.ok:    mov     edx, [rbx+JS_CNT]
        sub     edx, ecx
        mov     [rbx+JS_CNT], edx
        mov     rax, [rbx+JS_BITS]
        mov     ecx, edx
        shr     rax, cl
        mov     ecx, r8d
        mov     edx, 1
        shl     edx, cl
        dec     edx
        and     eax, edx
        ret

; ecx = s -> eax = the next s bits as a signed value (JPEG "receive and extend"); s = 0 gives 0.  Clobbers like jb_getbits.
jb_recv:
        test    ecx, ecx
        jz      .zero
        mov     r9d, ecx
        call    jb_getbits
        mov     ecx, r9d
        dec     ecx
        mov     edx, 1
        shl     edx, cl                         ; 1 << (s - 1)
        cmp     eax, edx
        jae     .pos
        lea     edx, [rdx*2-1]                  ; (1 << s) - 1
        sub     eax, edx
.pos:   ret
.zero:  xor     eax, eax
        ret

; rdi = Huffman table -> eax = symbol or -1.  Clobbers rcx, rdx, r8, r9, r10.
jb_decode:
        cmp     dword [rbx+JS_CNT], 16
        jae     .ok
        call    jb_fill
.ok:    mov     ecx, [rbx+JS_CNT]
        sub     ecx, 16
        mov     rax, [rbx+JS_BITS]
        shr     rax, cl
        movzx   r9d, ax                         ; the next 16 bits
        mov     edx, r9d
        shr     edx, 7
        movzx   r8d, word [rdi+rdx*2+JH_FAST]
        test    r8d, r8d
        jz      .slow
        mov     ecx, r8d
        shr     ecx, 8
        movzx   eax, r8b
        sub     [rbx+JS_CNT], ecx
        ret
.slow:  mov     r10d, 10
.sl:    mov     ecx, 16
        sub     ecx, r10d
        mov     eax, r9d
        shr     eax, cl
        cmp     eax, [rdi+r10*4+JH_MAXC]
        jle     .found
        inc     r10d
        cmp     r10d, 16
        jbe     .sl
        mov     eax, -1
        ret
.found: sub     eax, [rdi+r10*4+JH_MINC]
        add     eax, [rdi+r10*4+JH_VALP]
        and     eax, 255
        movzx   eax, byte [rdi+rax+JH_VAL]
        sub     [rbx+JS_CNT], r10d
        ret

; ---------------------------------------------------------------- tables
; rdi = table, rsi = the 16 length counts, rdx = the symbols -> eax = 0, or -1 when the counts are impossible
PROC jp_build_ht, 4
        mov     loc(0), rdi
        mov     r12, rsi
        mov     r13, rdx
        xor     eax, eax
        mov     ecx, 128
        rep     stosq                           ; clear the fast table (rdi was the table)
        mov     rdi, loc(0)
        xor     r8d, r8d                        ; total symbols
        xor     ecx, ecx
.sum:   movzx   eax, byte [r12+rcx]
        add     r8d, eax
        inc     ecx
        cmp     ecx, 16
        jb      .sum
        cmp     r8d, 256
        ja      .err
        xor     ecx, ecx                        ; copy the symbols
.cp:    cmp     ecx, r8d
        jae     .cpd
        mov     al, [r13+rcx]
        mov     [rdi+rcx+JH_VAL], al
        inc     ecx
        jmp     .cp
.cpd:   xor     r9d, r9d                        ; code
        xor     r10d, r10d                      ; k
        mov     r14d, 1                         ; length
.len:   movzx   r11d, byte [r12+r14-1]          ; codes of this length
        mov     [rdi+r14*4+JH_VALP], r10d
        mov     [rdi+r14*4+JH_MINC], r9d
        mov     dword [rdi+r14*4+JH_MAXC], -1
        test    r11d, r11d
        jz      .nc
        lea     eax, [r9+r11-1]
        mov     [rdi+r14*4+JH_MAXC], eax
        mov     ecx, r14d
        mov     edx, 1
        shl     edx, cl
        lea     eax, [r9+r11]
        cmp     eax, edx
        ja      .err                            ; more codes than the length has room for
        cmp     r14d, 9
        ja      .nc
        xor     r15d, r15d                      ; i
.fi:    cmp     r15d, r11d
        jae     .nc
        mov     ecx, 9
        sub     ecx, r14d                       ; fast-table bits left over
        lea     eax, [r9+r15]                   ; this code
        shl     eax, cl
        mov     edx, 1
        shl     edx, cl                         ; slots it covers
        lea     ecx, [r10+r15]
        movzx   ecx, byte [rdi+rcx+JH_VAL]      ; its symbol
        mov     esi, r14d
        shl     esi, 8
        or      ecx, esi                        ; (length << 8) | symbol
.ff:    test    edx, edx
        jz      .fn
        cmp     eax, 512
        jae     .fn
        mov     [rdi+rax*2+JH_FAST], cx
        inc     eax
        dec     edx
        jmp     .ff
.fn:    inc     r15d
        jmp     .fi
.nc:    add     r9d, r11d
        add     r10d, r11d
        add     r9d, r9d
        inc     r14d
        cmp     r14d, 16
        jbe     .len
        mov     dword [rdi+17*4+JH_MAXC], 0xFFFFF
        xor     eax, eax
        jmp     .out
.err:   mov     eax, -1
.out:   EPROC

; ---------------------------------------------------------------- inverse DCT
; One 8-point transform of the accurate integer kind: inputs at [in + k*STRIDE] (dwords), the eight unscaled results
; go to [out + 4*i].  Uses rax, rcx, rdx, r8-r11.
%macro IDCT8 3                          ; input register, stride in bytes, output register
        mov     eax, [%1+2*%2]
        mov     ecx, [%1+6*%2]
        lea     edx, [rax+rcx]
        imul    edx, edx, 4433
        imul    ecx, ecx, -15137
        add     ecx, edx                ; tmp2
        imul    eax, eax, 6270
        add     eax, edx                ; tmp3
        mov     r8d, [%1]
        mov     r9d, [%1+4*%2]
        lea     edx, [r8+r9]
        shl     edx, 13                 ; tmp0
        sub     r8d, r9d
        shl     r8d, 13                 ; tmp1
        lea     r9d, [rdx+rax]
        mov     [%3], r9d               ; tmp10
        sub     edx, eax
        mov     [%3+12], edx            ; tmp13
        lea     r9d, [r8+rcx]
        mov     [%3+4], r9d             ; tmp11
        sub     r8d, ecx
        mov     [%3+8], r8d             ; tmp12
        mov     eax, [%1+7*%2]          ; odd part: t0 .. t3
        mov     ecx, [%1+5*%2]
        mov     edx, [%1+3*%2]
        mov     r8d, [%1+%2]
        lea     r9d, [rax+rdx]
        lea     r10d, [rcx+r8]
        lea     r11d, [r9+r10]
        imul    r11d, r11d, 9633        ; z5
        imul    r9d, r9d, -16069
        add     r9d, r11d               ; z3
        imul    r10d, r10d, -3196
        add     r10d, r11d              ; z4
        lea     r11d, [rax+r8]
        imul    r11d, r11d, -7373       ; z1
        imul    eax, eax, 2446
        add     eax, r11d
        add     eax, r9d                ; tmp0
        imul    r8d, r8d, 12299
        add     r8d, r11d
        add     r8d, r10d               ; tmp3
        lea     r11d, [rcx+rdx]
        imul    r11d, r11d, -20995      ; z2
        imul    ecx, ecx, 16819
        add     ecx, r11d
        add     ecx, r10d               ; tmp1
        imul    edx, edx, 25172
        add     edx, r11d
        add     edx, r9d                ; tmp2
        mov     r9d, [%3]
        lea     r10d, [r9+r8]
        sub     r9d, r8d
        mov     [%3], r10d
        mov     [%3+28], r9d
        mov     r9d, [%3+4]
        lea     r10d, [r9+rdx]
        sub     r9d, edx
        mov     [%3+4], r10d
        mov     [%3+24], r9d
        mov     r9d, [%3+8]
        lea     r10d, [r9+rcx]
        sub     r9d, ecx
        mov     [%3+8], r10d
        mov     [%3+20], r9d
        mov     r9d, [%3+12]
        lea     r10d, [r9+rax]
        sub     r9d, eax
        mov     [%3+12], r10d
        mov     [%3+16], r9d
%endmacro

; rdi = destination (top-left pixel of the 8x8 block), esi = bytes per destination row.  Transforms JS_COEF.
PROC jp_idct, 4
        mov     loc(0), rdi
        mov     loc(1), rsi
        xor     r12d, r12d
.col:   lea     r13, [rbx+JS_COEF+r12*4]        ; ---- pass 1: columns
        lea     r14, [rbx+JS_WS+r12*4]
        mov     eax, [r13+32]
        or      eax, [r13+64]
        or      eax, [r13+96]
        or      eax, [r13+128]
        or      eax, [r13+160]
        or      eax, [r13+192]
        or      eax, [r13+224]
        jnz     .full1
        mov     eax, [r13]                      ; only the DC term: a flat column
        shl     eax, 2
        mov     [r14], eax
        mov     [r14+32], eax
        mov     [r14+64], eax
        mov     [r14+96], eax
        mov     [r14+128], eax
        mov     [r14+160], eax
        mov     [r14+192], eax
        mov     [r14+224], eax
        jmp     .nc
.full1: lea     r15, [rbx+JS_TMP]
        IDCT8   r13, 32, r15
        xor     ecx, ecx
.d1:    mov     eax, [r15+rcx*4]
        add     eax, 1024
        sar     eax, 11
        mov     edx, ecx
        shl     edx, 5
        mov     [r14+rdx], eax
        inc     ecx
        cmp     ecx, 8
        jb      .d1
.nc:    inc     r12d
        cmp     r12d, 8
        jb      .col
        mov     rdi, loc(0)
        xor     r12d, r12d
.row:   mov     r13d, r12d
        shl     r13d, 5
        lea     r13, [rbx+JS_WS+r13]            ; ---- pass 2: rows
        mov     eax, [r13+4]
        or      eax, [r13+8]
        or      eax, [r13+12]
        or      eax, [r13+16]
        or      eax, [r13+20]
        or      eax, [r13+24]
        or      eax, [r13+28]
        jnz     .full2
        mov     eax, [r13]
        add     eax, 16
        sar     eax, 5
        add     eax, 128
        xor     edx, edx
        test    eax, eax
        cmovs   eax, edx
        mov     edx, 255
        cmp     eax, 255
        cmova   eax, edx
        mov     rdx, 0x0101010101010101
        imul    rax, rdx
        mov     [rdi], rax
        jmp     .nr
.full2: lea     r15, [rbx+JS_TMP]
        IDCT8   r13, 4, r15
        xor     ecx, ecx
        mov     r9d, 255
        xor     r10d, r10d
.d2:    mov     eax, [r15+rcx*4]
        add     eax, 131072
        sar     eax, 18
        add     eax, 128
        test    eax, eax
        cmovs   eax, r10d
        cmp     eax, 255
        cmova   eax, r9d
        mov     [rdi+rcx], al
        inc     ecx
        cmp     ecx, 8
        jb      .d2
.nr:    add     rdi, loc(1)
        inc     r12d
        cmp     r12d, 8
        jb      .row
        EPROC

; ---------------------------------------------------------------- one block
; rdi = component record, ecx = block x, edx = block y (in blocks of its plane) -> eax = 0, or -1 on damaged data
PROC jp_block, 6
        mov     r12, rdi
        mov     loc(0), rcx
        mov     loc(1), rdx
        lea     rdi, [rbx+JS_COEF]
        xor     eax, eax
        mov     ecx, 64
        rep     stosd
        mov     eax, [r12+JC_TQ]
        shl     eax, 8
        lea     r13, [rbx+JS_QT+rax]            ; quantisation table (natural order)
        mov     eax, [r12+JC_TD]
        imul    eax, JH_SIZE
        lea     rdi, [rbx+JS_HT+rax]
        call    jb_decode
        test    eax, eax
        js      .err
        mov     ecx, eax
        call    jb_recv
        add     eax, [r12+JC_PRED]
        mov     [r12+JC_PRED], eax
        imul    eax, [r13]
        mov     [rbx+JS_COEF], eax
        mov     eax, [r12+JC_TA]
        add     eax, 4
        imul    eax, JH_SIZE
        lea     r14, [rbx+JS_HT+rax]            ; AC table
        mov     esi, 1
.ac:    cmp     esi, 64
        jae     .done
        mov     rdi, r14
        call    jb_decode
        test    eax, eax
        js      .err
        mov     ecx, eax
        and     ecx, 15                         ; size
        shr     eax, 4                          ; run
        test    ecx, ecx
        jz      .zr
        add     esi, eax
        cmp     esi, 63
        ja      .done                           ; runs past the block: stop
        call    jb_recv
        lea     rdx, [jp_zz]
        movzx   edx, byte [rdx+rsi]
        imul    eax, [r13+rdx*4]
        mov     [rbx+JS_COEF+rdx*4], eax
        inc     esi
        jmp     .ac
.zr:    cmp     eax, 15
        jne     .done                           ; end of block
        add     esi, 16
        jmp     .ac
.done:  mov     rax, [r12+JC_PLANE]
        mov     ecx, dword loc(1)
        shl     ecx, 3
        imul    ecx, [r12+JC_STRIDE]
        add     rax, rcx
        mov     ecx, dword loc(0)
        shl     ecx, 3
        add     rax, rcx
        mov     rdi, rax
        mov     esi, [r12+JC_STRIDE]
        call    jp_idct
        xor     eax, eax
        jmp     .out
.err:   mov     eax, -1
.out:   EPROC

; ---------------------------------------------------------------- one scan
; rsi = the SOS payload (after the length) -> eax = 0 / -1; JS_POS is left at the marker that ends the scan
PROC jp_scan, 12
        movzx   eax, byte [rsi]                 ; components in this scan
        test    eax, eax
        jz      .err
        cmp     eax, 4
        ja      .err
        mov     loc(0), rax
        xor     r12d, r12d
.sel:   cmp     r12d, dword loc(0)
        jae     .seld
        movzx   eax, byte [rsi+1+r12*2]         ; component id
        movzx   ecx, byte [rsi+2+r12*2]         ; table selectors
        xor     edx, edx
.find:  cmp     edx, [rbx+JS_NCOMP]
        jae     .err
        mov     r8d, edx
        shl     r8d, 6
        cmp     [rbx+JS_COMP+r8+JC_ID], eax
        je      .got
        inc     edx
        jmp     .find
.got:   mov     r9d, ecx
        shr     r9d, 4
        and     ecx, 15
        cmp     r9d, 3
        ja      .err
        cmp     ecx, 3
        ja      .err
        mov     [rbx+JS_COMP+r8+JC_TD], r9d
        mov     [rbx+JS_COMP+r8+JC_TA], ecx
        cmp     byte [rbx+JS_DEF+r9], 0         ; the tables must exist
        je      .err
        lea     r10d, [rcx+4]
        cmp     byte [rbx+JS_DEF+r10], 0
        je      .err
        mov     [rbx+JS_SLOTS+r12*4], edx       ; scan component slot -> component index
        inc     r12d
        jmp     .sel
.seld:  mov     rax, loc(0)
        mov     dword loc(1), 0                 ; reset: bits, predictors, marker
        mov     qword [rbx+JS_BITS], 0
        mov     dword [rbx+JS_CNT], 0
        mov     dword [rbx+JS_MARKER], 0
        xor     ecx, ecx
.pr:    mov     edx, ecx
        shl     edx, 6
        mov     dword [rbx+JS_COMP+rdx+JC_PRED], 0
        inc     ecx
        cmp     ecx, 4
        jb      .pr
        ; the units: MCUs for an interleaved scan, blocks for a single component
        cmp     dword loc(0), 1
        jne     .mcu
        mov     eax, [rbx+JS_SLOTS]
        shl     eax, 6
        lea     r13, [rbx+JS_COMP+rax]          ; the component
        mov     eax, [r13+JC_BW]
        imul    eax, [r13+JC_BH]
        jmp     .units
.mcu:   mov     eax, [rbx+JS_MCUX]
        imul    eax, [rbx+JS_MCUY]
.units: mov     r14d, eax                       ; number of units
        xor     r15d, r15d                      ; unit number
.unit:  cmp     r15d, r14d
        jae     .scan_end
        mov     eax, [rbx+JS_RI]
        test    eax, eax
        jz      .nr
        test    r15d, r15d
        jz      .nr
        mov     ecx, eax
        mov     eax, r15d
        xor     edx, edx
        div     ecx
        test    edx, edx
        jnz     .nr
        call    jp_restart
.nr:    cmp     dword loc(0), 1
        jne     .mcu_unit
        mov     eax, r15d                       ; non-interleaved: block (x, y)
        xor     edx, edx
        div     dword [r13+JC_BW]
        mov     ecx, edx                        ; x
        mov     edx, eax                        ; y
        mov     rdi, r13
        call    jp_block
        test    eax, eax
        js      .err
        jmp     .nu
.mcu_unit:
        mov     eax, r15d
        xor     edx, edx
        div     dword [rbx+JS_MCUX]
        mov     loc(2), rdx                     ; mx
        mov     loc(3), rax                     ; my
        xor     r12d, r12d
.mc:    cmp     r12d, dword loc(0)
        jae     .nu
        mov     eax, [rbx+JS_SLOTS+r12*4]
        shl     eax, 6
        lea     r13, [rbx+JS_COMP+rax]
        xor     esi, esi                        ; v
.mv:    cmp     esi, [r13+JC_V]
        jae     .mcn
        xor     edi, edi                        ; h
.mh:    cmp     edi, [r13+JC_H]
        jae     .mvn
        mov     eax, dword loc(2)
        imul    eax, [r13+JC_H]
        add     eax, edi
        mov     ecx, eax                        ; block x
        mov     eax, dword loc(3)
        imul    eax, [r13+JC_V]
        add     eax, esi
        mov     edx, eax                        ; block y
        mov     loc(4), rsi
        mov     loc(5), rdi
        mov     rdi, r13
        call    jp_block
        mov     rsi, loc(4)
        mov     rdi, loc(5)
        test    eax, eax
        js      .err
        inc     edi
        jmp     .mh
.mvn:   inc     esi
        jmp     .mv
.mcn:   inc     r12d
        jmp     .mc
.nu:    inc     r15d
        jmp     .unit
.scan_end:
        ; leave JS_POS at the next marker (skip anything up to it, e.g. padding bytes)
        mov     rax, [rbx+JS_POS]
.skip:  lea     rcx, [rax+1]
        cmp     rcx, [rbx+JS_END]
        jae     .atend
        cmp     byte [rax], 0xFF
        jne     .sk1
        movzx   edx, byte [rcx]
        test    edx, edx
        jz      .sk1
        cmp     edx, 0xFF
        jne     .atend
.sk1:   inc     rax
        jmp     .skip
.atend: mov     [rbx+JS_POS], rax
        xor     eax, eax
        jmp     .out
.err:   mov     eax, -1
.out:   EPROC

; Restart: drop the buffered bits, step over the RSTn marker, reset the predictors.  rbx = state.
jp_restart:
        mov     qword [rbx+JS_BITS], 0
        mov     dword [rbx+JS_CNT], 0
        mov     dword [rbx+JS_MARKER], 0
        mov     rax, [rbx+JS_POS]
        mov     rdx, [rbx+JS_END]
.f:     lea     rcx, [rax+1]
        cmp     rcx, rdx
        jae     .done
        cmp     byte [rax], 0xFF
        jne     .n
        movzx   ecx, byte [rax+1]
        and     ecx, 0xF8
        cmp     ecx, 0xD0
        jne     .n
        add     rax, 2                          ; found RSTn
        jmp     .done
.n:     inc     rax
        jmp     .f
.done:  mov     [rbx+JS_POS], rax
        xor     ecx, ecx
.p:     mov     edx, ecx
        shl     edx, 6
        mov     dword [rbx+JS_COMP+rdx+JC_PRED], 0
        inc     ecx
        cmp     ecx, 4
        jb      .p
        ret

; ---------------------------------------------------------------- chroma upsampling (libjpeg's "fancy" triangle filters)
; One row, 2:1 horizontally.  rsi = input row, edx = input width (more than 2), rdi = output row (2 * width).
jp_row_h2v1:
        movzx   eax, byte [rsi]
        mov     [rdi], al
        movzx   ecx, byte [rsi+1]
        lea     r9d, [rax+rax*2]
        add     r9d, ecx
        add     r9d, 2
        shr     r9d, 2
        mov     [rdi+1], r9b
        add     rdi, 2
        mov     r11d, 1
.l:     lea     r10d, [r11+1]
        cmp     r10d, edx
        jae     .last
        movzx   eax, byte [rsi+r11]
        lea     eax, [rax+rax*2]
        movzx   ecx, byte [rsi+r11-1]
        lea     r9d, [rax+rcx+1]
        shr     r9d, 2
        mov     [rdi], r9b
        movzx   ecx, byte [rsi+r11+1]
        lea     r9d, [rax+rcx+2]
        shr     r9d, 2
        mov     [rdi+1], r9b
        add     rdi, 2
        inc     r11d
        jmp     .l
.last:  movzx   eax, byte [rsi+r11]
        lea     ecx, [rax+rax*2]
        movzx   r9d, byte [rsi+r11-1]
        lea     ecx, [rcx+r9+1]
        shr     ecx, 2
        mov     [rdi], cl
        mov     [rdi+1], al
        ret

; One output row of a 2:1 x 2:1 upsampling.  rsi = the nearest input row, r8 = the next nearest one (above or below),
; edx = input width (more than 2), rdi = output row.
jp_row_h2v2:
        movzx   eax, byte [rsi]
        lea     eax, [rax+rax*2]
        movzx   ecx, byte [r8]
        add     eax, ecx                        ; this column's sum: 3 * near + far
        movzx   r9d, byte [rsi+1]
        lea     r9d, [r9+r9*2]
        movzx   ecx, byte [r8+1]
        add     r9d, ecx                        ; next column's
        lea     ecx, [rax*4+8]
        shr     ecx, 4
        mov     [rdi], cl
        lea     ecx, [rax+rax*2]
        add     ecx, r9d
        add     ecx, 7
        shr     ecx, 4
        mov     [rdi+1], cl
        mov     r10d, eax                       ; last
        mov     eax, r9d                        ; this
        mov     r11d, 2
        add     rdi, 2
.l:     cmp     r11d, edx
        jae     .last
        movzx   r9d, byte [rsi+r11]
        lea     r9d, [r9+r9*2]
        movzx   ecx, byte [r8+r11]
        add     r9d, ecx                        ; next
        lea     ecx, [rax+rax*2]
        add     ecx, r10d
        add     ecx, 8
        shr     ecx, 4
        mov     [rdi], cl
        lea     ecx, [rax+rax*2]
        add     ecx, r9d
        add     ecx, 7
        shr     ecx, 4
        mov     [rdi+1], cl
        mov     r10d, eax
        mov     eax, r9d
        add     rdi, 2
        inc     r11d
        jmp     .l
.last:  lea     ecx, [rax+rax*2]
        add     ecx, r10d
        add     ecx, 8
        shr     ecx, 4
        mov     [rdi], cl
        lea     ecx, [rax*4+7]
        shr     ecx, 4
        mov     [rdi+1], cl
        ret

; Components sampled at half the horizontal rate (and full or half the vertical rate) are interpolated to full size, as
; libjpeg does; other ratios are replicated by jp_convert.  rbx = state.
PROC jp_upsample, 12
        xor     r12d, r12d
.comp:  cmp     r12d, [rbx+JS_NCOMP]
        jae     .out
        mov     eax, r12d
        shl     eax, 6
        lea     r13, [rbx+JS_COMP+rax]
        mov     eax, [r13+JC_H]
        add     eax, eax
        cmp     eax, [rbx+JS_HMAX]
        jne     .next                           ; only 2:1 horizontally
        mov     eax, [r13+JC_V]
        mov     r14d, 1                         ; vertical factor 1 or 2
        cmp     eax, [rbx+JS_VMAX]
        je      .vok
        add     eax, eax
        cmp     eax, [rbx+JS_VMAX]
        jne     .next
        mov     r14d, 2
.vok:   mov     eax, [rbx+JS_W]                 ; input size: ceil(W * h / hmax) x ceil(H * v / vmax)
        imul    eax, [r13+JC_H]
        add     eax, [rbx+JS_HMAX]
        dec     eax
        xor     edx, edx
        div     dword [rbx+JS_HMAX]
        mov     r15d, eax                       ; width
        cmp     r15d, 2
        jbe     .next                           ; libjpeg replicates such narrow ones
        mov     eax, [rbx+JS_H]
        imul    eax, [r13+JC_V]
        add     eax, [rbx+JS_VMAX]
        dec     eax
        xor     edx, edx
        div     dword [rbx+JS_VMAX]
        mov     loc(0), rax                     ; height
        mov     eax, [rbx+JS_MCUX]
        imul    eax, [rbx+JS_HMAX]
        shl     eax, 3
        mov     loc(1), rax                     ; new stride
        mov     ecx, [rbx+JS_MCUY]
        imul    ecx, [rbx+JS_VMAX]
        shl     ecx, 3
        imul    rax, rcx
        lea     rcx, [rax+16]
        call    mem_alloc
        mov     loc(2), rax                     ; new plane
        xor     esi, esi                        ; input row
.rows:  cmp     esi, dword loc(0)
        jae     .done
        mov     eax, esi
        imul    eax, [r13+JC_STRIDE]
        mov     r9, [r13+JC_PLANE]
        lea     r10, [r9+rax]                   ; this input row
        cmp     r14d, 2
        je      .v2
        mov     rax, rsi
        imul    rax, loc(1)
        mov     rdi, loc(2)
        add     rdi, rax
        push    rsi
        mov     rsi, r10
        mov     edx, r15d
        call    jp_row_h2v1
        pop     rsi
        jmp     .rn
.v2:    mov     eax, esi                        ; row above (clamped at the top) -> r8
        test    eax, eax
        jz      .a1
        dec     eax
.a1:    imul    eax, [r13+JC_STRIDE]
        lea     r8, [r9+rax]
        mov     rax, rsi
        add     rax, rax
        imul    rax, loc(1)
        mov     rdi, loc(2)
        add     rdi, rax
        push    rsi
        mov     rsi, r10
        mov     edx, r15d
        call    jp_row_h2v2                     ; output row 2 * r
        pop     rsi
        lea     eax, [rsi+1]                    ; row below (clamped at the bottom)
        mov     ecx, dword loc(0)
        dec     ecx
        cmp     eax, ecx
        jbe     .b1
        mov     eax, ecx
.b1:    imul    eax, [r13+JC_STRIDE]
        mov     r9, [r13+JC_PLANE]
        lea     r8, [r9+rax]
        mov     rax, rsi
        add     rax, rax
        inc     rax
        imul    rax, loc(1)
        mov     rdi, loc(2)
        add     rdi, rax
        mov     eax, esi
        imul    eax, [r13+JC_STRIDE]
        lea     r10, [r9+rax]
        push    rsi
        mov     rsi, r10
        mov     edx, r15d
        call    jp_row_h2v2                     ; output row 2 * r + 1
        pop     rsi
.rn:    inc     esi
        jmp     .rows
.done:  mov     rcx, [r13+JC_PLANE]
        call    mem_free
        mov     rax, loc(2)
        mov     [r13+JC_PLANE], rax
        mov     eax, dword loc(1)
        mov     [r13+JC_STRIDE], eax
        mov     eax, [rbx+JS_HMAX]
        mov     [r13+JC_H], eax
        mov     eax, [rbx+JS_VMAX]
        mov     [r13+JC_V], eax
.next:  inc     r12d
        jmp     .comp
.out:   EPROC

; ---------------------------------------------------------------- colour conversion
%macro CLAMP8 1                         ; %1 = 0 .. 255 (negative -> 0, above -> 255)
        cmp     %1, 255
        jbe     %%ok
        sar     %1, 31
        not     %1
        and     %1, 255
%%ok:
%endmacro

; -> rax = {w, h, BGRA} block.  rbx = state with decoded planes.
PROC jp_convert, 8
        mov     eax, [rbx+JS_W]
        imul    eax, [rbx+JS_H]
        shl     rax, 2
        lea     rcx, [rax+8]
        call    mem_alloc
        mov     loc(0), rax
        mov     ecx, [rbx+JS_W]
        mov     [rax], ecx
        mov     ecx, [rbx+JS_H]
        mov     [rax+4], ecx
        xor     r13d, r13d                      ; x maps
.xm:    cmp     r13d, [rbx+JS_NCOMP]
        jae     .xmd
        mov     ecx, [rbx+JS_W]
        shl     ecx, 2
        call    mem_alloc
        mov     r14, rax
        mov     [rbx+JS_XMAP+r13*8], rax
        mov     eax, r13d
        shl     eax, 6
        mov     r15d, [rbx+JS_COMP+rax+JC_H]
        xor     ecx, ecx
.xl:    cmp     ecx, [rbx+JS_W]
        jae     .xln
        mov     eax, ecx
        imul    eax, r15d
        xor     edx, edx
        div     dword [rbx+JS_HMAX]
        mov     [r14+rcx*4], eax
        inc     ecx
        jmp     .xl
.xln:   inc     r13d
        jmp     .xm
.xmd:   ; the colour model: 0 grey, 1 YCbCr, 2 RGB
        mov     dword loc(3), 0
        cmp     dword [rbx+JS_NCOMP], 1
        je      .modeok
        mov     dword loc(3), 1
        cmp     dword [rbx+JS_ADOBE], 0
        je      .rgbm
        cmp     dword [rbx+JS_ADOBE], -1
        jne     .modeok
        cmp     dword [rbx+JS_COMP+JC_ID], 'R'
        jne     .modeok
        cmp     dword [rbx+JS_COMP+JC_SIZE+JC_ID], 'G'
        jne     .modeok
        cmp     dword [rbx+JS_COMP+2*JC_SIZE+JC_ID], 'B'
        jne     .modeok
.rgbm:  mov     dword loc(3), 2
.modeok:
        mov     r15, loc(0)
        add     r15, 8                          ; output cursor
        mov     r12, [rbx+JS_XMAP]
        mov     r13, [rbx+JS_XMAP+8]
        mov     r14, [rbx+JS_XMAP+16]
        mov     qword loc(1), 0                 ; y
.row:   mov     eax, dword loc(1)
        cmp     eax, [rbx+JS_H]
        jae     .done
        xor     r10d, r10d                      ; row pointers of the components -> rsi, rdi, loc(2)
.rp:    cmp     r10d, [rbx+JS_NCOMP]
        jae     .rpd
        mov     r11d, r10d
        shl     r11d, 6
        mov     eax, dword loc(1)
        imul    eax, [rbx+JS_COMP+r11+JC_V]
        xor     edx, edx
        div     dword [rbx+JS_VMAX]
        imul    eax, [rbx+JS_COMP+r11+JC_STRIDE]
        add     rax, [rbx+JS_COMP+r11+JC_PLANE]
        test    r10d, r10d
        jnz     .rp1
        mov     rsi, rax
        jmp     .rpn
.rp1:   cmp     r10d, 1
        jne     .rp2
        mov     rdi, rax
        jmp     .rpn
.rp2:   mov     loc(2), rax
.rpn:   inc     r10d
        jmp     .rp
.rpd:   xor     ecx, ecx                        ; x
        mov     eax, dword loc(3)
        test    eax, eax
        jz      .grey
        cmp     eax, 2
        je      .rgb
.ycc:   cmp     ecx, [rbx+JS_W]
        jae     .rowend
        mov     r8d, [r12+rcx*4]
        movzx   eax, byte [rsi+r8]              ; Y
        mov     r8d, [r13+rcx*4]
        movzx   edx, byte [rdi+r8]
        sub     edx, 128                        ; Cb
        mov     r9, loc(2)
        mov     r8d, [r14+rcx*4]
        movzx   r8d, byte [r9+r8]
        sub     r8d, 128                        ; Cr
        imul    r9d, r8d, 91881                 ; R = Y + 1.402 Cr
        add     r9d, 32768
        sar     r9d, 16
        add     r9d, eax
        CLAMP8  r9d
        imul    r10d, edx, 116130               ; B = Y + 1.772 Cb
        add     r10d, 32768
        sar     r10d, 16
        add     r10d, eax
        CLAMP8  r10d
        imul    edx, edx, -22554                ; G = Y - 0.344 Cb - 0.714 Cr (rounded the way libjpeg does)
        imul    r8d, r8d, -46802
        add     edx, r8d
        add     edx, 32768
        sar     edx, 16
        add     eax, edx
        CLAMP8  eax
        shl     r9d, 16
        shl     eax, 8
        or      r9d, eax
        or      r9d, r10d
        or      r9d, 0xFF000000
        mov     [r15], r9d
        add     r15, 4
        inc     ecx
        jmp     .ycc
.rgb:   cmp     ecx, [rbx+JS_W]
        jae     .rowend
        mov     r8d, [r12+rcx*4]
        movzx   r9d, byte [rsi+r8]              ; R
        mov     r8d, [r13+rcx*4]
        movzx   eax, byte [rdi+r8]              ; G
        mov     r10, loc(2)
        mov     r8d, [r14+rcx*4]
        movzx   r10d, byte [r10+r8]             ; B
        shl     r9d, 16
        shl     eax, 8
        or      r9d, eax
        or      r9d, r10d
        or      r9d, 0xFF000000
        mov     [r15], r9d
        add     r15, 4
        inc     ecx
        jmp     .rgb
.grey:  cmp     ecx, [rbx+JS_W]
        jae     .rowend
        mov     r8d, [r12+rcx*4]
        movzx   eax, byte [rsi+r8]
        mov     edx, eax
        shl     edx, 8
        or      edx, eax
        shl     edx, 8
        or      edx, eax
        or      edx, 0xFF000000
        mov     [r15], edx
        add     r15, 4
        inc     ecx
        jmp     .grey
.rowend:
        inc     qword loc(1)
        jmp     .row
.done:  xor     r13d, r13d                      ; free the maps
.fm:    cmp     r13d, [rbx+JS_NCOMP]
        jae     .fmd
        mov     rcx, [rbx+JS_XMAP+r13*8]
        call    mem_free
        inc     r13d
        jmp     .fm
.fmd:   mov     rax, loc(0)
        EPROC

; ---------------------------------------------------------------- the file
; rdi = ptr after the length, ecx = bytes left in the segment: DQT
; (the segment handlers read from rsi = payload, edx = payload length)

; rcx = data, rdx = length -> rax = {w, h, BGRA} block, or 0
PROC jpeg_decode, 8
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     ecx, JS_SIZE
        call    mem_alloc
        mov     rbx, rax
        mov     loc(2), rax
        mov     rax, loc(0)
        add     rax, 2                          ; after SOI
        mov     [rbx+JS_POS], rax
        mov     [rbx+JS_SRC], rax
        mov     rax, loc(0)
        add     rax, loc(1)
        mov     [rbx+JS_END], rax
        mov     dword [rbx+JS_ADOBE], -1
.marker:
        mov     rsi, [rbx+JS_POS]
        mov     rdx, [rbx+JS_END]
.fnd:   lea     rax, [rsi+1]
        cmp     rax, rdx
        jae     .eof
        cmp     byte [rsi], 0xFF
        jne     .fn1
        movzx   ecx, byte [rsi+1]
        test    ecx, ecx
        jz      .fn1
        cmp     ecx, 0xFF
        jne     .m
.fn1:   inc     rsi
        jmp     .fnd
.m:     add     rsi, 2                          ; rsi = after the marker, ecx = marker
        mov     [rbx+JS_POS], rsi
        cmp     ecx, 0xD8
        je      .marker
        cmp     ecx, 0xD9
        je      .eof
        cmp     ecx, 0x01
        je      .marker
        mov     eax, ecx
        and     eax, 0xF8
        cmp     eax, 0xD0
        je      .marker                         ; stray RSTn
        lea     rax, [rsi+2]
        cmp     rax, rdx
        ja      .eof
        movzx   eax, word [rsi]
        xchg    al, ah                          ; segment length including its own two bytes
        cmp     eax, 2
        jb      .fail
        lea     r8, [rsi+rax]
        cmp     r8, rdx
        ja      .eof                            ; truncated segment
        mov     r12d, ecx                       ; marker
        lea     rsi, [rsi+2]                    ; payload
        lea     r13d, [rax-2]                   ; payload length
        mov     r14, r8                         ; start of the next marker
        cmp     r12d, 0xC0
        je      .sof
        cmp     r12d, 0xC1
        je      .sof
        cmp     r12d, 0xC4
        je      .dht
        cmp     r12d, 0xDB
        je      .dqt
        cmp     r12d, 0xDD
        je      .dri
        cmp     r12d, 0xDA
        je      .sos
        cmp     r12d, 0xEE
        je      .app14
        cmp     r12d, 0xC2                      ; progressive, lossless, hierarchical, arithmetic: not ours
        jb      .skip
        cmp     r12d, 0xCF
        ja      .skip
        cmp     r12d, 0xC8
        je      .skip
        jmp     .fail
.skip:  mov     [rbx+JS_POS], r14
        jmp     .marker
.app14: cmp     r13d, 12
        jb      .skip
        cmp     dword [rsi], 0x626F6441         ; "Adob"
        jne     .skip
        movzx   eax, byte [rsi+11]
        mov     [rbx+JS_ADOBE], eax
        jmp     .skip
.dri:   cmp     r13d, 2
        jb      .fail
        movzx   eax, word [rsi]
        xchg    al, ah
        mov     [rbx+JS_RI], eax
        jmp     .skip
.dqt:   mov     rdi, rsi
        lea     r15, [rsi+r13]                  ; end of the payload
.dq1:   cmp     rdi, r15
        jae     .skip
        movzx   eax, byte [rdi]
        inc     rdi
        mov     ecx, eax
        and     ecx, 15                         ; table
        shr     eax, 4                          ; 0 = 8-bit values, 1 = 16-bit
        cmp     ecx, 3
        ja      .fail
        cmp     eax, 1
        ja      .fail
        lea     rdx, [rdi+64]
        test    eax, eax
        jz      .dq8
        lea     rdx, [rdi+128]
.dq8:   cmp     rdx, r15
        ja      .fail
        shl     ecx, 8
        lea     r8, [rbx+JS_QT+rcx]
        xor     ecx, ecx
.dq2:   lea     r9, [jp_zz]
        movzx   r9d, byte [r9+rcx]
        test    eax, eax
        jnz     .dq16
        movzx   r10d, byte [rdi+rcx]
        jmp     .dqs
.dq16:  movzx   r10d, word [rdi+rcx*2]
        rol     r10w, 8
.dqs:   mov     [r8+r9*4], r10d
        inc     ecx
        cmp     ecx, 64
        jb      .dq2
        mov     rdi, rdx
        jmp     .dq1
.dht:   mov     rdi, rsi
        lea     r15, [rsi+r13]
.dh1:   cmp     rdi, r15
        jae     .skip
        lea     rax, [rdi+17]
        cmp     rax, r15
        ja      .fail
        movzx   eax, byte [rdi]
        mov     ecx, eax
        and     ecx, 15                         ; table number
        shr     eax, 4                          ; class: 0 DC, 1 AC
        cmp     ecx, 3
        ja      .fail
        cmp     eax, 1
        ja      .fail
        lea     eax, [rcx+rax*4]
        mov     r9d, eax                        ; table index
        imul    eax, JH_SIZE
        lea     r10, [rbx+JS_HT+rax]
        lea     rsi, [rdi+1]                    ; the 16 counts
        xor     ecx, ecx
        xor     r8d, r8d
.dh2:   movzx   eax, byte [rsi+rcx]
        add     r8d, eax
        inc     ecx
        cmp     ecx, 16
        jb      .dh2
        lea     rdx, [rsi+16]                   ; the symbols
        lea     rax, [rdx+r8]
        cmp     rax, r15
        ja      .fail
        mov     r12d, r9d
        mov     r13, rax                        ; end of this table
        mov     rdi, r10
        call    jp_build_ht
        test    eax, eax
        jnz     .fail
        mov     byte [rbx+JS_DEF+r12], 1
        mov     rdi, r13
        jmp     .dh1
.sof:   cmp     dword [rbx+JS_FRAME], 0
        jne     .fail
        cmp     r13d, 6
        jb      .fail
        cmp     byte [rsi], 8
        jne     .fail                           ; 8-bit samples only
        movzx   eax, word [rsi+1]
        xchg    al, ah
        mov     [rbx+JS_H], eax
        movzx   eax, word [rsi+3]
        xchg    al, ah
        mov     [rbx+JS_W], eax
        movzx   eax, byte [rsi+5]
        mov     [rbx+JS_NCOMP], eax
        cmp     eax, 1
        je      .nc_ok
        cmp     eax, 3
        jne     .fail
.nc_ok: lea     ecx, [rax+rax*2]
        add     ecx, 6
        cmp     ecx, r13d
        ja      .fail
        mov     eax, [rbx+JS_W]
        mov     ecx, [rbx+JS_H]
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
        cmp     rdx, 16000000                   ; more than 16 megapixels is not cover art
        ja      .fail
        mov     dword [rbx+JS_HMAX], 1
        mov     dword [rbx+JS_VMAX], 1
        xor     r8d, r8d
.sc:    cmp     r8d, [rbx+JS_NCOMP]
        jae     .scd
        lea     eax, [r8+r8*2]
        lea     rdi, [rsi+6+rax]
        movzx   eax, byte [rdi]                 ; id
        movzx   ecx, byte [rdi+1]               ; sampling factors
        movzx   edx, byte [rdi+2]               ; quantisation table
        mov     r9d, r8d
        shl     r9d, 6
        mov     [rbx+JS_COMP+r9+JC_ID], eax
        mov     eax, ecx
        shr     eax, 4
        and     ecx, 15
        jz      .fail
        test    eax, eax
        jz      .fail
        cmp     eax, 4
        ja      .fail
        cmp     ecx, 4
        ja      .fail
        cmp     edx, 3
        ja      .fail
        mov     [rbx+JS_COMP+r9+JC_H], eax
        mov     [rbx+JS_COMP+r9+JC_V], ecx
        mov     [rbx+JS_COMP+r9+JC_TQ], edx
        cmp     eax, [rbx+JS_HMAX]
        jbe     .h1
        mov     [rbx+JS_HMAX], eax
.h1:    cmp     ecx, [rbx+JS_VMAX]
        jbe     .v1
        mov     [rbx+JS_VMAX], ecx
.v1:    inc     r8d
        jmp     .sc
.scd:   ; MCU geometry and planes
        mov     eax, [rbx+JS_HMAX]
        shl     eax, 3
        mov     r8d, eax                        ; MCU width in pixels
        mov     eax, [rbx+JS_W]
        add     eax, r8d
        dec     eax
        xor     edx, edx
        div     r8d
        mov     [rbx+JS_MCUX], eax
        mov     eax, [rbx+JS_VMAX]
        shl     eax, 3
        mov     r8d, eax
        mov     eax, [rbx+JS_H]
        add     eax, r8d
        dec     eax
        xor     edx, edx
        div     r8d
        mov     [rbx+JS_MCUY], eax
        xor     r8d, r8d
.pl:    cmp     r8d, [rbx+JS_NCOMP]
        jae     .pld
        mov     r9d, r8d
        shl     r9d, 6
        mov     eax, [rbx+JS_MCUX]
        imul    eax, [rbx+JS_COMP+r9+JC_H]
        shl     eax, 3
        mov     [rbx+JS_COMP+r9+JC_STRIDE], eax
        mov     ecx, [rbx+JS_MCUY]
        imul    ecx, [rbx+JS_COMP+r9+JC_V]
        shl     ecx, 3
        mov     [rbx+JS_COMP+r9+JC_PH], ecx
        imul    rax, rcx                        ; bytes
        mov     rcx, rax
        mov     loc(3), r8
        mov     loc(4), r9
        call    mem_alloc
        mov     r8, loc(3)
        mov     r9, loc(4)
        mov     [rbx+JS_COMP+r9+JC_PLANE], rax
        ; blocks of a non-interleaved scan: ceil(component width / 8) by ceil(component height / 8)
        mov     eax, [rbx+JS_W]
        imul    eax, [rbx+JS_COMP+r9+JC_H]
        add     eax, [rbx+JS_HMAX]
        dec     eax
        xor     edx, edx
        div     dword [rbx+JS_HMAX]             ; component width in pixels
        add     eax, 7
        shr     eax, 3
        mov     [rbx+JS_COMP+r9+JC_BW], eax
        mov     eax, [rbx+JS_H]
        imul    eax, [rbx+JS_COMP+r9+JC_V]
        add     eax, [rbx+JS_VMAX]
        dec     eax
        xor     edx, edx
        div     dword [rbx+JS_VMAX]
        add     eax, 7
        shr     eax, 3
        mov     [rbx+JS_COMP+r9+JC_BH], eax
        inc     r8d
        jmp     .pl
.pld:   mov     dword [rbx+JS_FRAME], 1
        jmp     .skip
.sos:   cmp     dword [rbx+JS_FRAME], 0
        je      .fail
        mov     [rbx+JS_POS], r14               ; entropy-coded data starts after the header
        call    jp_scan                         ; (rsi = header payload)
        test    eax, eax
        jnz     .fail
        inc     dword [rbx+JS_SCANS]
        jmp     .marker
.eof:   cmp     dword [rbx+JS_SCANS], 0
        je      .fail
        call    jp_upsample
        call    jp_convert
        mov     loc(5), rax
        jmp     .free
.fail:  mov     qword loc(5), 0
.free:  xor     r13d, r13d                      ; the planes
.fp:    cmp     r13d, 4
        jae     .fpd
        mov     eax, r13d
        shl     eax, 6
        mov     rcx, [rbx+JS_COMP+rax+JC_PLANE]
        call    mem_free
        inc     r13d
        jmp     .fp
.fpd:   mov     rcx, rbx
        call    mem_free
        mov     rax, loc(5)
        EPROC
