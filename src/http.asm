; http.asm - synchronous HTTP(S) client over WinHTTP.  Safe to call from any thread.
;
; http_request(method_w, url_u8, headers_w, body, body_len, out_buf, retry_after_ptr) -> eax = HTTP status
;   method_w   UTF-16 verb ("GET", "POST", ...)
;   url_u8     UTF-8 absolute URL, http:// or https://
;   headers_w  UTF-16 "Name: value\r\n..." block, or 0
;   body       request body bytes or 0;  body_len its length
;   out_buf    Buf* that receives the response body (NUL-terminated); appended to, not reset
;   retry_ptr  optional dword* that receives the Retry-After header in seconds (0 if absent), or 0
; Returns 0 when the transport failed (no connection, timeout ...); g_http_err then holds GetLastError().

extern WinHttpOpen, WinHttpConnect, WinHttpOpenRequest, WinHttpSendRequest, WinHttpReceiveResponse
extern WinHttpQueryHeaders, WinHttpQueryDataAvailable, WinHttpReadData, WinHttpCloseHandle, WinHttpSetTimeouts
extern GetLastError

%define WINHTTP_FLAG_SECURE          0x00800000
%define WINHTTP_QUERY_STATUS_CODE    19
%define WINHTTP_QUERY_FLAG_NUMBER    0x20000000
%define WINHTTP_QUERY_CUSTOM         65535

section .bss
http_session:   resq 1
g_http_err:     resd 1

section .data
WSTR http_agent, "ByteStream/0.1"
WSTR http_retry_hdr, "Retry-After"
ZSTR url_https, "https://"
ZSTR url_http, "http://"

section .text

PROC http_init, 0
        lea     rcx, [http_agent]
        xor     edx, edx                        ; WINHTTP_ACCESS_TYPE_DEFAULT_PROXY
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword outarg(5), 0
        call    WinHttpOpen
        mov     [http_session], rax
        test    rax, rax
        jz      .out
        mov     rcx, rax
        mov     edx, 5000                       ; resolve
        mov     r8d, 5000                       ; connect
        mov     r9d, 15000                      ; send
        mov     dword outarg(5), 30000          ; receive
        call    WinHttpSetTimeouts
.out:   EPROC

; rcx = url (UTF-8), rdx = out[4] {secure, port, host_w*, path_w*}  -> eax = 1 on success, 0 if malformed.
; host_w and path_w are heap strings the caller frees.
PROC url_split, 6
        mov     loc(1), rdx
        mov     loc(0), rcx
        mov     qword [rdx], 0
        mov     qword [rdx+8], 80
        mov     qword [rdx+16], 0
        mov     qword [rdx+24], 0
        lea     rdx, [url_https]
        call    u8_starts
        test    eax, eax
        jz      .nohttps
        mov     rdx, loc(1)
        mov     qword [rdx], 1
        mov     qword [rdx+8], 443
        mov     rax, loc(0)
        add     rax, 8
        mov     loc(2), rax
        jmp     .host
.nohttps:
        mov     rcx, loc(0)
        lea     rdx, [url_http]
        call    u8_starts
        test    eax, eax
        jz      .bad
        mov     rax, loc(0)
        add     rax, 7
        mov     loc(2), rax
.host:  mov     rsi, loc(2)                     ; host start
        xor     ebx, ebx
.hl:    movzx   eax, byte [rsi+rbx]
        test    eax, eax
        jz      .hend
        cmp     eax, '/'
        je      .hend
        cmp     eax, ':'
        je      .hend
        cmp     eax, '?'
        je      .hend
        inc     ebx
        jmp     .hl
.hend:  test    ebx, ebx
        jz      .bad
        mov     rcx, rsi
        mov     rdx, rbx
        call    u8_to_w
        mov     rdx, loc(1)
        mov     [rdx+16], rax
        lea     rsi, [rsi+rbx]                  ; rsi -> terminator of the host
        cmp     byte [rsi], ':'
        jne     .path
        inc     rsi
        xor     eax, eax
.pl:    movzx   ecx, byte [rsi]
        sub     ecx, '0'
        cmp     ecx, 9
        ja      .pdone
        imul    eax, eax, 10
        add     eax, ecx
        inc     rsi
        jmp     .pl
.pdone: mov     rdx, loc(1)
        mov     [rdx+8], rax
.path:  cmp     byte [rsi], '/'
        je      .haspath
        cmp     byte [rsi], '?'
        je      .qpath
        lea     rcx, [path_root]                ; no path at all
        mov     rdx, -1
        call    u8_to_w
        jmp     .setpath
.qpath: mov     qword loc(3), 0                 ; "/" + "?query"
        mov     qword loc(4), 0
        mov     qword loc(5), 0
        lea     rcx, loc(5)
        lea     rdx, [path_root]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     rdx, rsi
        call    buf_append_z
        mov     rcx, loc(5)
        mov     rdx, -1
        call    u8_to_w
        mov     loc(2), rax
        lea     rcx, loc(5)
        call    buf_free
        mov     rax, loc(2)
        jmp     .setpath
.haspath:
        mov     rcx, rsi
        mov     rdx, -1
        call    u8_to_w
.setpath:
        mov     rdx, loc(1)
        mov     [rdx+24], rax
        mov     eax, 1
        jmp     .out
.bad:   xor     eax, eax
.out:   EPROC

section .data
ZSTR path_root, "/"
section .text

; See the header comment for the argument list.
PROC http_request, 18
        mov     loc(0), rcx                     ; method
        mov     loc(1), rdx                     ; url
        mov     loc(2), r8                      ; headers
        mov     loc(3), r9                      ; body
        mov     rax, stk5
        mov     loc(4), rax                     ; body length
        mov     rax, stk6
        mov     loc(5), rax                     ; out buf
        mov     rax, stk7
        mov     loc(6), rax                     ; retry-after ptr
        mov     qword loc(7), 0                 ; status
        mov     qword loc(8), 0                 ; connect handle
        mov     qword loc(9), 0                 ; request handle
        mov     rcx, loc(6)
        test    rcx, rcx
        jz      .nr
        mov     dword [rcx], 0
.nr:    ; url parts at &loc(13): secure=loc(13) port=loc(12) host=loc(11) path=loc(10)
        mov     rcx, loc(1)
        lea     rdx, loc(13)
        call    url_split
        test    eax, eax
        jz      .free
        mov     rcx, [http_session]
        test    rcx, rcx
        jz      .free
        mov     rdx, loc(11)
        mov     r8d, dword loc(12)
        xor     r9d, r9d
        call    WinHttpConnect
        mov     loc(8), rax
        test    rax, rax
        jz      .fail
        mov     rcx, rax
        mov     rdx, loc(0)
        mov     r8, loc(10)
        xor     r9d, r9d
        mov     qword outarg(5), 0
        mov     qword outarg(6), 0
        xor     eax, eax
        cmp     qword loc(13), 0
        je      .plain
        mov     eax, WINHTTP_FLAG_SECURE
.plain: mov     outarg(7), rax
        call    WinHttpOpenRequest
        mov     loc(9), rax
        test    rax, rax
        jz      .fail
        mov     rcx, rax
        mov     rdx, loc(2)
        mov     r8d, -1                         ; header block is NUL-terminated
        test    rdx, rdx
        jnz     .hdr
        xor     r8d, r8d
.hdr:   mov     r9, loc(3)
        mov     rax, loc(4)
        mov     outarg(5), rax                  ; optional data length
        mov     outarg(6), rax                  ; total length
        mov     qword outarg(7), 0
        call    WinHttpSendRequest
        test    eax, eax
        jz      .fail
        mov     rcx, loc(9)
        xor     edx, edx
        call    WinHttpReceiveResponse
        test    eax, eax
        jz      .fail
        mov     rcx, loc(9)
        mov     edx, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER
        xor     r8d, r8d
        lea     r9, loc(7)
        mov     dword loc(14), 4
        lea     rax, loc(14)
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        mov     qword loc(7), 0
        call    WinHttpQueryHeaders
        test    eax, eax
        jz      .fail
.read:  mov     rcx, loc(9)
        lea     rdx, loc(15)
        mov     qword loc(15), 0
        call    WinHttpQueryDataAvailable
        test    eax, eax
        jz      .rdone
        mov     eax, dword loc(15)
        test    eax, eax
        jz      .rdone
        mov     rcx, loc(5)
        mov     rdx, rax
        call    buf_reserve
        mov     rbx, loc(5)
        mov     rdx, [rbx+BUF_PTR]
        add     rdx, [rbx+BUF_LEN]
        mov     rcx, loc(9)
        mov     r8d, dword loc(15)
        lea     r9, loc(16)
        mov     dword loc(16), 0
        call    WinHttpReadData
        test    eax, eax
        jz      .rdone
        mov     eax, dword loc(16)
        test    eax, eax
        jz      .rdone
        mov     rbx, loc(5)
        add     [rbx+BUF_LEN], rax
        mov     rcx, [rbx+BUF_PTR]
        add     rcx, [rbx+BUF_LEN]
        mov     byte [rcx], 0
        jmp     .read
.rdone: mov     rcx, loc(6)
        test    rcx, rcx
        jz      .ok
        call    http_read_retry_after
.ok:    jmp     .free
.fail:  call    GetLastError
        mov     [g_http_err], eax
        mov     qword loc(7), 0
.free:  mov     rcx, loc(9)
        test    rcx, rcx
        jz      .c1
        call    WinHttpCloseHandle
.c1:    mov     rcx, loc(8)
        test    rcx, rcx
        jz      .c2
        call    WinHttpCloseHandle
.c2:    mov     rcx, loc(11)
        call    mem_free
        mov     rcx, loc(10)
        call    mem_free
        mov     rax, loc(7)
        EPROC

; Reads the Retry-After header of request loc(9) of the *calling* http_request frame (rbp-based) into *loc(6).
; Uses the caller's frame because it is only ever called from there.
http_read_retry_after:
        sub     rsp, 120                        ; keeps rsp 16-byte aligned at the call below
        mov     rcx, [rbp-72-8*9]
        mov     edx, WINHTTP_QUERY_CUSTOM
        lea     r8, [http_retry_hdr]
        lea     r9, [rsp+64]                    ; 32-byte wide scratch
        mov     dword [rsp+56], 32
        lea     rax, [rsp+56]
        mov     [rsp+32], rax
        mov     qword [rsp+40], 0
        mov     dword [rsp+64], 0
        call    WinHttpQueryHeaders
        test    eax, eax
        jz      .out
        lea     rcx, [rsp+64]
        xor     eax, eax
.d:     movzx   edx, word [rcx]
        sub     edx, '0'
        cmp     edx, 9
        ja      .set
        imul    eax, eax, 10
        add     eax, edx
        add     rcx, 2
        jmp     .d
.set:   mov     rcx, [rbp-72-8*6]
        mov     [rcx], eax
.out:   add     rsp, 120
        ret
