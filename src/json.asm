; json.asm - allocation-free JSON scanner for NUL-terminated UTF-8 text.
;
; Values are addressed by pointer to their first byte. Nothing is parsed into a tree:
; json_get / json_at / json_path walk the text on demand, json_str_* decode a string value.
; All functions treat a NUL byte as end of input, so every JSON buffer must be NUL-terminated.

section .text

json_ws:                                ; rcx = p -> rax = first non-blank at/after p
.l:     mov     al, [rcx]
        cmp     al, ' '
        je      .n
        cmp     al, 9
        je      .n
        cmp     al, 10
        je      .n
        cmp     al, 13
        jne     .d
.n:     inc     rcx
        jmp     .l
.d:     mov     rax, rcx
        ret

json_skip_str:                          ; rcx at opening quote -> rax past closing quote, 0 on error
        inc     rcx
.l:     mov     al, [rcx]
        test    al, al
        jz      .err
        cmp     al, '\'
        je      .esc
        cmp     al, '"'
        je      .end
        inc     rcx
        jmp     .l
.esc:   cmp     byte [rcx+1], 0
        je      .err
        add     rcx, 2
        jmp     .l
.end:   lea     rax, [rcx+1]
        ret
.err:   xor     eax, eax
        ret

; rcx = p -> rax = pointer just past the value starting at/after p (0 on malformed input)
PROC json_skip, 1
        test    rcx, rcx
        jz      .err
        call    json_ws
        mov     rcx, rax
        mov     al, [rcx]
        test    al, al
        jz      .err
        cmp     al, '"'
        je      .str
        cmp     al, '{'
        je      .nest
        cmp     al, '['
        je      .nest
.lit:   mov     al, [rcx]
        test    al, al
        jz      .litend
        cmp     al, ','
        je      .litend
        cmp     al, '}'
        je      .litend
        cmp     al, ']'
        je      .litend
        cmp     al, ' '
        je      .litend
        cmp     al, 9
        je      .litend
        cmp     al, 10
        je      .litend
        cmp     al, 13
        je      .litend
        inc     rcx
        jmp     .lit
.litend:
        mov     rax, rcx
        jmp     .out
.str:   call    json_skip_str
        jmp     .out
.nest:  mov     qword loc(0), 0
.nl:    mov     al, [rcx]
        test    al, al
        jz      .err
        cmp     al, '"'
        jne     .nq
        call    json_skip_str
        test    rax, rax
        jz      .out
        mov     rcx, rax
        jmp     .nl
.nq:    cmp     al, '{'
        je      .open
        cmp     al, '['
        je      .open
        cmp     al, '}'
        je      .close
        cmp     al, ']'
        je      .close
        inc     rcx
        jmp     .nl
.open:  inc     qword loc(0)
        inc     rcx
        jmp     .nl
.close: dec     qword loc(0)
        inc     rcx
        cmp     qword loc(0), 0
        jne     .nl
        mov     rax, rcx
        jmp     .out
.err:   xor     eax, eax
.out:   EPROC

mem_eq:                                 ; rcx, rdx, r8 = n -> eax = 1 if equal
        test    r8, r8
        jz      .y
.l:     mov     al, [rcx]
        cmp     al, [rdx]
        jne     .n
        inc     rcx
        inc     rdx
        dec     r8
        jnz     .l
.y:     mov     eax, 1
        ret
.n:     xor     eax, eax
        ret

; rcx = p (object), rdx = key (z-string) -> rax = pointer to the member's value, 0 if absent
PROC json_get, 3
        mov     loc(0), rdx
        test    rcx, rcx
        jz      .none
        call    json_ws
        mov     rbx, rax
        cmp     byte [rbx], '{'
        jne     .none
        inc     rbx
        mov     rcx, loc(0)
        call    u8_len
        mov     loc(1), rax
.loop:  mov     rcx, rbx
        call    json_ws
        mov     rbx, rax
        mov     al, [rbx]
        cmp     al, ','
        jne     .nc
        inc     rbx
        jmp     .loop
.nc:    cmp     al, '"'
        jne     .none
        xor     r12d, r12d
        lea     rsi, [rbx+1]
        mov     rcx, rbx
        call    json_skip_str
        test    rax, rax
        jz      .none
        mov     rdi, rax
        lea     rax, [rdi-1]
        sub     rax, rsi
        cmp     rax, loc(1)
        jne     .nm
        mov     rcx, rsi
        mov     rdx, loc(0)
        mov     r8, rax
        call    mem_eq
        mov     r12d, eax
.nm:    mov     rcx, rdi
        call    json_ws
        cmp     byte [rax], ':'
        jne     .none
        lea     rcx, [rax+1]
        call    json_ws
        mov     rbx, rax
        test    r12d, r12d
        jnz     .found
        mov     rcx, rbx
        call    json_skip
        test    rax, rax
        jz      .none
        mov     rbx, rax
        jmp     .loop
.found: mov     rax, rbx
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC

; rcx = p (array), rdx = index -> rax = pointer to element, 0 if out of range
PROC json_at, 1
        mov     loc(0), rdx
        test    rcx, rcx
        jz      .none
        call    json_ws
        mov     rbx, rax
        cmp     byte [rbx], '['
        jne     .none
        inc     rbx
        xor     r12d, r12d
.loop:  mov     rcx, rbx
        call    json_ws
        mov     rbx, rax
        mov     al, [rbx]
        test    al, al
        jz      .none
        cmp     al, ']'
        je      .none
        cmp     r12, loc(0)
        je      .found
        mov     rcx, rbx
        call    json_skip
        test    rax, rax
        jz      .none
        mov     rcx, rax
        call    json_ws
        mov     rbx, rax
        cmp     byte [rbx], ','
        jne     .none
        inc     rbx
        inc     r12
        jmp     .loop
.found: mov     rax, rbx
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC

; rcx = p (array) -> rax = number of elements
PROC json_count, 0
        xor     r12d, r12d
        test    rcx, rcx
        jz      .out
        call    json_ws
        mov     rbx, rax
        cmp     byte [rbx], '['
        jne     .out
        inc     rbx
.loop:  mov     rcx, rbx
        call    json_ws
        mov     rbx, rax
        mov     al, [rbx]
        test    al, al
        jz      .out
        cmp     al, ']'
        je      .out
        mov     rcx, rbx
        call    json_skip
        test    rax, rax
        jz      .out
        inc     r12
        mov     rcx, rax
        call    json_ws
        mov     rbx, rax
        cmp     byte [rbx], ','
        jne     .out
        inc     rbx
        jmp     .loop
.out:   mov     rax, r12
        EPROC

; rcx = p, rdx = path such as "items.0.track.name" -> rax = value pointer or 0
PROC json_path, 10
        mov     loc(0), rdx
        mov     loc(1), rcx
.seg:   mov     rsi, loc(0)
        cmp     byte [rsi], 0
        je      .done
        lea     rdi, loc(9)             ; 64-byte segment buffer
        xor     ecx, ecx
.cp:    mov     al, [rsi]
        test    al, al
        jz      .cpe
        cmp     al, '.'
        je      .cpe
        cmp     ecx, 62
        jae     .none
        mov     [rdi+rcx], al
        inc     rcx
        inc     rsi
        jmp     .cp
.cpe:   mov     byte [rdi+rcx], 0
        cmp     al, '.'
        jne     .nodot
        inc     rsi
.nodot: mov     loc(0), rsi
        ; numeric segment?
        test    ecx, ecx
        jz      .none
        xor     eax, eax
        xor     edx, edx
.num:   movzx   r8d, byte [rdi+rdx]
        sub     r8d, '0'
        cmp     r8d, 9
        ja      .key
        imul    rax, rax, 10
        add     rax, r8
        inc     rdx
        cmp     rdx, rcx
        jb      .num
        mov     rdx, rax
        mov     rcx, loc(1)
        call    json_at
        jmp     .got
.key:   mov     rcx, loc(1)
        mov     rdx, rdi
        call    json_get
.got:   test    rax, rax
        jz      .none
        mov     loc(1), rax
        jmp     .seg
.done:  mov     rax, loc(1)
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC

hex4:                                   ; rcx = 4 hex digits -> eax = value, -1 if invalid
        xor     eax, eax
        mov     r8d, 4
.l:     movzx   edx, byte [rcx]
        inc     rcx
        cmp     dl, '0'
        jb      .bad
        cmp     dl, '9'
        jbe     .dg
        or      dl, 0x20
        cmp     dl, 'a'
        jb      .bad
        cmp     dl, 'f'
        ja      .bad
        sub     dl, 'a' - 10
        jmp     .acc
.dg:    sub     dl, '0'
.acc:   shl     eax, 4
        or      al, dl
        dec     r8d
        jnz     .l
        ret
.bad:   mov     eax, -1
        ret

; rdi = dst, eax = code point -> rdi advanced past the UTF-8 bytes
utf8_put:
        cmp     eax, 0x80
        jae     .2
        mov     [rdi], al
        inc     rdi
        ret
.2:     cmp     eax, 0x800
        jae     .3
        mov     edx, eax
        shr     edx, 6
        or      dl, 0xC0
        mov     [rdi], dl
        and     al, 0x3F
        or      al, 0x80
        mov     [rdi+1], al
        add     rdi, 2
        ret
.3:     cmp     eax, 0x10000
        jae     .4
        mov     edx, eax
        shr     edx, 12
        or      dl, 0xE0
        mov     [rdi], dl
        mov     edx, eax
        shr     edx, 6
        and     dl, 0x3F
        or      dl, 0x80
        mov     [rdi+1], dl
        and     al, 0x3F
        or      al, 0x80
        mov     [rdi+2], al
        add     rdi, 3
        ret
.4:     mov     edx, eax
        shr     edx, 18
        or      dl, 0xF0
        mov     [rdi], dl
        mov     edx, eax
        shr     edx, 12
        and     dl, 0x3F
        or      dl, 0x80
        mov     [rdi+1], dl
        mov     edx, eax
        shr     edx, 6
        and     dl, 0x3F
        or      dl, 0x80
        mov     [rdi+2], dl
        and     al, 0x3F
        or      al, 0x80
        mov     [rdi+3], al
        add     rdi, 4
        ret

; rcx = pointer to a JSON string value -> rax = heap UTF-8 text with escapes decoded, rdx = byte length.
; Anything that is not a string (null, numbers, missing) yields "".
PROC json_str_u8, 3
        test    rcx, rcx
        jz      .empty
        cmp     byte [rcx], '"'
        jne     .empty
        lea     rsi, [rcx+1]
        mov     loc(0), rsi
        call    json_skip_str
        test    rax, rax
        jz      .empty
        sub     rax, rsi
        lea     rcx, [rax+1]
        call    mem_alloc
        mov     loc(1), rax
        mov     rdi, rax
        mov     rsi, loc(0)
.l:     mov     al, [rsi]
        test    al, al
        jz      .fin
        cmp     al, '"'
        je      .fin
        cmp     al, '\'
        je      .esc
        mov     [rdi], al
        inc     rdi
        inc     rsi
        jmp     .l
.esc:   movzx   eax, byte [rsi+1]
        add     rsi, 2
        cmp     al, 'n'
        jne     .e1
        mov     al, 10
        jmp     .lit
.e1:    cmp     al, 't'
        jne     .e2
        mov     al, 9
        jmp     .lit
.e2:    cmp     al, 'r'
        jne     .e3
        mov     al, 13
        jmp     .lit
.e3:    cmp     al, 'b'
        jne     .e4
        mov     al, 8
        jmp     .lit
.e4:    cmp     al, 'f'
        jne     .e5
        mov     al, 12
        jmp     .lit
.e5:    cmp     al, 'u'
        jne     .lit                    ; \" \\ \/ -> the character itself
        mov     rcx, rsi
        call    hex4
        cmp     eax, -1
        jne     .u1
        mov     al, '?'
        jmp     .lit
.u1:    add     rsi, 4
        mov     r12d, eax
        and     eax, 0xFC00
        cmp     eax, 0xD800
        jne     .put
        cmp     byte [rsi], '\'
        jne     .put
        cmp     byte [rsi+1], 'u'
        jne     .put
        lea     rcx, [rsi+2]
        call    hex4
        cmp     eax, 0xDC00
        jb      .put
        cmp     eax, 0xDFFF
        ja      .put
        sub     eax, 0xDC00
        mov     edx, r12d
        sub     edx, 0xD800
        shl     edx, 10
        lea     r12d, [rdx+rax+0x10000]
        add     rsi, 6
.put:   mov     eax, r12d
        call    utf8_put
        jmp     .l
.lit:   mov     [rdi], al
        inc     rdi
        jmp     .l
.fin:   mov     byte [rdi], 0
        mov     rax, loc(1)
        mov     rdx, rdi
        sub     rdx, rax
        jmp     .out
.empty: mov     ecx, 1
        call    mem_alloc
        xor     edx, edx
.out:   EPROC

; rcx = pointer to a JSON string value -> rax = heap UTF-16 string ("" for non-strings)
PROC json_str_w, 1
        call    json_str_u8
        mov     loc(0), rax
        mov     rcx, rax
        mov     rdx, -1
        call    u8_to_w
        mov     rbx, rax
        mov     rcx, loc(0)
        call    mem_free
        mov     rax, rbx
        EPROC

; rcx = pointer to a JSON number -> rax = integer part (signed); 0 for non-numbers
json_int:
        test    rcx, rcx
        jz      .z
        xor     eax, eax
        xor     r8d, r8d
        cmp     byte [rcx], '-'
        jne     .d
        mov     r8d, 1
        inc     rcx
.d:     movzx   edx, byte [rcx]
        sub     edx, '0'
        cmp     edx, 9
        ja      .e
        imul    rax, rax, 10
        add     rax, rdx
        inc     rcx
        jmp     .d
.e:     test    r8d, r8d
        jz      .r
        neg     rax
.r:     ret
.z:     xor     eax, eax
        ret

; rcx = pointer to a JSON literal -> eax = 1 for true
json_bool:
        test    rcx, rcx
        jz      .f
        cmp     byte [rcx], 't'
        sete    al
        movzx   eax, al
        ret
.f:     xor     eax, eax
        ret
