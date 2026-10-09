; core.asm - heap, string, conversion and buffer helpers (Win64 ABI).

extern GetProcessHeap, HeapAlloc, HeapFree, HeapReAlloc, ExitProcess
extern MultiByteToWideChar, WideCharToMultiByte, lstrlenW, WriteFile, GetStdHandle

; UTF-16 strings start on an even address: the kernel probes the class name, mutex name ... it is handed with
; 2-byte alignment, so a string that happened to land on an odd address made RegisterClassExW fail on real
; Windows (Wine does not check).
%macro WSTR 2
        align 2
%1:     dw __utf16__(%2), 0
%endmacro

section .bss
g_heap:         resq 1
g_wr:           resd 1

section .text

; ---------------------------------------------------------------- memory
core_init:
        sub     rsp, 40
        call    GetProcessHeap
        mov     [g_heap], rax
        add     rsp, 40
        ret

; rcx = size -> rax = zeroed block (never returns NULL)
mem_alloc:
        sub     rsp, 40
        mov     r8, rcx
        mov     rcx, [g_heap]
        mov     edx, HEAP_ZERO_MEMORY
        call    HeapAlloc
        test    rax, rax
        jnz     .ok
        mov     ecx, 3
        call    ExitProcess
.ok:    add     rsp, 40
        ret

mem_free:                               ; rcx = ptr (NULL ok)
        test    rcx, rcx
        jz      .r
        sub     rsp, 40
        mov     r8, rcx
        mov     rcx, [g_heap]
        xor     edx, edx
        call    HeapFree
        add     rsp, 40
.r:     ret

mem_realloc:                            ; rcx = ptr (NULL ok), rdx = new size
        test    rcx, rcx
        jnz     .re
        mov     rcx, rdx
        jmp     mem_alloc
.re:    sub     rsp, 40
        mov     r9, rdx
        mov     r8, rcx
        mov     rcx, [g_heap]
        mov     edx, HEAP_ZERO_MEMORY
        call    HeapReAlloc
        test    rax, rax
        jnz     .ok
        mov     ecx, 3
        call    ExitProcess
.ok:    add     rsp, 40
        ret

mem_copy:                               ; rcx = dst, rdx = src, r8 = n -> rax = dst
        push    rsi
        push    rdi
        mov     rax, rcx
        mov     rdi, rcx
        mov     rsi, rdx
        mov     rcx, r8
        rep     movsb
        pop     rdi
        pop     rsi
        ret

mem_zero:                               ; rcx = dst, rdx = n
        push    rdi
        mov     rdi, rcx
        mov     rcx, rdx
        xor     eax, eax
        rep     stosb
        pop     rdi
        ret

; ---------------------------------------------------------------- C strings (UTF-8)
u8_len:                                 ; rcx -> rax
        xor     eax, eax
.l:     cmp     byte [rcx+rax], 0
        je      .r
        inc     rax
        jmp     .l
.r:     ret

u8_eq:                                  ; rcx, rdx -> eax = 1 if equal
.l:     mov     al, [rcx]
        cmp     al, [rdx]
        jne     .no
        test    al, al
        jz      .yes
        inc     rcx
        inc     rdx
        jmp     .l
.yes:   mov     eax, 1
        ret
.no:    xor     eax, eax
        ret

u8_starts:                              ; rcx = s, rdx = prefix -> eax = 1 if s starts with prefix
.l:     mov     al, [rdx]
        test    al, al
        jz      .yes
        cmp     al, [rcx]
        jne     .no
        inc     rcx
        inc     rdx
        jmp     .l
.yes:   mov     eax, 1
        ret
.no:    xor     eax, eax
        ret

; rcx = z-string -> rax = heap copy
PROC u8_dup, 2
        mov     loc(0), rcx
        call    u8_len
        mov     loc(1), rax
        lea     rcx, [rax+1]
        call    mem_alloc
        mov     rcx, rax
        mov     rdx, loc(0)
        mov     r8, loc(1)
        call    mem_copy                ; returns dst
        EPROC

; ---------------------------------------------------------------- UTF-8 <-> UTF-16
; rcx = utf8, rdx = byte length or -1 for NUL-terminated -> rax = heap wide string (NUL-terminated)
PROC u8_to_w, 4
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     ecx, 65001
        xor     edx, edx
        mov     r8, loc(0)
        mov     r9, loc(1)
        mov     qword outarg(5), 0
        mov     qword outarg(6), 0
        call    MultiByteToWideChar
        mov     loc(2), rax
        lea     rcx, [rax*2+2]
        call    mem_alloc
        mov     loc(3), rax
        mov     ecx, 65001
        xor     edx, edx
        mov     r8, loc(0)
        mov     r9, loc(1)
        mov     rax, loc(3)
        mov     outarg(5), rax
        mov     rax, loc(2)
        mov     outarg(6), rax
        call    MultiByteToWideChar
        mov     rax, loc(3)
        EPROC

; rcx = wide, rdx = wchar count or -1 -> rax = heap UTF-8 (NUL-terminated), rdx = length in bytes
PROC w_to_u8, 4
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     ecx, 65001
        xor     edx, edx
        mov     r8, loc(0)
        mov     r9, loc(1)
        mov     qword outarg(5), 0
        mov     qword outarg(6), 0
        mov     qword outarg(7), 0
        mov     qword outarg(8), 0
        call    WideCharToMultiByte
        mov     loc(2), rax
        lea     rcx, [rax+1]
        call    mem_alloc
        mov     loc(3), rax
        mov     ecx, 65001
        xor     edx, edx
        mov     r8, loc(0)
        mov     r9, loc(1)
        mov     rax, loc(3)
        mov     outarg(5), rax
        mov     rax, loc(2)
        mov     outarg(6), rax
        mov     qword outarg(7), 0
        mov     qword outarg(8), 0
        call    WideCharToMultiByte
        mov     rdx, loc(2)
        cmp     qword loc(1), -1
        jne     .ret
        dec     rdx                     ; count included the terminator
.ret:   mov     rax, loc(3)
        EPROC

; ---------------------------------------------------------------- numbers
; rcx = dst (bytes), rdx = value -> rax = end pointer (no NUL written)
u8_put_u64:
        push    rbx
        mov     r8, rcx
        mov     rax, rdx
        mov     r9d, 10
        xor     ecx, ecx
.d:     xor     edx, edx
        div     r9
        add     dl, '0'
        push    rdx
        inc     ecx
        test    rax, rax
        jnz     .d
.p:     pop     rax
        mov     [r8], al
        inc     r8
        dec     ecx
        jnz     .p
        mov     rax, r8
        pop     rbx
        ret

; rcx = dst (wchars), rdx = value -> rax = end pointer
w_put_u64:
        push    rbx
        mov     r8, rcx
        mov     rax, rdx
        mov     r9d, 10
        xor     ecx, ecx
.d:     xor     edx, edx
        div     r9
        add     dl, '0'
        push    rdx
        inc     ecx
        test    rax, rax
        jnz     .d
.p:     pop     rax
        mov     [r8], ax
        add     r8, 2
        dec     ecx
        jnz     .p
        mov     rax, r8
        pop     rbx
        ret

; rcx = dst (wchars), rdx = milliseconds -> writes "m:ss\0" ; rax = end pointer (at the NUL)
PROC w_fmt_time, 2
        mov     loc(0), rcx
        mov     rax, rdx
        xor     edx, edx
        mov     ecx, 1000
        div     rcx                     ; rax = seconds
        xor     edx, edx
        mov     ecx, 60
        div     rcx                     ; rax = minutes, rdx = seconds
        mov     loc(1), rdx
        mov     rcx, loc(0)
        mov     rdx, rax
        call    w_put_u64
        mov     word [rax], ':'
        add     rax, 2
        mov     rdx, loc(1)
        cmp     rdx, 10
        jae     .two
        mov     word [rax], '0'
        add     rax, 2
.two:   mov     rcx, rax
        call    w_put_u64
        mov     word [rax], 0
        EPROC

; ---------------------------------------------------------------- growable byte buffer
; struct Buf { qword ptr; qword len; qword cap }
%define BUF_PTR 0
%define BUF_LEN 8
%define BUF_CAP 16

PROC buf_reserve, 0                     ; rcx = buf, rdx = extra bytes
        mov     rbx, rcx
        mov     rax, [rbx+BUF_LEN]
        lea     rax, [rax+rdx+1]
        cmp     rax, [rbx+BUF_CAP]
        jbe     .ok
        mov     rcx, [rbx+BUF_CAP]
        add     rcx, rcx
        cmp     rcx, 256
        jae     .big
        mov     ecx, 256
.big:   cmp     rcx, rax
        jae     .go
        mov     rcx, rax
.go:    mov     [rbx+BUF_CAP], rcx
        mov     rdx, rcx
        mov     rcx, [rbx+BUF_PTR]
        call    mem_realloc
        mov     [rbx+BUF_PTR], rax
.ok:    EPROC

PROC buf_append, 2                      ; rcx = buf, rdx = src, r8 = n
        mov     rbx, rcx
        mov     loc(0), rdx
        mov     loc(1), r8
        mov     rdx, r8
        mov     rcx, rbx
        call    buf_reserve
        mov     rcx, [rbx+BUF_PTR]
        add     rcx, [rbx+BUF_LEN]
        mov     rdx, loc(0)
        mov     r8, loc(1)
        call    mem_copy
        mov     rax, loc(1)
        add     [rbx+BUF_LEN], rax
        mov     rax, [rbx+BUF_PTR]
        add     rax, [rbx+BUF_LEN]
        mov     byte [rax], 0
        EPROC

PROC buf_append_z, 1                    ; rcx = buf, rdx = z-string
        mov     rbx, rcx
        mov     loc(0), rdx
        mov     rcx, rdx
        call    u8_len
        mov     r8, rax
        mov     rcx, rbx
        mov     rdx, loc(0)
        call    buf_append
        EPROC

PROC buf_append_char, 1                 ; rcx = buf, dl = byte
        mov     loc(0), rdx
        lea     rdx, loc(0)
        mov     r8d, 1
        call    buf_append
        EPROC

PROC buf_append_u64, 3                  ; rcx = buf, rdx = value
        mov     rbx, rcx
        lea     rcx, loc(2)                     ; 24-byte digit scratch: loc(2)..loc(0)
        call    u8_put_u64
        lea     rdx, loc(2)
        mov     r8, rax
        sub     r8, rdx
        mov     rcx, rbx
        call    buf_append
        EPROC

; percent-encode (RFC 3986 unreserved kept). rcx = buf, rdx = src, r8 = n
PROC buf_append_urlenc, 3
        mov     rbx, rcx
        mov     rsi, rdx
        mov     rdi, r8
.next:  test    rdi, rdi
        jz      .done
        movzx   eax, byte [rsi]
        inc     rsi
        dec     rdi
        cmp     al, 'a'
        jb      .up
        cmp     al, 'z'
        jbe     .lit
.up:    cmp     al, 'A'
        jb      .dig
        cmp     al, 'Z'
        jbe     .lit
.dig:   cmp     al, '0'
        jb      .sym
        cmp     al, '9'
        jbe     .lit
.sym:   cmp     al, '-'
        je      .lit
        cmp     al, '.'
        je      .lit
        cmp     al, '_'
        je      .lit
        cmp     al, '~'
        je      .lit
        ; %XX
        mov     r12d, eax
        mov     rcx, rbx
        mov     edx, '%'
        call    buf_append_char
        mov     eax, r12d
        shr     eax, 4
        call    hexdigit
        mov     rcx, rbx
        movzx   edx, al
        call    buf_append_char
        mov     eax, r12d
        and     eax, 15
        call    hexdigit
        mov     rcx, rbx
        movzx   edx, al
        call    buf_append_char
        jmp     .next
.lit:   mov     rcx, rbx
        movzx   edx, al
        call    buf_append_char
        jmp     .next
.done:  EPROC

hexdigit:                               ; al = 0..15 -> al = '0'..'f' (uppercase)
        cmp     al, 10
        jb      .d
        add     al, 'A' - 10
        ret
.d:     add     al, '0'
        ret

buf_reset:                              ; rcx = buf
        mov     qword [rcx+BUF_LEN], 0
        mov     rax, [rcx+BUF_PTR]
        test    rax, rax
        jz      .r
        mov     byte [rax], 0
.r:     ret

buf_free:                               ; rcx = buf
        push    rbx
        sub     rsp, 32
        mov     rbx, rcx
        mov     rcx, [rbx+BUF_PTR]
        call    mem_free
        mov     qword [rbx+BUF_PTR], 0
        mov     qword [rbx+BUF_LEN], 0
        mov     qword [rbx+BUF_CAP], 0
        add     rsp, 32
        pop     rbx
        ret

; ---------------------------------------------------------------- base64url (no padding)
; rcx = src, rdx = len, r8 = dst -> rax = output length
b64url_enc:
        push    rbx
        push    rsi
        push    rdi
        mov     rsi, rcx
        mov     rdi, r8
        mov     r9, r8                  ; start of dst
        lea     r10, [b64url_tab]
.blk:   cmp     rdx, 3
        jb      .tail
        movzx   eax, byte [rsi]
        shl     eax, 16
        movzx   ecx, byte [rsi+1]
        shl     ecx, 8
        or      eax, ecx
        movzx   ecx, byte [rsi+2]
        or      eax, ecx
        mov     ecx, eax
        shr     ecx, 18
        and     ecx, 63
        mov     bl, [r10+rcx]
        mov     [rdi], bl
        mov     ecx, eax
        shr     ecx, 12
        and     ecx, 63
        mov     bl, [r10+rcx]
        mov     [rdi+1], bl
        mov     ecx, eax
        shr     ecx, 6
        and     ecx, 63
        mov     bl, [r10+rcx]
        mov     [rdi+2], bl
        and     eax, 63
        mov     bl, [r10+rax]
        mov     [rdi+3], bl
        add     rsi, 3
        add     rdi, 4
        sub     rdx, 3
        jmp     .blk
.tail:  test    rdx, rdx
        jz      .done
        movzx   eax, byte [rsi]
        shl     eax, 16
        cmp     rdx, 2
        jb      .one
        movzx   ecx, byte [rsi+1]
        shl     ecx, 8
        or      eax, ecx
.one:   mov     ecx, eax
        shr     ecx, 18
        and     ecx, 63
        mov     bl, [r10+rcx]
        mov     [rdi], bl
        mov     ecx, eax
        shr     ecx, 12
        and     ecx, 63
        mov     bl, [r10+rcx]
        mov     [rdi+1], bl
        add     rdi, 2
        cmp     rdx, 2
        jb      .done
        mov     ecx, eax
        shr     ecx, 6
        and     ecx, 63
        mov     bl, [r10+rcx]
        mov     [rdi], bl
        inc     rdi
.done:  mov     rax, rdi
        sub     rax, r9
        pop     rdi
        pop     rsi
        pop     rbx
        ret

; ---------------------------------------------------------------- console/log output (stdout)
; rcx = z-string, writes to stdout (used by --selftest and diagnostics)
PROC out_z, 1
        mov     loc(0), rcx
        call    u8_len
        mov     r12, rax
        mov     ecx, -11
        call    GetStdHandle
        mov     rcx, rax
        mov     rdx, loc(0)
        mov     r8, r12
        lea     r9, [g_wr]
        mov     qword outarg(5), 0
        call    WriteFile
        EPROC

section .data
b64url_tab:     db "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

section .text
