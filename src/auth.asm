; auth.asm - Spotify sign-in: OAuth 2.0 Authorization Code with PKCE (RFC 7636), token storage and refresh.
;
; Flow: auth_begin() makes a code_verifier / challenge / state, starts the loopback server and opens the
; authorize URL in the browser; the server posts the returned code to the UI thread (auth_on_callback), which
; exchanges it for tokens (TAG_TOKEN) and then loads the profile (TAG_ME).  The refresh token is kept only in
; %APPDATA%\ByteStream\auth.bin, encrypted with DPAPI (bound to this Windows user).  No client secret exists:
; PKCE public clients never send one.
;
; Threads: everything here runs on the UI thread except auth_refresh_blocking / auth_ensure_fresh, which run on
; the API worker.  Shared state (refresh token, expiry, the DPAPI blobs) is guarded by auth_lock.

extern BCryptGenRandom, BCryptHash, CryptProtectData, CryptUnprotectData, LocalFree, DeleteFileW

%define BCRYPT_USE_SYSTEM_PREFERRED_RNG  2
%define BCRYPT_SHA256_ALG_HANDLE         0x00000041

%define AUTH_OUT        0
%define AUTH_WAITING    1               ; browser opened, waiting for the redirect
%define AUTH_EXCHANGE   2               ; talking to Spotify (code exchange / session restore / profile)
%define AUTH_IN         3

%define AUTH_TIMEOUT_MS 300000

section .bss
auth_state:     resd 1
refresh_lock:    resd 1
auth_lock:      resd 1
                align 8
auth_verifier:  resb 72                 ; 64 chars + NUL
                align 8
auth_challenge: resb 48                 ; 43 chars + NUL
                align 8
auth_expect:    resb 40                 ; "state" we expect on the redirect (22 chars + NUL); empty = none pending
                align 8
auth_refresh:   resb 520                ; refresh token (UTF-8, NUL-terminated); empty when signed out
auth_expiry:    resq 1                  ; GetTickCount64() after which the access token must be renewed (0 = none)
auth_wait_t0:   resq 1
                align 8
auth_path:      resw 560
auth_url_buf:   resq 3                  ; Buf holding the last authorize URL (for "Copy sign-in link")
auth_blob_in:   resq 2                  ; DATA_BLOB { dword cb; qword pb }
auth_blob_out:  resq 2
                align 8
auth_rnd:       resb 64
                align 8
auth_hash:      resb 32
auth_restoring: resd 1                  ; 1 while a stored session is being restored at startup

section .data
WSTR w_auth_name, "\auth.bin"                ; plain quotes: in backtick strings \a is a bell character
ZSTR a_alphabet, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
ZSTR a_authorize, "/authorize?response_type=code&client_id="
ZSTR a_scope_pre, "&scope="
ZSTR a_redir_pre, "&redirect_uri="
ZSTR a_state_pre, "&state="
ZSTR a_chal_pre, "&code_challenge_method=S256&code_challenge="
ZSTR a_scopes, "streaming user-read-email user-read-private user-library-read user-library-modify playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private user-read-playback-state user-modify-playback-state user-read-currently-playing user-read-recently-played user-follow-read user-follow-modify"
ZSTR a_token_path, "/api/token"
ZSTR a_grant_code, "grant_type=authorization_code&code="
ZSTR a_grant_refresh, "grant_type=refresh_token&refresh_token="
ZSTR a_cid, "&client_id="
ZSTR a_verif, "&code_verifier="
ZSTR a_me_path, "/v1/me"
WSTR w_post, "POST"
WSTR w_form_hdr, `Content-Type: application/x-www-form-urlencoded\r\n`
ZSTR j_access, "access_token"
ZSTR j_refresh, "refresh_token"
ZSTR j_expires, "expires_in"
ZSTR j_error, "error"
ZSTR j_errdesc, "error_description"
ZSTR j_display, "display_name"
ZSTR j_id, "id"
ZSTR a_signin_open, "sign-in: browser opened"
ZSTR a_signin_cb, "sign-in: redirect received, exchanging code"
ZSTR a_signin_ok, "sign-in: tokens installed"
ZSTR a_signin_restore, "sign-in: restoring stored session"
ZSTR a_signin_fail, "sign-in: failed, token endpoint status "
ZSTR a_refresh_ok, "auth: access token refreshed"
ZSTR a_refresh_bad, "auth: refresh failed, status "
ZSTR a_signed_out, "sign-out: stored credentials removed"
ZSTR a_save_efail, "auth: could not encrypt the refresh token (error "
ZSTR a_save_wfail, "auth: could not write auth.bin (error "
WSTR w_err_offline, "Could not reach Spotify. Check your internet connection and try again."
WSTR w_err_denied, "Sign-in was cancelled in the browser."
WSTR w_err_expired, "Your Spotify session expired. Please sign in again."
WSTR w_err_forbidden, `Spotify refused this account (HTTP 403). In the Spotify dashboard open your app, go to Users Management, add your account, then sign in again.`
WSTR w_err_timeout, "Sign-in timed out. Click Sign in with Spotify to try again."
WSTR w_err_badclient, "Spotify did not accept this Client ID. Check it in the setup box (step 3)."
WSTR w_err_badredirect, "Spotify rejected the redirect address. Add exactly the address from step 2 to your Spotify app."
WSTR w_err_generic, "Spotify returned an error while signing in. Details are in the log (Settings > Diagnostics)."
WSTR w_err_server, "The sign-in server could not start. Another program may be using the port; change it in step 2."
WSTR w_lbl_dashboard, "Open dashboard"
ZSTR e_invalid_client, "invalid_client"
ZSTR e_invalid_grant, "invalid_grant"
ZSTR e_access_denied, "access_denied"

section .text

; ---------------------------------------------------------------- primitives
; rcx = buffer, edx = byte count : fills with cryptographically strong random bytes
PROC rand_bytes, 0
        mov     r8d, edx
        mov     rdx, rcx
        xor     ecx, ecx
        mov     r9d, BCRYPT_USE_SYSTEM_PREFERRED_RNG
        call    BCryptGenRandom
        EPROC

; rcx = data, rdx = length, r8 = 32-byte output
PROC sha256, 0
        mov     r9, rcx                         ; pbInput
        mov     outarg(5), rdx                  ; cbInput
        mov     outarg(6), r8                   ; pbOutput
        mov     qword outarg(7), 32             ; cbOutput
        mov     ecx, BCRYPT_SHA256_ALG_HANDLE
        xor     edx, edx                        ; pbSecret = NULL
        xor     r8d, r8d                        ; cbSecret = 0
        call    BCryptHash
        EPROC

; rcx = verifier, rdx = length, r8 = output (>= 44 bytes): PKCE S256 challenge = base64url(SHA-256(verifier)), NUL-terminated
PROC pkce_challenge_of, 1
        mov     loc(0), r8
        lea     r8, [auth_hash]
        call    sha256
        lea     rcx, [auth_hash]
        mov     edx, 32
        mov     r8, loc(0)
        call    b64url_enc
        mov     rcx, loc(0)
        mov     byte [rcx+rax], 0
        EPROC

; fresh verifier (64 URL-safe chars), its challenge and a CSRF state
PROC pkce_make, 0
        lea     rcx, [auth_rnd]
        mov     edx, 64
        call    rand_bytes
        lea     rsi, [auth_rnd]
        lea     rdi, [auth_verifier]
        lea     r8, [a_alphabet]
        xor     ecx, ecx
.v:     movzx   eax, byte [rsi+rcx]
        and     eax, 63                         ; 64-symbol alphabet: no modulo bias
        mov     al, [r8+rax]
        mov     [rdi+rcx], al
        inc     ecx
        cmp     ecx, 64
        jb      .v
        mov     byte [rdi+64], 0
        lea     rcx, [auth_verifier]
        mov     edx, 64
        lea     r8, [auth_challenge]
        call    pkce_challenge_of
        lea     rcx, [auth_rnd]
        mov     edx, 16
        call    rand_bytes
        lea     rcx, [auth_rnd]
        mov     edx, 16
        lea     r8, [auth_expect]
        call    b64url_enc
        lea     rcx, [auth_expect]
        mov     byte [rcx+rax], 0
        EPROC

; ---------------------------------------------------------------- stored refresh token (DPAPI)
PROC auth_init, 0
        lea     rcx, [auth_path]
        lea     rdx, [data_dir]
        call    lstrcpyW
        lea     rcx, [auth_path]
        lea     rdx, [w_auth_name]
        call    lstrcatW
        EPROC

; encrypts auth_refresh with the current Windows user's key and writes auth.bin
PROC auth_save, 2
        lea     rcx, [auth_lock]
        call    lock_acquire
        lea     rcx, [auth_refresh]
        call    u8_len
        lea     rdi, [auth_blob_in]
        mov     [rdi], eax
        lea     rax, [auth_refresh]
        mov     [rdi+8], rax
        mov     rcx, rdi
        xor     edx, edx                        ; description
        xor     r8d, r8d                        ; entropy
        xor     r9d, r9d                        ; reserved
        mov     qword outarg(5), 0              ; prompt
        mov     qword outarg(6), 1              ; CRYPTPROTECT_UI_FORBIDDEN
        lea     rax, [auth_blob_out]
        mov     outarg(7), rax
        call    CryptProtectData
        test    eax, eax
        jz      .encfail
        lea     rdi, [auth_blob_out]
        lea     rcx, [auth_path]
        mov     rdx, [rdi+8]
        mov     r8d, [rdi]
        call    file_write_all
        mov     loc(0), rax
        mov     rcx, [auth_blob_out+8]
        call    LocalFree
        cmp     qword loc(0), 0
        jne     .done
        lea     rcx, [a_save_wfail]
        call    GetLastError
        mov     edx, eax
        lea     rcx, [a_save_wfail]
        call    log_num
        jmp     .done
.encfail:
        call    GetLastError
        mov     edx, eax
        lea     rcx, [a_save_efail]
        call    log_num
.done:  lea     rcx, [auth_lock]
        call    lock_release
        EPROC

; reads and decrypts auth.bin into auth_refresh -> eax = 1 when a stored session exists
PROC auth_load, 3
        lea     rcx, [auth_path]
        call    file_read_all
        test    rax, rax
        jz      .none
        mov     loc(0), rax
        lea     rdi, [auth_blob_in]
        mov     [rdi], edx
        mov     [rdi+8], rax
        mov     rcx, rdi
        xor     edx, edx
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword outarg(5), 0
        mov     qword outarg(6), 1
        lea     rax, [auth_blob_out]
        mov     outarg(7), rax
        call    CryptUnprotectData
        mov     loc(1), rax
        mov     rcx, loc(0)
        call    mem_free
        cmp     qword loc(1), 0
        je      .none
        mov     ecx, [auth_blob_out]
        cmp     ecx, 500
        ja      .badsize
        lea     rdi, [auth_refresh]
        mov     rsi, [auth_blob_out+8]
        xor     eax, eax
.cp:    cmp     eax, ecx
        jae     .term
        mov     dl, [rsi+rax]
        mov     [rdi+rax], dl
        inc     eax
        jmp     .cp
.term:  mov     byte [rdi+rax], 0
        mov     rcx, [auth_blob_out+8]
        call    LocalFree
        mov     eax, 1
        jmp     .out
.badsize:
        mov     rcx, [auth_blob_out+8]
        call    LocalFree
.none:  xor     eax, eax
.out:   EPROC

; wipes tokens from memory and disk
PROC auth_forget, 0
        lea     rcx, [auth_lock]
        call    lock_acquire
        lea     rdi, [auth_refresh]
        mov     ecx, 520
        xor     eax, eax
        rep     stosb
        mov     qword [auth_expiry], 0
        lea     rcx, [auth_lock]
        call    lock_release
        xor     ecx, ecx
        call    net_set_token
        lea     rcx, [auth_path]
        call    DeleteFileW
        EPROC

; ---------------------------------------------------------------- token responses
; rcx = JSON object text (token endpoint response) -> eax = 1 when it carried an access token.
; Installs the access token, its expiry, and (when present) a new refresh token, which is persisted.
PROC auth_install_tokens, 4
        test    rcx, rcx
        jz      .bad
        mov     loc(0), rcx
        lea     rdx, [j_access]
        call    jpu
        mov     loc(1), rax
        cmp     byte [rax], 0
        je      .nofree
        mov     rcx, rax
        call    net_set_token
        mov     rcx, loc(0)
        lea     rdx, [j_expires]
        call    jpi
        test    eax, eax
        jnz     .exp
        mov     eax, 3600
.exp:   cmp     eax, 90
        ja      .okexp
        mov     eax, 90                         ; never schedule a refresh sooner than the margin
.okexp: sub     eax, 30                         ; renew a little early
        imul    rax, rax, 1000
        mov     loc(2), rax
        call    GetTickCount64
        add     rax, loc(2)
        mov     [auth_expiry], rax
        mov     rcx, loc(0)
        lea     rdx, [j_refresh]
        call    jpu
        mov     loc(2), rax
        cmp     byte [rax], 0
        je      .norefresh
        lea     rcx, [auth_lock]
        call    lock_acquire
        mov     rsi, loc(2)
        lea     rdi, [auth_refresh]
        xor     ecx, ecx
.cp:    cmp     ecx, 510
        jae     .t
        mov     al, [rsi+rcx]
        test    al, al
        jz      .t
        mov     [rdi+rcx], al
        inc     ecx
        jmp     .cp
.t:     mov     byte [rdi+rcx], 0
        lea     rcx, [auth_lock]
        call    lock_release
        call    auth_save
.norefresh:
        mov     rcx, loc(2)
        call    mem_free
        mov     rcx, loc(1)
        call    mem_free
        mov     eax, 1
        jmp     .out
.nofree: mov    rcx, loc(1)
        call    mem_free
.bad:   xor     eax, eax
.out:   EPROC

; ---------------------------------------------------------------- request bodies
; rcx = Buf* : appends "grant_type=refresh_token&refresh_token=<token>&client_id=<id>"
PROC auth_refresh_body, 1
        mov     loc(0), rcx
        lea     rdx, [a_grant_refresh]
        call    buf_append_z
        lea     rcx, [auth_lock]
        call    lock_acquire
        lea     rcx, [auth_refresh]
        call    u8_len
        mov     r8, rax
        mov     rcx, loc(0)
        lea     rdx, [auth_refresh]
        call    buf_append_urlenc
        lea     rcx, [auth_lock]
        call    lock_release
        mov     rcx, loc(0)
        lea     rdx, [a_cid]
        call    buf_append_z
        lea     rcx, [set_client_id]
        call    u8_len
        mov     r8, rax
        mov     rcx, loc(0)
        lea     rdx, [set_client_id]
        call    buf_append_urlenc
        EPROC

; ---------------------------------------------------------------- refresh on a worker thread
; Both the API worker and the local server's token route (the player page asks for a token whenever its SDK needs
; one) may refresh, so the whole exchange runs under refresh_lock.
; -> eax = 1 when a fresh access token was installed
PROC auth_refresh_blocking, 2
        lea     rcx, [refresh_lock]
        call    lock_acquire
        call    auth_refresh_locked
        mov     ebx, eax
        lea     rcx, [refresh_lock]
        call    lock_release
        mov     eax, ebx
        EPROC

; (caller holds refresh_lock).  Locals: loc(0) token URL; Bufs: body top 3, response top 6, url top 9
PROC auth_refresh_locked, 12
        cmp     byte [auth_refresh], 0
        je      .no
        BUFZERO 3
        BUFZERO 6
        BUFZERO 9
        lea     rcx, loc(3)
        call    auth_refresh_body
        lea     rcx, loc(9)
        lea     rdx, [a_token_path]
        call    auth_url
        lea     rcx, [w_post]
        mov     rdx, loc(9)
        lea     r8, [w_form_hdr]
        mov     r9, loc(3)
        mov     rax, loc(2)
        mov     outarg(5), rax                  ; body length
        lea     rax, loc(6)
        mov     outarg(6), rax                  ; response Buf
        mov     qword outarg(7), 0
        call    http_request
        mov     r12d, eax
        cmp     r12d, 200
        jne     .fail
        mov     rcx, loc(6)
        call    auth_install_tokens
        test    eax, eax
        jz      .fail
        lea     rcx, [a_refresh_ok]
        call    log_msg
        mov     r12d, 1
        jmp     .done
.fail:  lea     rcx, [a_refresh_bad]
        mov     edx, r12d
        call    log_num
        cmp     r12d, 400
        jne     .nf
        call    auth_forget                     ; refresh token revoked or expired: do not retry it
.nf:    xor     r12d, r12d
.done:  lea     rcx, loc(3)
        call    buf_free
        lea     rcx, loc(6)
        call    buf_free
        lea     rcx, loc(9)
        call    buf_free
        mov     eax, r12d
        jmp     .out
.no:    xor     eax, eax
.out:   EPROC

; called by the API worker before every authenticated request: renew a token that is about to expire
PROC auth_ensure_fresh, 0
        cmp     byte [auth_refresh], 0
        je      .out
        lea     rcx, [refresh_lock]
        call    lock_acquire
        mov     rax, [auth_expiry]              ; (checked under the lock: another thread may just have refreshed)
        test    rax, rax
        jz      .unlock
        mov     rbx, rax
        call    GetTickCount64
        add     rax, 60000
        cmp     rax, rbx
        jb      .unlock                         ; more than a minute left
        call    auth_refresh_locked
.unlock: lea    rcx, [refresh_lock]
        call    lock_release
.out:   EPROC

; ---------------------------------------------------------------- user-visible failures
; rcx = message (UTF-16), rdx = banner action label (UTF-16) or 0, r8d = banner action code
PROC auth_fail, 3
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     dword [auth_state], AUTH_OUT
        mov     byte [auth_expect], 0
        mov     dword [auth_restoring], 0
        mov     dword [signed_in], 0
        xor     ecx, ecx
        call    net_set_token
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        mov     r8, loc(2)
        call    ui_banner
        EPROC

; rcx = haystack, rdx = needle (both UTF-8, NUL-terminated) -> eax = 1 when needle occurs in haystack
u8_contains:
        push    rsi
        push    rdi
        mov     rsi, rcx
.outer: cmp     byte [rsi], 0
        je      .no
        mov     rdi, rdx
        mov     rcx, rsi
.inner: mov     al, [rdi]
        test    al, al
        jz      .yes
        cmp     al, [rcx]
        jne     .next
        inc     rdi
        inc     rcx
        jmp     .inner
.next:  inc     rsi
        jmp     .outer
.yes:   mov     eax, 1
        jmp     .out
.no:    xor     eax, eax
.out:   pop     rdi
        pop     rsi
        ret

; ---------------------------------------------------------------- starting a sign-in
; -> eax = 1 when the browser was opened.   Locals: Buf (redirect URI scratch) top 3
PROC auth_begin, 6
        call    pkce_make
        call    srv_start
        test    eax, eax
        jnz     .srv
        lea     rcx, [w_err_server]
        xor     edx, edx
        xor     r8d, r8d
        call    auth_fail
        xor     eax, eax
        jmp     .out
.srv:   lea     rcx, [auth_url_buf]
        lea     rdx, [a_authorize]
        call    auth_url
        lea     rcx, [set_client_id]
        call    u8_len
        mov     r8, rax
        lea     rcx, [auth_url_buf]
        lea     rdx, [set_client_id]
        call    buf_append_urlenc
        lea     rcx, [auth_url_buf]
        lea     rdx, [a_scope_pre]
        call    buf_append_z
        lea     rcx, [a_scopes]
        call    u8_len
        mov     r8, rax
        lea     rcx, [auth_url_buf]
        lea     rdx, [a_scopes]
        call    buf_append_urlenc
        lea     rcx, [auth_url_buf]
        lea     rdx, [a_redir_pre]
        call    buf_append_z
        BUFZERO 3
        lea     rcx, loc(3)
        call    redirect_uri_append
        mov     r8, loc(2)                      ; redirect length
        lea     rcx, [auth_url_buf]
        mov     rdx, loc(3)
        call    buf_append_urlenc
        lea     rcx, loc(3)
        call    buf_free
        lea     rcx, [auth_url_buf]
        lea     rdx, [a_state_pre]
        call    buf_append_z
        lea     rcx, [auth_url_buf]
        lea     rdx, [auth_expect]
        call    buf_append_z
        lea     rcx, [auth_url_buf]
        lea     rdx, [a_chal_pre]
        call    buf_append_z
        lea     rcx, [auth_url_buf]
        lea     rdx, [auth_challenge]
        call    buf_append_z
        call    ui_banner_clear
        mov     dword [auth_state], AUTH_WAITING
        call    GetTickCount64
        mov     [auth_wait_t0], rax
        lea     rcx, [a_signin_open]
        call    log_msg
        mov     rcx, [auth_url_buf]
        call    os_open_url
        mov     eax, 1
.out:   EPROC

; "Cancel" on the sign-in screen
PROC auth_cancel, 0
        mov     dword [auth_state], AUTH_OUT
        mov     byte [auth_expect], 0
        EPROC

; WM_APP+3 from the loopback server: rcx = heap string (the code, or the error name), edx = 0 code / 1 error.
; Takes ownership of the string.   Locals: loc(0) string, loc(1) kind; Bufs: body top 4, redirect top 7, url top 10
PROC auth_on_callback, 12
        mov     loc(0), rcx
        mov     loc(1), rdx
        cmp     dword [auth_state], AUTH_WAITING
        jne     .drop
        mov     byte [auth_expect], 0           ; a state value is single-use
        cmp     dword loc(1), 0
        je      .code
        mov     rcx, loc(0)
        lea     rdx, [e_access_denied]
        call    u8_eq
        lea     rcx, [w_err_denied]
        test    eax, eax
        jnz     .showerr
        lea     rcx, [w_err_generic]
.showerr:
        xor     edx, edx
        xor     r8d, r8d
        call    auth_fail
        jmp     .drop
.code:  lea     rcx, [a_signin_cb]
        call    log_msg
        mov     dword [auth_state], AUTH_EXCHANGE
        BUFZERO 4
        BUFZERO 7
        BUFZERO 10
        lea     rcx, loc(4)
        lea     rdx, [a_grant_code]
        call    buf_append_z
        mov     rcx, loc(0)
        call    u8_len
        mov     r8, rax
        lea     rcx, loc(4)
        mov     rdx, loc(0)
        call    buf_append_urlenc
        lea     rcx, loc(4)
        lea     rdx, [a_redir_pre]
        call    buf_append_z
        lea     rcx, loc(7)
        call    redirect_uri_append
        mov     r8, loc(6)                      ; redirect length
        lea     rcx, loc(4)
        mov     rdx, loc(7)
        call    buf_append_urlenc
        lea     rcx, loc(7)
        call    buf_free
        lea     rcx, loc(4)
        lea     rdx, [a_cid]
        call    buf_append_z
        lea     rcx, [set_client_id]
        call    u8_len
        mov     r8, rax
        lea     rcx, loc(4)
        lea     rdx, [set_client_id]
        call    buf_append_urlenc
        lea     rcx, loc(4)
        lea     rdx, [a_verif]
        call    buf_append_z
        lea     rcx, loc(4)
        lea     rdx, [auth_verifier]
        call    buf_append_z
        lea     rcx, loc(10)
        lea     rdx, [a_token_path]
        call    auth_url
        xor     ecx, ecx
        mov     edx, TAG_TOKEN
        xor     r8d, r8d                        ; arg 0 = code exchange
        lea     r9, [w_post]
        mov     rax, loc(10)
        mov     outarg(5), rax
        mov     rax, loc(4)
        mov     outarg(6), rax
        mov     qword outarg(7), JF_FORM | JF_NOAUTH
        mov     qword outarg(8), 0
        call    net_submit
        lea     rcx, loc(4)
        call    buf_free
        lea     rcx, loc(10)
        call    buf_free
.drop:  mov     rcx, loc(0)
        call    mem_free
        EPROC

; ---------------------------------------------------------------- startup: restore a stored session
; Locals: Bufs: body top 2, url top 5
PROC auth_restore, 6
        cmp     byte [set_client_id], 0
        je      .out
        call    auth_load
        test    eax, eax
        jz      .out
        mov     dword [auth_state], AUTH_EXCHANGE
        mov     dword [auth_restoring], 1
        lea     rcx, [a_signin_restore]
        call    log_msg
        BUFZERO 2
        BUFZERO 5
        lea     rcx, loc(2)
        call    auth_refresh_body
        lea     rcx, loc(5)
        lea     rdx, [a_token_path]
        call    auth_url
        xor     ecx, ecx
        mov     edx, TAG_TOKEN
        mov     r8d, 1                          ; arg 1 = session restore
        lea     r9, [w_post]
        mov     rax, loc(5)
        mov     outarg(5), rax
        mov     rax, loc(2)
        mov     outarg(6), rax
        mov     qword outarg(7), JF_FORM | JF_NOAUTH
        mov     qword outarg(8), 0
        call    net_submit
        lea     rcx, loc(2)
        call    buf_free
        lea     rcx, loc(5)
        call    buf_free
.out:   EPROC

; ---------------------------------------------------------------- job handlers (UI thread)
; TAG_TOKEN: the token endpoint answered.   Locals: loc(0) job, loc(1) error name, loc(2) description
PROC h_token, 4
        mov     rsi, rcx
        mov     loc(0), rcx
        mov     eax, [rsi+JB_STATUS]
        cmp     eax, 200
        jne     .error
        mov     rcx, [rsi+JB_RESP]
        call    auth_install_tokens
        test    eax, eax
        jz      .generic
        lea     rcx, [a_signin_ok]
        call    log_msg
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [a_me_path]
        call    api_url
        xor     ecx, ecx
        mov     edx, TAG_ME
        xor     r8d, r8d
        lea     r9, [w_get]
        mov     rax, loc(5)
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        mov     qword outarg(7), 0
        mov     qword outarg(8), 0
        call    net_submit
        lea     rcx, loc(5)
        call    buf_free
        jmp     .out
.error: mov     rsi, loc(0)
        lea     rcx, [a_signin_fail]
        mov     edx, [rsi+JB_STATUS]
        call    log_num
        mov     rsi, loc(0)
        cmp     dword [rsi+JB_STATUS], 0
        jne     .parse
        lea     rcx, [w_err_offline]
        jmp     .fail
.parse: mov     rcx, [rsi+JB_RESP]
        lea     rdx, [j_error]
        call    jpu
        mov     loc(1), rax
        mov     rsi, loc(0)
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [j_errdesc]
        call    jpu
        mov     loc(2), rax
        mov     rcx, loc(1)
        lea     rdx, [e_invalid_client]
        call    u8_eq
        test    eax, eax
        jz      .grant
        lea     rcx, [w_err_badclient]
        jmp     .cleanup
.grant: mov     rcx, loc(1)
        lea     rdx, [e_invalid_grant]
        call    u8_eq
        test    eax, eax
        jz      .gen2
        mov     rsi, loc(0)
        cmp     qword [rsi+JB_ARG], 1
        jne     .redir
        call    auth_forget                     ; the stored session is no longer valid
        lea     rcx, [w_err_expired]
        jmp     .cleanup
.redir: mov     rcx, loc(2)
        lea     rdx, [s_word_redirect]
        call    u8_contains
        test    eax, eax
        jz      .gen2
        lea     rcx, [w_err_badredirect]
        jmp     .cleanup
.gen2:  lea     rcx, [w_err_generic]
.cleanup:
        mov     rbx, rcx                        ; keep the chosen message across the frees
        mov     rcx, loc(1)
        call    mem_free
        mov     rcx, loc(2)
        call    mem_free
        mov     rcx, rbx
.fail:  xor     edx, edx
        xor     r8d, r8d
        call    auth_fail
        jmp     .out
.generic:
        lea     rcx, [w_err_generic]
        jmp     .fail
.out:   EPROC

section .data
ZSTR s_word_redirect, "redirect"
ZSTR a_signed_in_as, "Signed in as "
section .text

; TAG_ME: the profile answered - sign-in is complete (or refused).   Locals: loc(0) job, loc(1) name; Buf top 4
PROC h_me, 6
        mov     rsi, rcx
        mov     loc(0), rcx
        mov     eax, [rsi+JB_STATUS]
        cmp     eax, 200
        je      .ok
        cmp     eax, 403
        je      .forbidden
        cmp     eax, 401
        je      .expired
        cmp     eax, 0
        je      .offline
        lea     rcx, [w_err_generic]
        jmp     .fail
.offline:
        lea     rcx, [w_err_offline]
        jmp     .fail
.expired:
        call    auth_forget
        lea     rcx, [w_err_expired]
        jmp     .fail
.forbidden:
        call    auth_forget
        lea     rcx, [w_err_forbidden]
        lea     rdx, [w_lbl_dashboard]
        mov     r8d, BA_DASHBOARD
        call    auth_fail
        jmp     .out
.fail:  xor     edx, edx
        xor     r8d, r8d
        call    auth_fail
        jmp     .out
.ok:    mov     rcx, [rsi+JB_RESP]
        lea     rdx, [j_display]
        call    jpu
        mov     loc(1), rax
        cmp     byte [rax], 0
        jne     .named
        mov     rcx, loc(1)
        call    mem_free
        mov     rsi, loc(0)
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [j_id]
        call    jpu
        mov     loc(1), rax
.named: mov     rcx, [user_id]
        call    mem_free
        mov     rsi, loc(0)
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [j_id]
        call    jpu
        mov     [user_id], rax
        mov     rcx, [user_name]
        call    mem_free
        mov     rcx, loc(1)
        mov     rdx, -1
        call    u8_to_w
        mov     [user_name], rax
        mov     dword [g_demo], 0
        mov     dword [signed_in], 1
        mov     dword [auth_state], AUTH_IN
        mov     dword [auth_restoring], 0
        mov     dword [page], PAGE_HOME
        mov     dword [scroll_main], 0
        call    ui_banner_clear
        call    lib_load_all
        BUFZERO 4
        lea     rcx, loc(4)
        lea     rdx, [a_signed_in_as]
        call    buf_append_z
        lea     rcx, loc(4)
        mov     rdx, loc(1)
        call    buf_append_z
        mov     rcx, loc(4)
        mov     rdx, -1
        call    u8_to_w
        mov     rbx, rax
        mov     rcx, rax
        call    ui_toast
        mov     rcx, rbx
        call    mem_free
        lea     rcx, loc(4)
        call    buf_free
        mov     rcx, loc(1)
        call    mem_free
.out:   EPROC

; ---------------------------------------------------------------- sign out, timeouts
PROC auth_sign_out, 0
        call    auth_cancel
        call    auth_forget
        mov     rcx, [user_name]
        call    mem_free
        mov     qword [user_name], 0
        call    app_free_all
        call    lib_reset
        call    edge_stop
        call    np_clear
        mov     dword [np_valid], 0
        mov     dword [signed_in], 0
        mov     dword [g_demo], 0
        mov     dword [page], PAGE_LOGIN
        mov     dword [fullscreen], 0
        call    ui_banner_clear
        lea     rcx, [a_signed_out]
        call    log_msg
        EPROC

; called from the UI timer: gives up on a sign-in the user walked away from
PROC auth_tick, 0
        cmp     dword [auth_state], AUTH_WAITING
        jne     .out
        call    GetTickCount64
        sub     rax, [auth_wait_t0]
        cmp     rax, AUTH_TIMEOUT_MS
        jb      .out
        lea     rcx, [w_err_timeout]
        xor     edx, edx
        xor     r8d, r8d
        call    auth_fail
        mov     eax, 1                          ; state changed: repaint
        jmp     .done
.out:   xor     eax, eax
.done:  EPROC
