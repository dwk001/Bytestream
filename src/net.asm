; net.asm - background request queue.
;
; The UI thread submits jobs; two worker threads (0 = API, 1 = images) run them with http_request and post
; the finished job back to the window as WM_APP+1.  All parsing and state changes happen on the UI thread in
; the handler registered for the job's tag, so UI data structures never need locks.
;
; One API worker keeps API calls strictly ordered (a "like" followed by a "contains" is seen in that order).

extern CreateThread, CreateEventW, SetEvent, WaitForSingleObject, Sleep, PostMessageW
extern PeekMessageW, GetTickCount64

%define JB_NEXT    0
%define JB_KIND    8                    ; queue index: 0 api, 1..3 images (three download workers), 4 audio helper
%define JB_TAG     16
%define JB_ARG     24
%define JB_METHOD  32                   ; static UTF-16 verb
%define JB_URL     40                   ; owned UTF-8
%define JB_BODY    48                   ; owned UTF-8 or 0
%define JB_BLEN    56
%define JB_HDRS    64                   ; owned UTF-8 "Name: value\r\n" block or 0
%define JB_STATUS  72
%define JB_RESP    80                   ; Buf {ptr, len, cap}
%define JB_FLAGS   104
%define JB_RETRY   108
%define JB_SEQ     112
%define JB_PIX     120                  ; decoded cover {w, h, BGRA} made on the worker thread (0 = none)
%define JB_SIZE    128

%define JF_NOAUTH  1                    ; do not add the Authorization header (token endpoint, CDN images)
%define JF_JSON    2                    ; Content-Type: application/json
%define JF_FORM    4                    ; Content-Type: application/x-www-form-urlencoded

%define WM_NET_DONE  (WM_APP + 1)

%define TAG_NONE   0
%define TAG_DEBUG  1
%define TAG_TOKEN  2                    ; OAuth token endpoint answered (arg 0 = code exchange, 1 = session restore)
%define TAG_ME     3                    ; GET /v1/me answered: sign-in complete
%define TAG_PLAY   4                    ; PUT /me/player/play answered
%define TAG_LIST   5                    ; a page of the library (arg = generation << 8 | source)
%define TAG_DETAIL 6                    ; tracks of the open playlist / album (arg = generation)
%define TAG_SEARCH 7                    ; search results (arg = generation)
%define TAG_IMG    8                    ; a cover image (the job URL is the cache key)
%define TAG_CONTAINS 9                  ; GET /me/library/contains answered (arg = block of hashes)
%define TAG_SAVE   10                   ; PUT / DELETE /me/library answered
%define TAG_QUEUE  11                   ; GET /me/player/queue answered
%define TAG_QADD   12                   ; POST /me/player/queue answered
%define TAG_PLMOD  13                   ; a playlist change answered (arg = block [gen][kind][id])
%define TAG_HPSTAT 14                   ; the audio helper answered GET /status (engine.asm)
%define TAG_HPAUTH 15                   ; the audio helper answered GET /auth/code
%define TAG_COUNT  16                   ; grows as handlers are added
%define NQ_COUNT   5                    ; 0 api, 1..3 covers, 4 the local audio helper
%define NQ_IMAGES  3
%define NQ_LOCAL   4                    ; own thread: a slow Spotify call (429 back-off) never delays pause or seek

section .bss
nq_head:        resq NQ_COUNT
nq_tail:        resq NQ_COUNT
nq_event:       resq NQ_COUNT
nq_lock:        resd 1
net_pending:    resd 1
net_started:    resd 1
net_api_base:   resq 1                  ; owned UTF-8, no trailing slash
net_auth_base:  resq 1
tok_lock:       resd 1
                align 8
tok_access:     resb 640                ; UTF-8 access token (NUL-terminated)
dbg_results:    resd 32                 ; 8 entries x {status, hash of body}
dbg_count:      resd 1
                align 8
dbg_body:       resb 256                ; first bytes of the most recent debug body

section .data
ZSTR h_auth_pre, "Authorization: Bearer "
ZSTR h_crlf, `\r\n`
ZSTR h_json, `Content-Type: application/json\r\n`
ZSTR h_form, `Content-Type: application/x-www-form-urlencoded\r\n`
ZSTR def_api_base, "https://api.spotify.com"
ZSTR def_auth_base, "https://accounts.spotify.com"
align 8
net_handlers:
        dq 0
        dq h_debug
        dq h_token
        dq h_me
        dq h_play
        dq h_list
        dq h_detail
        dq h_search
        dq h_img
        dq h_contains
        dq h_save
        dq h_queue
        dq h_qadd
        dq h_plmod
        dq h_hpstat
        dq h_hpauth

section .text

; ---------------------------------------------------------------- tiny spin lock (held for a few instructions only)
; rcx = lock dword*
lock_acquire:
        mov     eax, 1
.l:     xchg    [rcx], eax
        test    eax, eax
        jz      .got
        pause
        mov     eax, 1
        jmp     .l
.got:   ret

lock_release:
        mov     dword [rcx], 0
        ret

; ---------------------------------------------------------------- setup
; rcx = api base (UTF-8) or 0, rdx = accounts base (UTF-8) or 0.  Strings are copied.
PROC net_init, 2
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     rcx, loc(0)
        test    rcx, rcx
        jnz     .a
        lea     rcx, [def_api_base]
.a:     call    u8_dup
        mov     [net_api_base], rax
        mov     rcx, loc(1)
        test    rcx, rcx
        jnz     .b
        lea     rcx, [def_auth_base]
.b:     call    u8_dup
        mov     [net_auth_base], rax
        cmp     dword [net_started], 0
        jne     .out
        mov     dword [net_started], 1
        xor     ebx, ebx
.mk:    xor     ecx, ecx
        xor     edx, edx                        ; auto-reset
        xor     r8d, r8d                        ; initially non-signalled
        xor     r9d, r9d
        call    CreateEventW
        lea     rcx, [nq_event]
        mov     [rcx+rbx*8], rax
        xor     ecx, ecx
        xor     edx, edx
        lea     r8, [net_worker]
        mov     r9d, ebx                        ; thread parameter = kind
        mov     qword outarg(5), 0
        mov     qword outarg(6), 0
        call    CreateThread
        inc     ebx
        cmp     ebx, NQ_COUNT
        jb      .mk
.out:   EPROC

; rcx = access token (UTF-8, copied) or 0 to clear
net_set_token:
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 32
        mov     rsi, rcx
        lea     rcx, [tok_lock]
        call    lock_acquire
        lea     rdi, [tok_access]
        xor     ecx, ecx                        ; index 0 (also the clear-token case, which skips the copy)
        test    rsi, rsi
        jz      .term
.c:     cmp     ecx, 638
        jae     .term
        mov     al, [rsi+rcx]
        test    al, al
        jz      .term
        mov     [rdi+rcx], al
        inc     ecx
        jmp     .c
.term:  mov     byte [rdi+rcx], 0
        lea     rcx, [tok_lock]
        call    lock_release
        add     rsp, 32
        pop     rdi
        pop     rsi
        pop     rbx
        ret

; rcx = Buf* (reset first), rdx = path (UTF-8, starts with '/')  ->  "<api base><path>"
PROC api_url, 1
        mov     loc(0), rdx
        mov     rbx, rcx
        call    buf_reset
        mov     rcx, rbx
        mov     rdx, [net_api_base]
        call    buf_append_z
        mov     rcx, rbx
        mov     rdx, loc(0)
        call    buf_append_z
        EPROC

PROC auth_url, 1
        mov     loc(0), rdx
        mov     rbx, rcx
        call    buf_reset
        mov     rcx, rbx
        mov     rdx, [net_auth_base]
        call    buf_append_z
        mov     rcx, rbx
        mov     rdx, loc(0)
        call    buf_append_z
        EPROC

; ---------------------------------------------------------------- submit (UI thread)
; rcx = kind, rdx = tag, r8 = arg, r9 = method (static UTF-16 verb),
; [rbp+48] = URL (UTF-8, copied), [rbp+56] = body (UTF-8, copied) or 0, [rbp+64] = flags, [rbp+72] = extra headers or 0
; -> rax = job
PROC net_submit, 6
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        mov     ecx, JB_SIZE
        call    mem_alloc
        mov     rbx, rax
        mov     rax, loc(0)
        mov     [rbx+JB_KIND], rax
        mov     rax, loc(1)
        mov     [rbx+JB_TAG], rax
        mov     rax, loc(2)
        mov     [rbx+JB_ARG], rax
        mov     rax, loc(3)
        mov     [rbx+JB_METHOD], rax
        mov     rcx, stk5
        call    u8_dup
        mov     [rbx+JB_URL], rax
        mov     rcx, stk6
        test    rcx, rcx
        jz      .nb
        mov     loc(4), rcx
        call    u8_len
        mov     [rbx+JB_BLEN], rax
        mov     rcx, loc(4)
        call    u8_dup
        mov     [rbx+JB_BODY], rax
.nb:    mov     eax, stk7
        mov     [rbx+JB_FLAGS], eax
        mov     rcx, stk8
        test    rcx, rcx
        jz      .nh
        call    u8_dup
        mov     [rbx+JB_HDRS], rax
.nh:    lock inc dword [net_pending]
        lea     rcx, [nq_lock]
        call    lock_acquire
        mov     rax, [rbx+JB_KIND]
        lea     rcx, [nq_tail]
        mov     rdx, [rcx+rax*8]
        test    rdx, rdx
        jz      .first
        mov     [rdx+JB_NEXT], rbx
        jmp     .link
.first: lea     rcx, [nq_head]
        mov     [rcx+rax*8], rbx
.link:  lea     rcx, [nq_tail]
        mov     [rcx+rax*8], rbx
        lea     rcx, [nq_lock]
        call    lock_release
        mov     rax, [rbx+JB_KIND]
        lea     rcx, [nq_event]
        mov     rcx, [rcx+rax*8]
        call    SetEvent
        mov     rax, rbx
        EPROC

; ---------------------------------------------------------------- worker thread
; rcx = kind
PROC net_worker, 2
        mov     r12, rcx
.pop:   lea     rcx, [nq_lock]
        call    lock_acquire
        lea     rax, [nq_head]
        mov     rbx, [rax+r12*8]
        test    rbx, rbx
        jz      .empty
        mov     rdx, [rbx+JB_NEXT]
        mov     [rax+r12*8], rdx
        test    rdx, rdx
        jnz     .got
        lea     rax, [nq_tail]
        mov     qword [rax+r12*8], 0
.got:   lea     rcx, [nq_lock]
        call    lock_release
        mov     rcx, rbx
        call    net_run_job
        cmp     qword [rbx+JB_TAG], TAG_IMG     ; covers are decoded here, off the UI thread
        jne     .post
        cmp     dword [rbx+JB_STATUS], 200
        jne     .post
        mov     rcx, [rbx+JB_RESP+BUF_PTR]
        test    rcx, rcx
        jz      .post
        mov     rdx, [rbx+JB_RESP+BUF_LEN]
        call    img_decode_pixels
        mov     [rbx+JB_PIX], rax
.post:  mov     rcx, [hwnd]
        mov     edx, WM_NET_DONE
        mov     r8, rbx
        xor     r9d, r9d
        call    PostMessageW
        jmp     .pop
.empty: lea     rcx, [nq_lock]
        call    lock_release
        lea     rax, [nq_event]
        mov     rcx, [rax+r12*8]
        mov     edx, -1
        call    WaitForSingleObject
        jmp     .pop
        EPROC

; Builds the header block for a job -> rax = heap UTF-16 string (or 0)
PROC net_job_headers, 4
        mov     rsi, rcx
        mov     qword loc(1), 0                 ; Buf {ptr=loc(1) len=loc(2)?}  -> laid out at &loc(3)
        mov     qword loc(2), 0
        mov     qword loc(3), 0
        test    dword [rsi+JB_FLAGS], JF_NOAUTH
        jnz     .noauth
        cmp     byte [tok_access], 0
        je      .noauth
        lea     rcx, [tok_lock]
        call    lock_acquire
        lea     rcx, loc(3)
        lea     rdx, [h_auth_pre]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [tok_access]
        call    buf_append_z
        lea     rcx, [tok_lock]
        call    lock_release
        lea     rcx, loc(3)
        lea     rdx, [h_crlf]
        call    buf_append_z
.noauth:
        test    dword [rsi+JB_FLAGS], JF_JSON
        jz      .nj
        lea     rcx, loc(3)
        lea     rdx, [h_json]
        call    buf_append_z
.nj:    test    dword [rsi+JB_FLAGS], JF_FORM
        jz      .nf
        lea     rcx, loc(3)
        lea     rdx, [h_form]
        call    buf_append_z
.nf:    mov     rdx, [rsi+JB_HDRS]
        test    rdx, rdx
        jz      .conv
        lea     rcx, loc(3)
        call    buf_append_z
.conv:  mov     rcx, loc(3)
        test    rcx, rcx
        jz      .none
        cmp     byte [rcx], 0
        je      .none
        mov     rdx, -1
        call    u8_to_w
        mov     rbx, rax
        lea     rcx, loc(3)
        call    buf_free
        mov     rax, rbx
        jmp     .out
.none:  lea     rcx, loc(3)
        call    buf_free
        xor     eax, eax
.out:   EPROC

; rcx = job: performs the request, stores status/response in the job
PROC net_run_job, 4
        mov     rbx, rcx
        mov     dword loc(0), 0                 ; attempts
.again: test    dword [rbx+JB_FLAGS], JF_NOAUTH
        jnz     .hdrs
        call    auth_ensure_fresh               ; renew a token that is about to expire (API worker only)
.hdrs:  mov     rcx, rbx
        call    net_job_headers
        mov     loc(1), rax                     ; headers (wide) to free
        mov     rcx, [rbx+JB_METHOD]
        mov     rdx, [rbx+JB_URL]
        mov     r8, rax
        mov     r9, [rbx+JB_BODY]
        mov     rax, [rbx+JB_BLEN]
        mov     outarg(5), rax
        lea     rax, [rbx+JB_RESP]
        mov     outarg(6), rax
        lea     rax, [rbx+JB_RETRY]
        mov     outarg(7), rax
        call    http_request
        mov     [rbx+JB_STATUS], eax
        mov     rcx, loc(1)
        call    mem_free
        mov     rcx, rbx
        call    log_http
        mov     eax, [rbx+JB_STATUS]
        inc     dword loc(0)
        cmp     dword loc(0), 2
        jae     .done                           ; one retry at most
        cmp     eax, 429
        jne     .not429
        mov     ecx, [rbx+JB_RETRY]
        test    ecx, ecx
        jz      .done
        cmp     ecx, 5
        ja      .done                           ; long waits are reported, not slept through
        imul    ecx, ecx, 1000
        call    Sleep
        lea     rcx, [rbx+JB_RESP]              ; discard the 429 body
        call    buf_reset
        jmp     .again
.not429:
        cmp     eax, 401
        jne     .done
        test    dword [rbx+JB_FLAGS], JF_NOAUTH
        jnz     .done
        call    auth_refresh_blocking           ; returns eax = 1 when a fresh token is now installed
        test    eax, eax
        jz      .done
        lea     rcx, [rbx+JB_RESP]
        call    buf_reset
        jmp     .again
.done:  EPROC

; ---------------------------------------------------------------- UI-thread completion
; rcx = job (from WM_NET_DONE): runs the handler for its tag, then frees it
PROC net_dispatch, 2
        mov     rbx, rcx
        mov     rax, [rbx+JB_TAG]
        cmp     eax, TAG_COUNT
        jae     .free
        lea     rcx, [net_handlers]
        mov     rax, [rcx+rax*8]
        test    rax, rax
        jz      .free
        mov     rcx, rbx
        call    rax
.free:  mov     rcx, rbx
        call    net_job_free
        lock dec dword [net_pending]
        EPROC

PROC net_job_free, 0
        mov     rbx, rcx
        mov     rcx, [rbx+JB_URL]
        call    mem_free
        mov     rcx, [rbx+JB_BODY]
        call    mem_free
        mov     rcx, [rbx+JB_HDRS]
        call    mem_free
        mov     rcx, [rbx+JB_RESP]
        call    mem_free
        mov     rcx, [rbx+JB_PIX]
        call    mem_free
        mov     rcx, rbx
        call    mem_free
        EPROC

; Pumps the message loop until every submitted job has been handled (or the timeout expires).
; ecx = timeout in ms.   Used by the test harness, which must not read state while requests are in flight.
PROC net_wait_idle, 8
        mov     loc(0), rcx
        call    GetTickCount64
        mov     loc(1), rax
.l:     lea     rcx, [msg_buf]
        xor     edx, edx
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword outarg(5), 1              ; PM_REMOVE
        call    PeekMessageW
        test    eax, eax
        jz      .nomsg
        lea     rcx, [msg_buf]
        call    TranslateMessage
        lea     rcx, [msg_buf]
        call    DispatchMessageW
        call    GetTickCount64                  ; endless animation frames must not keep this loop alive past the timeout
        sub     rax, loc(1)
        cmp     rax, loc(0)
        jae     .out
        jmp     .l
.nomsg: cmp     dword [net_pending], 0
        je      .out
        call    GetTickCount64
        sub     rax, loc(1)
        cmp     rax, loc(0)
        jae     .out
        mov     ecx, 4
        call    Sleep
        jmp     .l
.out:   EPROC

; ---------------------------------------------------------------- developer probe: --net-get PATH
; Handler for TAG_DEBUG: records the status and a hash of the body in submit order.
h_debug:
        mov     eax, [dbg_count]
        cmp     eax, 16
        jae     .r
        lea     rdx, [dbg_results]
        mov     ecx, [rcx+JB_STATUS]
        mov     [rdx+rax*8], ecx
        inc     dword [dbg_count]
.r:     ret

section .data
ZSTR l_http, "http "
ZSTR l_arrow, " -> "
ZSTR l_bytes, " (bytes "
ZSTR l_paren, ")"
ZSTR l_fail, "FAILED (transport error "
section .text

; rcx = finished job: "http <METHOD> <url> -> <status> (bytes N)".  URLs carry no secrets (tokens travel in headers).
PROC log_http, 6
        mov     rsi, rcx
        mov     qword loc(2), 0                 ; Buf based at &loc(4)
        mov     qword loc(3), 0
        mov     qword loc(4), 0
        lea     rcx, loc(4)
        lea     rdx, [l_http]
        call    buf_append_z
        mov     rcx, [rsi+JB_METHOD]            ; static UTF-16 verb -> UTF-8
        mov     rdx, -1
        call    w_to_u8
        mov     loc(0), rax
        lea     rcx, loc(4)
        mov     rdx, rax
        call    buf_append_z
        mov     rcx, loc(0)
        call    mem_free
        lea     rcx, loc(4)
        lea     rdx, [l_sp1]
        call    buf_append_z
        lea     rcx, loc(4)
        mov     rdx, [rsi+JB_URL]
        call    buf_append_z
        lea     rcx, loc(4)
        lea     rdx, [l_arrow]
        call    buf_append_z
        mov     eax, [rsi+JB_STATUS]
        test    eax, eax
        jnz     .ok
        lea     rcx, loc(4)
        lea     rdx, [l_fail]
        call    buf_append_z
        lea     rcx, loc(4)
        mov     edx, [g_http_err]
        call    buf_append_u64
        lea     rcx, loc(4)
        lea     rdx, [l_paren]
        call    buf_append_z
        jmp     .emit
.ok:    lea     rcx, loc(4)
        mov     edx, eax
        call    buf_append_u64
        lea     rcx, loc(4)
        lea     rdx, [l_bytes]
        call    buf_append_z
        lea     rcx, loc(4)
        mov     rdx, [rsi+JB_RESP+8]
        call    buf_append_u64
        lea     rcx, loc(4)
        lea     rdx, [l_paren]
        call    buf_append_z
.emit:  mov     rcx, loc(4)
        call    log_msg
        lea     rcx, loc(4)
        call    buf_free
        EPROC
