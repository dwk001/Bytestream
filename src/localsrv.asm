; localsrv.asm - ByteStream's tiny HTTP server on 127.0.0.1:<port>.
;
; It serves exactly three things, all to programs on this PC:
;   GET  /callback?code=..&state=..   OAuth redirect from Spotify (milestone: sign-in)
;   GET  /player, /player.js          the Web Playback SDK page that runs inside the hidden Edge window
;   *    /bridge/...                  that page talking to ByteStream (token, events up, commands down)
;
; Safety rules (every request is checked before routing):
;   * the Host header must be exactly "127.0.0.1:<port>" - this stops DNS-rebinding from a web page,
;   * /player and /bridge/* need the per-run secret in ?k=...  (constant-time compare),
;   * /callback needs the single-use "state" we generated for this sign-in,
;   * the socket is bound to 127.0.0.1 only, exclusively (no other program can share the port),
;   * no CORS headers are ever sent, responses are never cached, and only GET / POST are accepted.
;
; Threads: one acceptor thread; one short-lived thread per connection (a handful at most).  Connection threads
; never touch UI state: they post WM_AUTH_CB / WM_BRIDGE_EVENT to the window and the UI thread does the work.

extern WSAStartup, WSACleanup, socket, bind, listen, accept, recv, send, closesocket, htons, setsockopt
extern WSAGetLastError, getsockname

%define WM_BRIDGE_EVENT  (WM_APP + 2)
%define WM_AUTH_CB       (WM_APP + 3)

%define SRV_REQ_MAX      70000          ; request head + body must fit (events are small)
%define SRV_HEAD_MAX     16384          ; request line + headers
%define SRV_CMD_SLOTS    64

section .bss
                align 8
srv_wsa:        resb 408                ; WSADATA
srv_sock:       resq 1                  ; listening socket
srv_started:    resd 1
srv_bound_port: resd 1
srv_err:        resd 1                  ; WSAGetLastError() of the last failed start (10048 = port in use)
                align 8
srv_secret:     resb 40                 ; per-run secret for /player and /bridge/* (22 chars + NUL)
srv_cmd_q:      resq SRV_CMD_SLOTS      ; commands for the player page (heap UTF-8 JSON strings)
srv_cmd_head:   resd 1
srv_cmd_count:  resd 1
srv_cmd_lock:   resd 1
srv_cmd_event:  resq 1
srv_sse_gen:    resd 1                  ; newest event-stream connection wins
srv_one:        resd 1

section .data
ZSTR s_get, "GET"
ZSTR s_post, "POST"
ZSTR p_callback, "/callback"
ZSTR p_player, "/player"
ZSTR p_playerjs, "/player.js"
ZSTR p_btoken, "/bridge/token"
ZSTR p_bevent, "/bridge/event"
ZSTR p_bcmds, "/bridge/cmds"
ZSTR h_host, "Host"
ZSTR h_clen, "Content-Length"
ZSTR q_code, "code"
ZSTR q_state, "state"
ZSTR q_error, "error"
ZSTR q_k, "k"
ZSTR st_200, "200 OK"
ZSTR st_204, "204 No Content"
ZSTR st_400, "400 Bad Request"
ZSTR st_401, "401 Unauthorized"
ZSTR st_403, "403 Forbidden"
ZSTR st_404, "404 Not Found"
ZSTR st_405, "405 Method Not Allowed"
ZSTR st_413, "413 Payload Too Large"
ZSTR ct_html, "text/html; charset=utf-8"
ZSTR ct_js, "text/javascript; charset=utf-8"
ZSTR ct_json, "application/json"
ZSTR ct_text, "text/plain; charset=utf-8"
ZSTR r_h1, "HTTP/1.1 "
ZSTR r_h2, `\r\nContent-Type: `
ZSTR r_h3, `\r\nContent-Length: `
ZSTR r_h4, `\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n`
; Deliberately not a script/connect allow-list: the Spotify SDK loads its own frame, workers and DRM helpers from several
; Spotify hosts, and a too-strict policy would silently break playback.  These directives cannot affect loading.
ZSTR r_csp_page, `Content-Security-Policy: frame-ancestors 'none'; base-uri 'none'; form-action 'none'; object-src 'none'\r\n`
ZSTR r_csp_none, `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n`
ZSTR r_end, `\r\n`
ZSTR r_sse_head, `HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n: connected\n\n`
ZSTR r_sse_ping, `: ping\n\n`
ZSTR r_sse_data, "data: "
ZSTR r_sse_end, `\n\n`
ZSTR b_cb_ok, `<!doctype html><meta charset=utf-8><title>ByteStream</title><body style="font:16px system-ui;background:#121212;color:#fff;display:grid;place-items:center;height:100vh;margin:0"><div><h2>You're signed in</h2><p style="color:#b3b3b3">You can close this tab and go back to ByteStream.</p></div>`
ZSTR b_cb_err, `<!doctype html><meta charset=utf-8><title>ByteStream</title><body style="font:16px system-ui;background:#121212;color:#fff;display:grid;place-items:center;height:100vh;margin:0"><div><h2>Sign-in was not completed</h2><p style="color:#b3b3b3">Go back to ByteStream and try again.</p></div>`
ZSTR b_bad_state, "State mismatch: this sign-in response was ignored."
ZSTR b_forbidden, "Forbidden"
ZSTR b_notfound, "Not found"
ZSTR b_json_tok_pre, `{"token":"`
ZSTR b_json_tok_post, `"}`
ZSTR b_json_notok, `{"error":"signed out"}`
ZSTR l_srv_up, "server: listening on 127.0.0.1 port "
ZSTR l_srv_fail, "server: could not listen, WSA error "
ZSTR l_srv_reject, "server: rejected request: "
ZSTR l_rej_host, "wrong Host header"
ZSTR l_rej_secret, "missing or wrong secret"
ZSTR l_rej_state, "wrong sign-in state"

align 16
srv_html_start: incbin "../web/player.html"
srv_html_end:
srv_js_start:   incbin "../web/player.js"
srv_js_end:

section .text

; ---------------------------------------------------------------- start / restart
; Starts (or re-binds after a port change) the listener -> eax = 1 when listening; otherwise srv_err holds the reason.
PROC srv_start, 12
        mov     eax, [set_port]
        cmp     dword [srv_started], 0
        je      .fresh
        cmp     eax, [srv_bound_port]
        je      .ok                             ; already listening on the right port
        mov     rcx, [srv_sock]                 ; port changed: closing the socket ends the old acceptor
        call    closesocket
        mov     dword [srv_started], 0
        jmp     .bind
.fresh: lea     rcx, [srv_wsa]
        mov     edx, 0x0202
        xchg    rcx, rdx                        ; WSAStartup(version, &data)
        call    WSAStartup
        mov     rcx, [srv_cmd_event]
        test    rcx, rcx
        jnz     .have_evt
        xor     ecx, ecx
        xor     edx, edx
        xor     r8d, r8d
        xor     r9d, r9d
        call    CreateEventW
        mov     [srv_cmd_event], rax
.have_evt:
        lea     rcx, [auth_rnd]                 ; 16 random bytes -> 22-char secret
        mov     edx, 16
        call    rand_bytes
        lea     rcx, [auth_rnd]
        mov     edx, 16
        lea     r8, [srv_secret]
        call    b64url_enc
        lea     rcx, [srv_secret]
        mov     byte [rcx+rax], 0
.bind:  mov     ecx, 2                          ; AF_INET
        mov     edx, 1                          ; SOCK_STREAM
        mov     r8d, 6                          ; IPPROTO_TCP
        call    socket
        cmp     rax, -1
        je      .fail
        mov     loc(0), rax
        mov     dword [srv_one], 1
        mov     rcx, rax
        mov     edx, 0xFFFF                     ; SOL_SOCKET
        mov     r8d, 0xFFFFFFFB                 ; SO_EXCLUSIVEADDRUSE (= ~SO_REUSEADDR): nobody else may bind this port
        lea     r9, [srv_one]
        mov     qword outarg(5), 4
        call    setsockopt
        mov     ecx, [set_port]
        call    htons
        mov     word [rbp-72-8*2], 2            ; sockaddr_in at &loc(2): family, port, 127.0.0.1, 8 zero bytes
        mov     [rbp-72-8*2+2], ax
        mov     dword [rbp-72-8*2+4], 0x0100007F
        mov     qword loc(1), 0
        mov     rcx, loc(0)
        lea     rdx, loc(2)
        mov     r8d, 16
        call    bind
        test    eax, eax
        jnz     .fail_close
        mov     rcx, loc(0)
        mov     edx, 16
        call    listen
        test    eax, eax
        jnz     .fail_close
        mov     rax, loc(0)
        mov     [srv_sock], rax
        mov     eax, [set_port]
        mov     [srv_bound_port], eax
        mov     dword [srv_started], 1
        mov     dword [srv_err], 0
        xor     ecx, ecx
        xor     edx, edx
        lea     r8, [srv_accept_loop]
        mov     r9, loc(0)
        mov     qword outarg(5), 0
        mov     qword outarg(6), 0
        call    CreateThread
        mov     rcx, rax
        call    CloseHandle
        lea     rcx, [l_srv_up]
        mov     edx, [set_port]
        call    log_num
        cmp     dword [cli_no_shell], 0
        je      .ok
        BUFZERO 5                               ; test mode: announce the player URL (incl. the per-run secret)
        lea     rcx, loc(5)
        lea     rdx, [l_announce]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     edx, [set_port]
        call    buf_append_u64
        lea     rcx, loc(5)
        lea     rdx, [l_announce2]
        call    buf_append_z
        lea     rcx, loc(5)
        lea     rdx, [srv_secret]
        call    buf_append_z
        lea     rcx, loc(5)
        lea     rdx, [s_lf]
        call    buf_append_z
        mov     rcx, loc(5)
        call    out_z
        lea     rcx, loc(5)
        call    buf_free
.ok:    mov     eax, 1
        jmp     .out
.fail_close:
        call    WSAGetLastError
        mov     [srv_err], eax
        mov     rcx, loc(0)
        call    closesocket
        jmp     .logfail
.fail:  call    WSAGetLastError
        mov     [srv_err], eax
.logfail:
        lea     rcx, [l_srv_fail]
        mov     edx, [srv_err]
        call    log_num
        xor     eax, eax
.out:   EPROC

; thread: rcx = listening socket
PROC srv_accept_loop, 2
        mov     r12, rcx
.l:     mov     rcx, r12
        xor     edx, edx
        xor     r8d, r8d
        call    accept
        cmp     rax, -1
        je      .done                           ; the listener was closed
        mov     r13, rax
        xor     ecx, ecx
        xor     edx, edx
        lea     r8, [srv_conn]
        mov     r9, r13
        mov     qword outarg(5), 0
        mov     qword outarg(6), 0
        call    CreateThread
        test    rax, rax
        jz      .nothread
        mov     rcx, rax
        call    CloseHandle
        jmp     .l
.nothread:
        mov     rcx, r13
        call    closesocket
        jmp     .l
.done:  xor     eax, eax
        EPROC

; ---------------------------------------------------------------- small helpers
; rcx = socket, rdx = bytes, r8 = length: send everything
PROC srv_send_all, 3
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
.l:     test    qword loc(2), -1
        jz      .ok
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        mov     r8, loc(2)
        xor     r9d, r9d
        call    send
        test    eax, eax
        jle     .bad
        movsxd  rax, eax
        add     loc(1), rax
        sub     loc(2), rax
        jmp     .l
.ok:    mov     eax, 1
        jmp     .out
.bad:   xor     eax, eax
.out:   EPROC

; rcx = socket, rdx = status text, r8 = content type, r9 = body, [rbp+48] = body length, [rbp+56] = extra header lines or 0
PROC srv_reply, 8
        mov     loc(0), rcx
        mov     loc(1), r9
        mov     rax, stk5
        mov     loc(2), rax
        BUFZERO 5
        mov     loc(6), r8
        mov     loc(7), rdx
        lea     rcx, loc(5)
        lea     rdx, [r_h1]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     rdx, loc(7)
        call    buf_append_z
        lea     rcx, loc(5)
        lea     rdx, [r_h2]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     rdx, loc(6)
        call    buf_append_z
        lea     rcx, loc(5)
        lea     rdx, [r_h3]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     rdx, loc(2)
        call    buf_append_u64
        lea     rcx, loc(5)
        lea     rdx, [r_h4]
        call    buf_append_z
        mov     rdx, stk6
        test    rdx, rdx
        jz      .noextra
        lea     rcx, loc(5)
        call    buf_append_z
.noextra:
        lea     rcx, loc(5)
        lea     rdx, [r_end]
        call    buf_append_z
        mov     rcx, loc(0)
        mov     rdx, loc(5)
        mov     r8, loc(4)
        call    srv_send_all
        cmp     qword loc(2), 0
        je      .nobody
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        mov     r8, loc(2)
        call    srv_send_all
.nobody:
        lea     rcx, loc(5)
        call    buf_free
        EPROC

; rcx = socket, rdx = status text, r8 = short plain-text body
PROC srv_simple, 3
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     rcx, r8
        call    u8_len
        mov     outarg(5), rax                  ; body length
        mov     qword outarg(6), 0              ; no extra headers
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        lea     r8, [ct_text]
        mov     r9, loc(2)
        call    srv_reply
        EPROC

; rcx = a, rdx = b, r8 = n -> eax = 1 when equal; takes the same time wherever the first difference is
ct_equal:
        xor     eax, eax
        test    r8, r8
        jz      .done
.l:     mov     r9b, [rcx]
        xor     r9b, [rdx]
        or      al, r9b
        inc     rcx
        inc     rdx
        dec     r8
        jnz     .l
.done:  test    al, al
        sete    al
        movzx   eax, al
        ret

; rcx = line start, rdx = NUL-terminated header name -> eax = 1 when the line starts with "name:" (any letter case)
hdr_line_is:
.l:     mov     al, [rdx]
        test    al, al
        jz      .colon
        mov     r8b, [rcx]
        cmp     al, 'A'
        jb      .a
        cmp     al, 'Z'
        ja      .a
        add     al, 32
.a:     cmp     r8b, 'A'
        jb      .b
        cmp     r8b, 'Z'
        ja      .b
        add     r8b, 32
.b:     cmp     al, r8b
        jne     .no
        inc     rcx
        inc     rdx
        jmp     .l
.colon: cmp     byte [rcx], ':'
        jne     .no
        mov     eax, 1
        ret
.no:    xor     eax, eax
        ret

; rcx = first header line, rdx = name, r8 = out buffer, r9 = capacity -> eax = value length, -1 when absent
PROC req_header, 4
        mov     rsi, rcx
        mov     loc(0), rdx
        mov     loc(1), r8
        mov     loc(2), r9
.line:  mov     al, [rsi]
        test    al, al
        jz      .none
        cmp     al, 13
        je      .none                           ; blank line: end of headers
        mov     rcx, rsi
        mov     rdx, loc(0)
        call    hdr_line_is
        test    eax, eax
        jnz     .found
.nl:    mov     al, [rsi]                       ; skip to the next line
        test    al, al
        jz      .none
        inc     rsi
        cmp     al, 10
        jne     .nl
        jmp     .line
.found: mov     rcx, rsi
.c1:    cmp     byte [rcx], ':'
        je      .c2
        inc     rcx
        jmp     .c1
.c2:    inc     rcx
.sp:    cmp     byte [rcx], ' '
        jne     .copy
        inc     rcx
        jmp     .sp
.copy:  mov     rdi, loc(1)
        xor     edx, edx
        mov     r8, loc(2)
        dec     r8
.cp:    mov     al, [rcx+rdx]
        test    al, al
        jz      .end
        cmp     al, 13
        je      .end
        cmp     rdx, r8
        jae     .end
        mov     [rdi+rdx], al
        inc     rdx
        jmp     .cp
.end:   mov     byte [rdi+rdx], 0
        mov     eax, edx
        jmp     .out
.none:  mov     eax, -1
.out:   EPROC

hexval:                                         ; al = hex digit -> eax = 0..15, -1 when not a digit
        cmp     al, '0'
        jb      .no
        cmp     al, '9'
        jbe     .d
        or      al, 0x20
        cmp     al, 'a'
        jb      .no
        cmp     al, 'f'
        ja      .no
        sub     al, 'a' - 10
        movzx   eax, al
        ret
.d:     sub     al, '0'
        movzx   eax, al
        ret
.no:    mov     eax, -1
        ret

; rcx = request target ("/path?a=b&c=d"), rdx = parameter name, r8 = out, r9 = capacity
; -> eax = length of the percent-decoded value, -1 when the parameter is absent
PROC qget, 5
        mov     loc(0), rdx
        mov     loc(1), r8
        mov     loc(2), r9
.q:     mov     al, [rcx]
        test    al, al
        jz      .none
        inc     rcx
        cmp     al, '?'
        jne     .q
.pair:  mov     rsi, rcx                        ; key start
        mov     rdi, loc(0)
.key:   mov     al, [rsi]
        cmp     al, '='
        je      .keyend
        cmp     al, '&'
        je      .keyend
        test    al, al
        jz      .keyend
        cmp     al, [rdi]
        jne     .skip
        inc     rsi
        inc     rdi
        jmp     .key
.keyend: cmp    byte [rdi], 0                   ; whole name matched?
        jne     .skip
        cmp     byte [rsi], '='
        jne     .empty
        inc     rsi                             ; value start
        mov     rdi, loc(1)
        xor     r10d, r10d
        mov     r11, loc(2)
        dec     r11
.val:   mov     al, [rsi]
        test    al, al
        jz      .vend
        cmp     al, '&'
        je      .vend
        inc     rsi
        cmp     al, '+'
        jne     .pct
        mov     al, ' '
        jmp     .put
.pct:   cmp     al, '%'
        jne     .put
        movzx   eax, byte [rsi]
        call    hexval
        cmp     eax, 0
        jl      .lit
        mov     r8d, eax
        movzx   eax, byte [rsi+1]
        call    hexval
        cmp     eax, 0
        jl      .lit
        shl     r8d, 4
        or      eax, r8d
        add     rsi, 2
        jmp     .put
.lit:   mov     al, '%'
.put:   cmp     r10, r11
        jae     .val                            ; value longer than the buffer: truncate
        mov     [rdi+r10], al
        inc     r10
        jmp     .val
.vend:  mov     byte [rdi+r10], 0
        mov     eax, r10d
        jmp     .out
.empty: mov     rdi, loc(1)
        mov     byte [rdi], 0
        xor     eax, eax
        jmp     .out
.skip:  mov     al, [rsi]                       ; advance to the next pair
        test    al, al
        jz      .none
        inc     rsi
        cmp     al, '&'
        jne     .skip
        mov     rcx, rsi
        jmp     .pair
.none:  mov     eax, -1
.out:   EPROC

; rcx = target, rdx = path (NUL-terminated) -> eax = 1 when the target is exactly that path (query string allowed)
path_is:
.l:     mov     al, [rdx]
        test    al, al
        jz      .end
        cmp     al, [rcx]
        jne     .no
        inc     rcx
        inc     rdx
        jmp     .l
.end:   mov     al, [rcx]
        test    al, al
        jz      .yes
        cmp     al, '?'
        je      .yes
.no:    xor     eax, eax
        ret
.yes:   mov     eax, 1
        ret

; rcx = target, rdx = 64-byte scratch -> eax = 1 when ?k= carries this run's secret
PROC srv_check_secret, 1
        mov     loc(0), rdx
        lea     rdx, [q_k]
        mov     r8, loc(0)
        mov     r9d, 64
        call    qget
        cmp     eax, 22
        jne     .no
        mov     rcx, loc(0)
        lea     rdx, [srv_secret]
        mov     r8d, 22
        call    ct_equal
        jmp     .out
.no:    xor     eax, eax
.out:   EPROC

; rcx = text (any bytes), rdx = length -> heap copy, NUL-terminated
PROC srv_dup_n, 2
        mov     loc(0), rcx
        mov     loc(1), rdx
        lea     rcx, [rdx+1]
        call    mem_alloc
        push    rax
        sub     rsp, 8
        mov     rcx, rax
        mov     rdx, loc(0)
        mov     r8, loc(1)
        call    mem_copy
        add     rsp, 8
        pop     rax
        EPROC

; ---------------------------------------------------------------- commands for the player page
; rcx = JSON command (UTF-8): copied and queued; wakes the event-stream connection
PROC srv_cmd_push, 1
        call    u8_dup
        mov     loc(0), rax
        lea     rcx, [srv_cmd_lock]
        call    lock_acquire
        cmp     dword [srv_cmd_count], SRV_CMD_SLOTS
        jb      .room
        lea     rcx, [srv_cmd_q]                ; full: drop the oldest
        mov     eax, [srv_cmd_head]
        mov     rcx, [rcx+rax*8]
        call    mem_free
        inc     dword [srv_cmd_head]
        and     dword [srv_cmd_head], SRV_CMD_SLOTS - 1
        dec     dword [srv_cmd_count]
.room:  mov     eax, [srv_cmd_head]
        add     eax, [srv_cmd_count]
        and     eax, SRV_CMD_SLOTS - 1
        lea     rcx, [srv_cmd_q]
        mov     rdx, loc(0)
        mov     [rcx+rax*8], rdx
        inc     dword [srv_cmd_count]
        lea     rcx, [srv_cmd_lock]
        call    lock_release
        mov     rcx, [srv_cmd_event]
        test    rcx, rcx
        jz      .out
        call    SetEvent
.out:   EPROC

; -> rax = next queued command (heap string, caller frees) or 0
PROC srv_cmd_pop, 0
        lea     rcx, [srv_cmd_lock]
        call    lock_acquire
        xor     ebx, ebx
        cmp     dword [srv_cmd_count], 0
        je      .none
        mov     eax, [srv_cmd_head]
        lea     rcx, [srv_cmd_q]
        mov     rbx, [rcx+rax*8]
        inc     dword [srv_cmd_head]
        and     dword [srv_cmd_head], SRV_CMD_SLOTS - 1
        dec     dword [srv_cmd_count]
.none:  lea     rcx, [srv_cmd_lock]
        call    lock_release
        mov     rax, rbx
        EPROC

; ---------------------------------------------------------------- one connection (its own thread)
; rcx = client socket.   Locals: 0 socket, 1 request buffer, 2 bytes received, 3 header length, 4 target,
; 5 method, 6 content length, 7 scratch (host / k / state / code values), 8 header start, 9 gen
PROC srv_conn, 12
        mov     loc(0), rcx
        mov     rcx, rcx
        mov     edx, 0xFFFF                     ; SOL_SOCKET
        mov     r8d, 0x1006                     ; SO_RCVTIMEO
        lea     r9, [srv_rcv_timeout]
        mov     qword outarg(5), 4
        call    setsockopt
        mov     rcx, loc(0)
        mov     edx, 0xFFFF
        mov     r8d, 0x1006
        lea     r9, [srv_rcv_timeout]
        mov     qword outarg(5), 4
        call    setsockopt
        mov     ecx, SRV_REQ_MAX + 1
        call    mem_alloc
        mov     loc(1), rax
        mov     ecx, 1024
        call    mem_alloc
        mov     loc(7), rax
        mov     qword loc(2), 0
        mov     qword loc(3), 0
        mov     qword loc(6), 0
.recv:  mov     rax, loc(2)
        cmp     rax, SRV_REQ_MAX
        jae     .toolarge
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        add     rdx, rax
        mov     r8d, SRV_REQ_MAX
        sub     r8d, eax
        xor     r9d, r9d
        call    recv
        test    eax, eax
        jle     .drop
        movsxd  rax, eax
        add     loc(2), rax
        mov     rcx, loc(1)
        mov     rax, loc(2)
        mov     byte [rcx+rax], 0
        cmp     qword loc(3), 0
        jne     .havehead
        ; look for the end of the header block
        mov     rsi, loc(1)
        xor     ecx, ecx
        mov     rdx, loc(2)
        sub     rdx, 3
        jle     .more
.find:  cmp     rcx, rdx
        jae     .nofind
        cmp     dword [rsi+rcx], 0x0A0D0A0D     ; \r\n\r\n
        je      .gotend
        inc     rcx
        jmp     .find
.gotend: lea    rax, [rcx+4]
        mov     loc(3), rax
        cmp     rax, SRV_HEAD_MAX
        ja      .toolarge                       ; the head itself is too big, even if it arrived in one piece
        jmp     .parse
.nofind: cmp    qword loc(2), SRV_HEAD_MAX
        ja      .toolarge
.more:  jmp     .recv
.parse: mov     rsi, loc(1)
        mov     loc(5), rsi                     ; method
.sp1:   mov     al, [rsi]
        test    al, al
        jz      .badreq
        cmp     al, ' '
        je      .sp1d
        inc     rsi
        jmp     .sp1
.sp1d:  mov     byte [rsi], 0
        inc     rsi
        mov     loc(4), rsi                     ; target
.sp2:   mov     al, [rsi]
        test    al, al
        jz      .badreq
        cmp     al, ' '
        je      .sp2d
        cmp     al, 13
        je      .sp2d
        inc     rsi
        jmp     .sp2
.sp2d:  mov     byte [rsi], 0
        inc     rsi                             ; step past the terminator we just wrote
.nl:    mov     al, [rsi]                       ; header lines start after the first newline
        test    al, al
        jz      .badreq
        inc     rsi
        cmp     al, 10
        jne     .nl
        mov     loc(8), rsi
        ; ---- Host must be exactly 127.0.0.1:<port>
        mov     rcx, loc(8)
        lea     rdx, [h_host]
        mov     r8, loc(7)
        mov     r9d, 64
        call    req_header
        test    eax, eax
        js      .rej_host
        mov     rcx, loc(7)
        add     rcx, 900                        ; expected value built at scratch+900
        lea     rdx, [s_host_pre]
        call    lstrcpyA_z
        mov     rcx, loc(7)
        add     rcx, 910
        mov     edx, [srv_bound_port]
        call    u8_put_u64
        mov     byte [rax], 0
        mov     rcx, loc(7)
        mov     rdx, loc(7)
        add     rdx, 900
        call    u8_eq
        test    eax, eax
        jz      .rej_host
        ; ---- Content-Length (POST bodies)
        mov     rcx, loc(8)
        lea     rdx, [h_clen]
        mov     r8, loc(7)
        add     r8, 64
        mov     r9d, 32
        call    req_header
        test    eax, eax
        js      .noclen
        mov     rcx, loc(7)
        add     rcx, 64
        call    json_int
        mov     loc(6), rax
.noclen: mov    rax, loc(6)
        cmp     rax, SRV_REQ_MAX - 1024
        ja      .toolarge
        add     rax, loc(3)
        cmp     rax, loc(2)
        jbe     .complete
        jmp     .recv                           ; body still arriving
.havehead:
        mov     rax, loc(6)
        add     rax, loc(3)
        cmp     rax, loc(2)
        ja      .recv
.complete:
        ; ---- method: GET or POST only
        mov     rcx, loc(5)
        lea     rdx, [s_get]
        call    u8_eq
        mov     r12d, eax                       ; 1 = GET
        mov     rcx, loc(5)
        lea     rdx, [s_post]
        call    u8_eq
        mov     r13d, eax                       ; 1 = POST
        or      eax, r12d
        jz      .notallowed
        ; ---- routes
        mov     rcx, loc(4)
        lea     rdx, [p_callback]
        call    path_is
        test    eax, eax
        jnz     .callback
        mov     rcx, loc(4)
        lea     rdx, [p_player]
        call    path_is
        test    eax, eax
        jnz     .page_html
        mov     rcx, loc(4)
        lea     rdx, [p_playerjs]
        call    path_is
        test    eax, eax
        jnz     .page_js
        mov     rcx, loc(4)
        lea     rdx, [p_btoken]
        call    path_is
        test    eax, eax
        jnz     .btoken
        mov     rcx, loc(4)
        lea     rdx, [p_bevent]
        call    path_is
        test    eax, eax
        jnz     .bevent
        mov     rcx, loc(4)
        lea     rdx, [p_bcmds]
        call    path_is
        test    eax, eax
        jnz     .bcmds
        jmp     .notfound

        ; ---- OAuth redirect
.callback:
        test    r12d, r12d
        jz      .notallowed
        mov     rcx, loc(4)
        lea     rdx, [q_state]
        mov     r8, loc(7)
        add     r8, 160
        mov     r9d, 64
        call    qget
        cmp     eax, 22
        jne     .rej_state
        lea     rcx, [auth_lock]                ; compare AND consume under the lock: a state is single-use even
        call    lock_acquire                    ; when two requests race each other
        cmp     byte [auth_expect], 0
        je      .state_bad
        mov     rcx, loc(7)
        add     rcx, 160
        lea     rdx, [auth_expect]
        mov     r8d, 22
        call    ct_equal
        test    eax, eax
        jz      .state_bad
        mov     byte [auth_expect], 0
        lea     rcx, [auth_lock]
        call    lock_release
        jmp     .state_ok
.state_bad:
        lea     rcx, [auth_lock]
        call    lock_release
        jmp     .rej_state
.state_ok:
        mov     rcx, loc(4)
        lea     rdx, [q_error]
        mov     r8, loc(7)
        add     r8, 224
        mov     r9d, 700
        call    qget
        test    eax, eax
        js      .nocberr
        mov     rcx, loc(7)
        add     rcx, 224
        call    u8_dup
        mov     r8, rax
        mov     r9d, 1                          ; kind 1: error
        jmp     .postcb
.nocberr:
        mov     rcx, loc(4)
        lea     rdx, [q_code]
        mov     r8, loc(7)
        add     r8, 224
        mov     r9d, 700
        call    qget
        test    eax, eax
        jle     .badreq
        mov     rcx, loc(7)
        add     rcx, 224
        call    u8_dup
        mov     r8, rax
        xor     r9d, r9d                        ; kind 0: authorization code
.postcb:
        mov     r14, r9
        mov     r15, r8
        mov     rcx, [hwnd]
        mov     edx, WM_AUTH_CB
        mov     r8, r15
        mov     r9, r14
        call    PostMessageW
        lea     r8, [b_cb_ok]
        test    r14, r14
        jz      .cbreply
        lea     r8, [b_cb_err]
.cbreply:
        mov     r15, r8
        mov     rcx, r8
        call    u8_len
        mov     outarg(5), rax
        lea     rax, [r_csp_none]
        mov     outarg(6), rax
        mov     rcx, loc(0)
        lea     rdx, [st_200]
        lea     r8, [ct_html]
        mov     r9, r15
        call    srv_reply
        jmp     .drop

        ; ---- player page and script (secret required)
.page_html:
        test    r12d, r12d
        jz      .notallowed
        mov     rcx, loc(4)
        mov     rdx, loc(7)
        add     rdx, 96
        call    srv_check_secret
        test    eax, eax
        jz      .rej_secret
        lea     rax, [srv_html_end]
        lea     rcx, [srv_html_start]
        sub     rax, rcx
        mov     outarg(5), rax
        lea     rax, [r_csp_page]
        mov     outarg(6), rax
        mov     rcx, loc(0)
        lea     rdx, [st_200]
        lea     r8, [ct_html]
        lea     r9, [srv_html_start]
        call    srv_reply
        jmp     .drop
.page_js:
        test    r12d, r12d
        jz      .notallowed                     ; (no secret needed: the script is public source and holds no secrets)
        lea     rax, [srv_js_end]
        lea     rcx, [srv_js_start]
        sub     rax, rcx
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        mov     rcx, loc(0)
        lea     rdx, [st_200]
        lea     r8, [ct_js]
        lea     r9, [srv_js_start]
        call    srv_reply
        jmp     .drop

        ; ---- bridge: current access token
.btoken:
        test    r12d, r12d
        jz      .notallowed
        mov     rcx, loc(4)
        mov     rdx, loc(7)
        add     rdx, 96
        call    srv_check_secret
        test    eax, eax
        jz      .rej_secret
        call    auth_ensure_fresh               ; the SDK may ask long after the last API call: never hand out an expired token
        BUFZERO 11
        lea     rcx, [tok_lock]
        call    lock_acquire
        cmp     byte [tok_access], 0
        je      .notok
        lea     rcx, loc(11)
        lea     rdx, [b_json_tok_pre]
        call    buf_append_z
        lea     rcx, loc(11)
        lea     rdx, [tok_access]
        call    buf_append_z
        lea     rcx, loc(11)
        lea     rdx, [b_json_tok_post]
        call    buf_append_z
        lea     rcx, [tok_lock]
        call    lock_release
        mov     rax, loc(10)
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        mov     rcx, loc(0)
        lea     rdx, [st_200]
        lea     r8, [ct_json]
        mov     r9, loc(11)
        call    srv_reply
        lea     rcx, loc(11)
        call    buf_free
        jmp     .drop
.notok: lea     rcx, [tok_lock]
        call    lock_release
        lea     r8, [b_json_notok]
        mov     rcx, loc(0)
        lea     rdx, [st_401]
        call    srv_simple
        jmp     .drop

        ; ---- bridge: an event from the page (POST, body = JSON)
.bevent:
        test    r13d, r13d
        jz      .notallowed
        mov     rcx, loc(4)
        mov     rdx, loc(7)
        add     rdx, 96
        call    srv_check_secret
        test    eax, eax
        jz      .rej_secret
        mov     rcx, loc(1)
        add     rcx, loc(3)
        mov     rdx, loc(6)
        call    srv_dup_n
        mov     r8, rax
        mov     rcx, [hwnd]
        mov     edx, WM_BRIDGE_EVENT
        mov     r9, loc(6)
        call    PostMessageW
        mov     qword outarg(5), 0
        mov     qword outarg(6), 0
        mov     rcx, loc(0)
        lea     rdx, [st_204]
        lea     r8, [ct_text]
        xor     r9d, r9d
        call    srv_reply
        jmp     .drop

        ; ---- bridge: server-sent events carrying commands for the page
.bcmds:
        test    r12d, r12d
        jz      .notallowed
        mov     rcx, loc(4)
        mov     rdx, loc(7)
        add     rdx, 96
        call    srv_check_secret
        test    eax, eax
        jz      .rej_secret
        lea     rcx, [srv_cmd_lock]
        call    lock_acquire
        inc     dword [srv_sse_gen]
        mov     eax, [srv_sse_gen]
        mov     loc(9), rax
        lea     rcx, [srv_cmd_lock]
        call    lock_release
        lea     rcx, [r_sse_head]
        call    u8_len
        mov     r8, rax
        mov     rcx, loc(0)
        lea     rdx, [r_sse_head]
        call    srv_send_all
        test    eax, eax
        jz      .drop
.sse:   mov     eax, [srv_sse_gen]
        cmp     rax, loc(9)
        jne     .drop                           ; a newer page took over
        call    srv_cmd_pop
        test    rax, rax
        jz      .wait
        mov     r14, rax
        mov     rcx, loc(0)
        lea     rdx, [r_sse_data]
        mov     r8d, 6
        call    srv_send_all
        mov     r15d, eax
        mov     rcx, r14
        call    u8_len
        mov     r8, rax
        mov     rcx, loc(0)
        mov     rdx, r14
        call    srv_send_all
        and     r15d, eax
        mov     rcx, loc(0)
        lea     rdx, [r_sse_end]
        mov     r8d, 2
        call    srv_send_all
        and     r15d, eax
        mov     rcx, r14
        call    mem_free
        test    r15d, r15d
        jz      .drop
        jmp     .sse
.wait:  mov     rcx, [srv_cmd_event]
        mov     edx, 15000
        call    WaitForSingleObject
        cmp     eax, 0x102                      ; WAIT_TIMEOUT: keep the stream alive
        jne     .sse
        mov     rcx, loc(0)
        lea     rdx, [r_sse_ping]
        mov     r8d, 9
        call    srv_send_all
        test    eax, eax
        jnz     .sse
        jmp     .drop

        ; ---- rejections (logged, never detailed to the caller)
.rej_host:
        lea     rax, [l_rej_host]
        jmp     .rej
.rej_secret:
        lea     rax, [l_rej_secret]
        jmp     .rej
.rej_state:
        lea     rax, [l_rej_state]
.rej:   mov     rbx, rax
        BUFZERO 11
        lea     rcx, loc(11)
        lea     rdx, [l_srv_reject]
        call    buf_append_z
        lea     rcx, loc(11)
        mov     rdx, rbx
        call    buf_append_z
        mov     rcx, loc(11)
        call    log_msg
        lea     rcx, loc(11)
        call    buf_free
        mov     rcx, loc(0)
        lea     rdx, [st_403]
        lea     r8, [b_forbidden]
        call    srv_simple
        jmp     .drop
.notallowed:
        mov     rcx, loc(0)
        lea     rdx, [st_405]
        lea     r8, [b_forbidden]
        call    srv_simple
        jmp     .drop
.notfound:
        mov     rcx, loc(0)
        lea     rdx, [st_404]
        lea     r8, [b_notfound]
        call    srv_simple
        jmp     .drop
.badreq:
        mov     rcx, loc(0)
        lea     rdx, [st_400]
        lea     r8, [b_bad_state]
        call    srv_simple
        jmp     .drop
.toolarge:
        mov     rcx, loc(0)
        lea     rdx, [st_413]
        lea     r8, [b_forbidden]
        call    srv_simple
.drop:  mov     rcx, loc(0)
        call    closesocket
        mov     rcx, loc(1)
        call    mem_free
        mov     rcx, loc(7)
        call    mem_free
        xor     eax, eax
        EPROC

; rcx = destination, rdx = source: copies a NUL-terminated string including the NUL
lstrcpyA_z:
.l:     mov     al, [rdx]
        mov     [rcx], al
        inc     rcx
        inc     rdx
        test    al, al
        jnz     .l
        ret

section .data
align 4
srv_rcv_timeout: dd 10000
ZSTR s_host_pre, "127.0.0.1:"
ZSTR l_announce, "player-url:http://127.0.0.1:"
ZSTR l_announce2, "/player?k="
section .text
