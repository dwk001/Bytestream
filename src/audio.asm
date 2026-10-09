; audio.asm - in-app Spotify playback.
;
; Spotify audio is DRM-protected, so ByteStream never touches it.  Playback runs in Spotify's official Web Playback
; SDK inside a hidden Microsoft Edge window that ByteStream starts (web/player.html + web/player.js, served by the
; loopback server).  This file is the native side:
;
;   edge_launch / edge_stop / edge_tick   start Edge minimised in its own profile, kill it with the app (job object),
;                                         shut it down after 10 idle minutes, notice if it dies
;   bridge_event                          messages from the page (ready, state, error) -> the now-playing state
;   real_play_list ... real_set_volume    the transport controls: PUT /me/player/play for "play this", and tiny JSON
;                                         commands over the event stream for pause / seek / volume / skip
;
; Everything here runs on the UI thread.

extern CreateProcessW, CreateJobObjectW, SetInformationJobObject, AssignProcessToJobObject, TerminateProcess
extern GetExitCodeProcess, ResumeThread, RegOpenKeyExW, RegQueryValueExW, RegCloseKey, ExpandEnvironmentStringsW
extern GetFileAttributesW

%define EDGE_IDLE_MS        600000      ; stop the helper after 10 minutes of silence
%define EDGE_CONNECT_MS     45000       ; give the helper this long to connect after launch
%define STILL_ACTIVE        259

section .bss
sdk_ready:      resd 1                  ; 1 once the page reported the Connect device
sdk_device:     resb 96                 ; its device id (UTF-8)
play_pending:   resq 1                  ; heap JSON body of a play request waiting for the helper
edge_exe:       resw 540
edge_override:  resq 1                  ; --edge-path (UTF-16), tests only
edge_proc:      resq 1
edge_job:       resq 1
edge_t0:        resq 1                  ; when the helper was launched
idle_t0:        resq 1                  ; when playback last stopped (0 = playing)
edge_si:        resb 112                ; STARTUPINFOW
edge_pi:        resb 32                 ; PROCESS_INFORMATION
edge_jobinfo:   resb 144                ; JOBOBJECT_EXTENDED_LIMIT_INFORMATION
edge_regsz:     resd 1
edge_regbuf:    resw 540

section .data
WSTR w_put, "PUT"
WSTR w_reg_edge, `SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\msedge.exe`
WSTR w_reg_chrome, `SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\chrome.exe`
WSTR w_edge_p1, `%ProgramFiles(x86)%\\Microsoft\\Edge\\Application\\msedge.exe`
WSTR w_edge_p2, `%ProgramFiles%\\Microsoft\\Edge\\Application\\msedge.exe`
WSTR w_chrome_p1, `%ProgramFiles%\\Google\\Chrome\\Application\\chrome.exe`
WSTR w_chrome_p2, `%ProgramFiles(x86)%\\Google\\Chrome\\Application\\chrome.exe`
WSTR w_chrome_p3, `%LOCALAPPDATA%\\Google\\Chrome\\Application\\chrome.exe`
WSTR w_edge_dir, `\\edge`
ZSTR e_q1, `"`
ZSTR e_app, ` --app=http://127.0.0.1:`
ZSTR e_player, `/player?k=`
ZSTR e_udd, ` --user-data-dir="`
ZSTR e_flags, `" --no-first-run --no-default-browser-check --disable-extensions --disable-sync --disable-default-apps --disable-gpu --autoplay-policy=no-user-gesture-required --disable-features=Translate,MediaRouter,CalculateNativeWinOcclusion --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows`
ZSTR e_launch_pre, "edge-launch:http://127.0.0.1:"
ZSTR s_edge_url, "https://www.microsoft.com/edge"
ZSTR l_edge_launch, "audio: starting helper "
ZSTR l_edge_none, "audio: no Edge or Chrome found"
ZSTR l_edge_fail, "audio: could not start the helper, error "
ZSTR l_edge_exit, "audio: helper exited, code "
ZSTR l_edge_idle, "audio: stopping the idle helper"
ZSTR l_edge_timeout, "audio: helper did not connect in time"
ZSTR l_ready, "audio: player ready, device "
ZSTR l_notready, "audio: player went away"
ZSTR l_track, "audio: now playing "
ZSTR l_play_ok, "audio: play request accepted"
ZSTR l_play_req, "audio: play requested"
ZSTR l_play_fail, "audio: play request failed, status "
ZSTR l_sdk_error, "audio: SDK error "
ZSTR l_hello, "audio: page loaded"
ZSTR ty_ready, "ready"
ZSTR ty_notready, "not_ready"
ZSTR ty_state, "state"
ZSTR ty_error, "error"
ZSTR ty_hello, "hello"
ZSTR ty_quit, "quit"
ZSTR ty_go, "go"
ZSTR k_type, "type"
ZSTR k_device, "device_id"
ZSTR k_kind, "kind"
ZSTR a_empty, "empty"
ZSTR k_paused, "paused"
ZSTR k_position, "position"
ZSTR k_duration, "duration"
ZSTR k_shuffle, "shuffle"
ZSTR k_repeat, "repeat"
ZSTR k_t_uri, "track.uri"
ZSTR k_t_name, "track.name"
ZSTR k_t_artists, "track.artists"
ZSTR k_t_album, "track.album"
ZSTR k_t_images, "track.images"
ZSTR k_err_reason, "error.reason"
ZSTR er_account, "account_error"
ZSTR er_auth, "authentication_error"
ZSTR er_init, "initialization_error"
ZSTR er_playback, "playback_error"
ZSTR er_autoplay, "autoplay_failed"
ZSTR c_toggle, `{"cmd":"toggle"}`
ZSTR c_next, `{"cmd":"next"}`
ZSTR c_prev, `{"cmd":"prev"}`
ZSTR c_seek_pre, `{"cmd":"seek","ms":`
ZSTR c_vol_pre, `{"cmd":"volume","pct":`
ZSTR c_close, `}`
ZSTR c_state, `{"cmd":"state"}`
ZSTR b_ctx_pre, `{"context_uri":"`
ZSTR b_ctx_mid, `","offset":{"uri":"`
ZSTR b_ctx_end, `"}}`
ZSTR b_ctx_close, `"}`
ZSTR b_uris_pre, `{"uris":[`
ZSTR b_uris_end, `]}`
ZSTR b_quote, `"`
ZSTR b_comma, `,`
ZSTR p_play, "/v1/me/player/play?device_id="
ZSTR p_shuffle, "/v1/me/player/shuffle?state="
ZSTR p_repeat, "/v1/me/player/repeat?state="
ZSTR p_devarg, "&device_id="
ZSTR b_true, "true"
ZSTR b_false, "false"
ZSTR b_off, "off"
ZSTR b_context, "context"
ZSTR b_track, "track"
ZSTR u_local, "spotify:local:"
ZSTR u_test_track, "spotify:track:4cOdK2wGLETKBW3PvgPWqT"
ZSTR s_comma_sp, ", "
WSTR w_err_noedge, "Microsoft Edge was not found. ByteStream uses it to play Spotify audio; install Edge and try again."
WSTR w_lbl_getedge, "Get Edge"
WSTR w_err_premium, "Spotify Premium is required to play music in ByteStream."
WSTR w_err_pauth, "Spotify did not accept the login for playback. Sign out and sign in again."
WSTR w_err_pinit, "The audio helper could not start Spotify playback (the browser reported no DRM support). Update Microsoft Edge and try again."
WSTR w_err_pconn, "The audio helper could not connect to Spotify. Check your internet connection and try again."
WSTR w_err_ptimeout, "The audio helper did not start in time. Try again; details are in Settings > Diagnostics."
WSTR w_err_pdevice, "Spotify could not find ByteStream's player. Press play again."
WSTR w_ta_demo, "Sign in to test audio."
WSTR w_msg_starting, "Starting audio..."
WSTR w_msg_playfail, "Spotify could not play that."
WSTR w_msg_unplayable, "Nothing playable in this list."
WSTR w_msg_unavailable, "Spotify does not offer that track here."
WSTR w_msg_autoplay, "The audio helper was blocked from starting playback. Press play again."

section .text

; ---------------------------------------------------------------- finding and launching the browser
; rcx = UTF-16 path with %VARS% -> eax = 1 and edge_exe set when that file exists
PROC edge_try_path, 0
        mov     rdx, rcx
        lea     rcx, [edge_regbuf]
        mov     r8d, 520
        mov     rax, rcx
        xchg    rcx, rdx                        ; ExpandEnvironmentStringsW(src, dst, size)
        call    ExpandEnvironmentStringsW
        lea     rcx, [edge_regbuf]
        call    GetFileAttributesW
        cmp     eax, -1
        je      .no
        lea     rcx, [edge_exe]
        lea     rdx, [edge_regbuf]
        call    lstrcpyW
        mov     eax, 1
        jmp     .out
.no:    xor     eax, eax
.out:   EPROC

; rcx = registry sub key under HKLM -> eax = 1 and edge_exe set when its default value names an existing file
PROC edge_try_reg, 4
        mov     loc(0), rcx
        mov     ebx, 0x20119                    ; KEY_READ | KEY_WOW64_64KEY
.view:  mov     rcx, 0x80000002                 ; HKEY_LOCAL_MACHINE
        mov     rdx, loc(0)
        xor     r8d, r8d
        mov     r9d, ebx
        lea     rax, loc(1)
        mov     outarg(5), rax
        call    RegOpenKeyExW
        test    eax, eax
        jnz     .next
        mov     dword [edge_regsz], 1040
        mov     rcx, loc(1)
        xor     edx, edx                        ; default value
        xor     r8d, r8d
        lea     r9, loc(2)                      ; type
        lea     rax, [edge_regbuf]
        mov     outarg(5), rax
        lea     rax, [edge_regsz]
        mov     outarg(6), rax
        call    RegQueryValueExW
        mov     r12d, eax
        mov     rcx, loc(1)
        call    RegCloseKey
        test    r12d, r12d
        jnz     .next
        lea     rcx, [edge_regbuf]
        call    GetFileAttributesW
        cmp     eax, -1
        je      .next
        lea     rcx, [edge_exe]
        lea     rdx, [edge_regbuf]
        call    lstrcpyW
        mov     eax, 1
        jmp     .out
.next:  cmp     ebx, 0x20219                    ; tried the 32-bit view already?
        je      .none
        mov     ebx, 0x20219                    ; KEY_READ | KEY_WOW64_32KEY
        jmp     .view
.none:  xor     eax, eax
.out:   EPROC

; -> eax = 1 when a Chromium-based browser was found (edge_exe holds its path)
PROC edge_find, 0
        mov     rcx, [edge_override]
        test    rcx, rcx
        jz      .search
        cmp     word [rcx], 0
        je      .none                           ; --edge-path "": tests pretend there is no browser
        lea     rcx, [edge_exe]
        mov     rdx, [edge_override]
        call    lstrcpyW
        mov     eax, 1
        jmp     .out
.search:
        lea     rcx, [w_reg_edge]
        call    edge_try_reg
        test    eax, eax
        jnz     .out
        lea     rcx, [w_edge_p1]
        call    edge_try_path
        test    eax, eax
        jnz     .out
        lea     rcx, [w_edge_p2]
        call    edge_try_path
        test    eax, eax
        jnz     .out
        lea     rcx, [w_reg_chrome]                 ; Chrome speaks the same SDK and DRM; fine as a fallback
        call    edge_try_reg
        test    eax, eax
        jnz     .out
        lea     rcx, [w_chrome_p1]
        call    edge_try_path
        test    eax, eax
        jnz     .out
        lea     rcx, [w_chrome_p2]
        call    edge_try_path
        test    eax, eax
        jnz     .out
        lea     rcx, [w_chrome_p3]
        call    edge_try_path
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC

; -> eax = 1 when the helper is running
PROC edge_alive, 2
        mov     rcx, [edge_proc]
        test    rcx, rcx
        jz      .no
        lea     rdx, loc(0)
        call    GetExitCodeProcess
        cmp     dword loc(0), STILL_ACTIVE
        jne     .no
        mov     eax, 1
        jmp     .out
.no:    xor     eax, eax
.out:   EPROC

; Starts the helper (once).  -> eax = 1 when it is running or was launched.   Bufs: command line top 5
PROC edge_launch, 8
        call    edge_alive
        test    eax, eax
        jnz     .ok
        call    edge_stop                       ; clear a dead helper's handles
        call    srv_start
        test    eax, eax
        jnz     .srv
        lea     rcx, [w_err_server]
        xor     edx, edx
        xor     r8d, r8d
        call    ui_banner
        xor     eax, eax
        jmp     .out
.srv:   call    edge_find
        test    eax, eax
        jnz     .found
        lea     rcx, [l_edge_none]
        call    log_msg
        lea     rcx, [w_err_noedge]
        lea     rdx, [w_lbl_getedge]
        mov     r8d, BA_GET_EDGE
        call    ui_banner
        xor     eax, eax
        jmp     .out
.found: ; --- command line (UTF-8 first, then converted)
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [e_q1]
        call    buf_append_z
        lea     rcx, [edge_exe]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(0), rax
        lea     rcx, loc(5)
        mov     rdx, rax
        call    buf_append_z
        mov     rcx, loc(0)
        call    mem_free
        lea     rcx, loc(5)
        lea     rdx, [e_q1]
        call    buf_append_z
        lea     rcx, loc(5)
        lea     rdx, [e_app]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     edx, [srv_bound_port]
        call    buf_append_u64
        lea     rcx, loc(5)
        lea     rdx, [e_player]
        call    buf_append_z
        lea     rcx, loc(5)
        lea     rdx, [srv_secret]
        call    buf_append_z
        lea     rcx, loc(5)
        lea     rdx, [e_udd]
        call    buf_append_z
        lea     rcx, [data_dir]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(0), rax
        lea     rcx, loc(5)
        mov     rdx, rax
        call    buf_append_z
        mov     rcx, loc(0)
        call    mem_free
        lea     rcx, loc(5)
        lea     rdx, [w_edge_dir_u8]
        call    buf_append_z
        lea     rcx, loc(5)
        lea     rdx, [e_flags]
        call    buf_append_z
        cmp     dword [cli_no_shell], 0
        je      .real
        ; tests: do not start a browser; announce what would run so the test can play the part of Edge
        BUFZERO 2
        lea     rcx, loc(2)
        lea     rdx, [e_launch_pre]
        call    buf_append_z
        lea     rcx, loc(2)
        mov     edx, [srv_bound_port]
        call    buf_append_u64
        lea     rcx, loc(2)
        lea     rdx, [e_player]
        call    buf_append_z
        lea     rcx, loc(2)
        lea     rdx, [srv_secret]
        call    buf_append_z
        lea     rcx, loc(2)
        lea     rdx, [s_lf]
        call    buf_append_z
        mov     rcx, loc(2)
        call    out_z
        lea     rcx, loc(2)
        call    buf_free
        lea     rcx, loc(5)
        call    buf_free
        call    GetTickCount64
        mov     [edge_t0], rax
        mov     eax, 1
        jmp     .out
.real:  lea     rcx, [l_edge_launch]
        call    log_msg
        mov     rcx, loc(5)
        mov     rdx, -1
        call    u8_to_w
        mov     loc(0), rax                     ; mutable wide command line
        lea     rcx, loc(5)
        call    buf_free
        ; --- a job object that kills the helper (and its children) when ByteStream ends
        xor     ecx, ecx
        xor     edx, edx
        call    CreateJobObjectW
        mov     [edge_job], rax
        test    rax, rax
        jz      .nojob
        lea     rdi, [edge_jobinfo]
        mov     ecx, 144
        xor     eax, eax
        rep     stosb
        mov     dword [edge_jobinfo+16], 0x2000 ; JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        mov     rcx, [edge_job]
        mov     edx, 9                          ; JobObjectExtendedLimitInformation
        lea     r8, [edge_jobinfo]
        mov     r9d, 144
        call    SetInformationJobObject
.nojob: lea     rdi, [edge_si]
        mov     ecx, 112
        xor     eax, eax
        rep     stosb
        mov     dword [edge_si], 104
        mov     dword [edge_si+60], 1           ; STARTF_USESHOWWINDOW
        mov     word [edge_si+64], 7            ; SW_SHOWMINNOACTIVE: minimised, no focus
        lea     rcx, [edge_exe]
        mov     rdx, loc(0)
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword outarg(5), 0              ; do not inherit handles
        mov     qword outarg(6), 4              ; CREATE_SUSPENDED: join the job before it can spawn children
        mov     qword outarg(7), 0
        mov     qword outarg(8), 0
        lea     rax, [edge_si]
        mov     outarg(9), rax
        lea     rax, [edge_pi]
        mov     outarg(10), rax
        call    CreateProcessW
        mov     r12d, eax
        mov     rcx, loc(0)
        call    mem_free
        test    r12d, r12d
        jnz     .started
        call    GetLastError
        mov     edx, eax
        lea     rcx, [l_edge_fail]
        call    log_num
        lea     rcx, [w_err_pconn]
        xor     edx, edx
        xor     r8d, r8d
        call    ui_banner
        xor     eax, eax
        jmp     .out
.started:
        mov     rax, [edge_pi]
        mov     [edge_proc], rax
        mov     rcx, [edge_job]
        test    rcx, rcx
        jz      .resume
        mov     rdx, [edge_proc]
        call    AssignProcessToJobObject
.resume:
        mov     rcx, [edge_pi+8]
        call    ResumeThread
        mov     rcx, [edge_pi+8]
        call    CloseHandle
        call    GetTickCount64
        mov     [edge_t0], rax
.ok:    mov     eax, 1
.out:   EPROC

section .data
w_edge_dir_u8:  db "\edge", 0
section .text

; Stops the helper and forgets the Connect device.
PROC edge_stop, 0
        mov     rcx, [edge_job]
        test    rcx, rcx
        jz      .noj
        call    CloseHandle                     ; KILL_ON_JOB_CLOSE ends Edge and everything it spawned
        mov     qword [edge_job], 0
.noj:   mov     rcx, [edge_proc]
        test    rcx, rcx
        jz      .out
        mov     edx, 0
        call    TerminateProcess
        mov     rcx, [edge_proc]
        call    CloseHandle
        mov     qword [edge_proc], 0
.out:   mov     dword [sdk_ready], 0
        EPROC

; UI timer: notices a dead helper, gives up on a helper that never connects, stops an idle one
PROC edge_tick, 0
        cmp     qword [edge_proc], 0
        jne     .have
        cmp     qword [play_pending], 0
        je      .out
        cmp     dword [cli_no_shell], 0
        je      .out
        jmp     .waitconn                       ; tests: nobody launches a process, but the connect timeout still applies
.have:  call    edge_alive
        test    eax, eax
        jnz     .running
        mov     rcx, [edge_proc]
        lea     rdx, [edge_pi+16]
        call    GetExitCodeProcess
        lea     rcx, [l_edge_exit]
        mov     edx, [edge_pi+16]
        call    log_num
        call    edge_stop
        mov     dword [np_paused], 1
        jmp     .out
.running:
        cmp     dword [sdk_ready], 0
        jne     .idle
.waitconn:
        cmp     qword [play_pending], 0
        je      .out
        call    GetTickCount64
        sub     rax, [edge_t0]
        cmp     rax, EDGE_CONNECT_MS
        jb      .out
        lea     rcx, [l_edge_timeout]
        call    log_msg
        mov     rcx, [play_pending]
        call    mem_free
        mov     qword [play_pending], 0
        lea     rcx, [w_err_ptimeout]
        xor     edx, edx
        xor     r8d, r8d
        call    ui_banner
        jmp     .out
.idle:  cmp     dword [np_valid], 0
        je      .quiet
        cmp     dword [np_paused], 0
        je      .playing
.quiet: cmp     qword [idle_t0], 0
        jne     .chk
        call    GetTickCount64
        mov     [idle_t0], rax
        jmp     .out
.chk:   call    GetTickCount64
        sub     rax, [idle_t0]
        cmp     rax, EDGE_IDLE_MS
        jb      .out
        lea     rcx, [l_edge_idle]
        call    log_msg
        call    edge_stop
        mov     qword [idle_t0], 0
        jmp     .out
.playing:
        mov     qword [idle_t0], 0
.out:   EPROC

; ---------------------------------------------------------------- commands to the page
; rcx = JSON command
audio_cmd:
        cmp     dword [sdk_ready], 0
        je      .no
        jmp     srv_cmd_push
.no:    ret

PROC real_toggle, 0
        cmp     dword [sdk_ready], 0
        je      .out
        call    np_position                     ; optimistic: keep the clock right until the page confirms
        mov     [np_pos], eax
        call    GetTickCount64
        mov     [np_tick], rax
        xor     dword [np_paused], 1
        lea     rcx, [c_toggle]
        call    audio_cmd
.out:   EPROC

PROC real_next, 0
        lea     rcx, [c_next]
        call    audio_cmd
        EPROC

PROC real_prev, 0
        lea     rcx, [c_prev]
        call    audio_cmd
        EPROC

; ecx = milliseconds.   Bufs: command top 2
PROC real_seek, 4
        mov     [np_pos], ecx
        mov     loc(3), rcx
        call    GetTickCount64
        mov     [np_tick], rax
        cmp     dword [sdk_ready], 0
        je      .out
        BUFZERO 2
        lea     rcx, loc(2)
        lea     rdx, [c_seek_pre]
        call    buf_append_z
        lea     rcx, loc(2)
        mov     edx, dword loc(3)
        call    buf_append_u64
        lea     rcx, loc(2)
        lea     rdx, [c_close]
        call    buf_append_z
        mov     rcx, loc(2)
        call    srv_cmd_push
        lea     rcx, loc(2)
        call    buf_free
.out:   EPROC

; ecx = 0..100
PROC real_set_volume, 4
        mov     dword loc(3), ecx
        cmp     dword [sdk_ready], 0
        je      .out
        BUFZERO 2
        lea     rcx, loc(2)
        lea     rdx, [c_vol_pre]
        call    buf_append_z
        lea     rcx, loc(2)
        mov     edx, dword loc(3)
        call    buf_append_u64
        lea     rcx, loc(2)
        lea     rdx, [c_close]
        call    buf_append_z
        mov     rcx, loc(2)
        call    srv_cmd_push
        lea     rcx, loc(2)
        call    buf_free
.out:   EPROC

; Shuffle and repeat are Web API calls aimed at our own device (the SDK reports the result back as a state event).
; ecx = 0/1.   Bufs: URL top 5
PROC real_shuffle, 6
        mov     dword loc(0), ecx
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [p_shuffle]
        call    api_url
        lea     rdx, [b_false]
        cmp     dword loc(0), 0
        je      .go
        lea     rdx, [b_true]
.go:    lea     rcx, loc(5)
        call    buf_append_z
        lea     rcx, loc(5)
        call    audio_put_device
        EPROC

; ecx = 0 off, 1 all (context), 2 one (track).   Bufs: URL top 5
PROC real_repeat, 6
        mov     dword loc(0), ecx
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [p_repeat]
        call    api_url
        lea     rdx, [b_off]
        cmp     dword loc(0), 1
        jne     .not1
        lea     rdx, [b_context]
.not1:  cmp     dword loc(0), 2
        jne     .go
        lea     rdx, [b_track]
.go:    lea     rcx, loc(5)
        call    buf_append_z
        lea     rcx, loc(5)
        call    audio_put_device
        EPROC

; rcx = Buf* holding ".../player/x?state=y": adds "&device_id=<ours>", sends it as a body-less PUT, frees the Buf
PROC audio_put_device, 2
        mov     loc(0), rcx
        lea     rdx, [p_devarg]
        call    buf_append_z
        mov     rcx, loc(0)
        lea     rdx, [sdk_device]
        call    buf_append_z
        xor     ecx, ecx
        xor     edx, edx                        ; TAG_NONE: nothing to do with the answer
        xor     r8d, r8d
        lea     r9, [w_put]
        mov     rax, loc(0)
        mov     rax, [rax+BUF_PTR]
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        mov     qword outarg(7), 0
        mov     qword outarg(8), 0
        call    net_submit
        mov     rcx, loc(0)
        call    buf_free
        EPROC

; ---------------------------------------------------------------- "play this"
; rcx = heap JSON body for PUT /me/player/play (ownership passes here)
PROC audio_start, 2
        mov     loc(0), rcx
        lea     rcx, [l_play_req]
        call    log_msg
        cmp     dword [sdk_ready], 0
        je      .wait
        mov     rcx, loc(0)
        call    audio_do_play
        jmp     .out
.wait:  mov     rcx, [play_pending]
        call    mem_free
        mov     rax, loc(0)
        mov     [play_pending], rax
        call    edge_launch
        test    eax, eax
        jnz     .started
        mov     rcx, [play_pending]
        call    mem_free
        mov     qword [play_pending], 0
        jmp     .out
.started:
        lea     rcx, [w_msg_starting]
        call    ui_toast
.out:   EPROC

; rcx = heap JSON body: sends it to the Connect device (frees it).   Bufs: url top 5
PROC audio_do_play, 6
        mov     loc(0), rcx
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [p_play]
        call    api_url
        lea     rcx, loc(5)
        lea     rdx, [sdk_device]
        call    buf_append_z
        xor     ecx, ecx
        mov     edx, TAG_PLAY
        xor     r8d, r8d
        lea     r9, [w_put]
        mov     rax, loc(5)
        mov     outarg(5), rax
        mov     rax, loc(0)
        mov     outarg(6), rax
        mov     qword outarg(7), JF_JSON
        mov     qword outarg(8), 0
        call    net_submit
        lea     rcx, loc(5)
        call    buf_free
        mov     rcx, loc(0)
        call    mem_free
        EPROC

; TAG_PLAY: the Web API answered the play request
PROC h_play, 4
        mov     rsi, rcx
        mov     loc(0), rcx
        mov     eax, [rsi+JB_STATUS]
        cmp     eax, 200
        je      .ok
        cmp     eax, 202
        je      .ok
        cmp     eax, 204
        je      .ok
        lea     rcx, [l_play_fail]
        mov     edx, eax
        call    log_num
        mov     rsi, loc(0)
        mov     eax, [rsi+JB_STATUS]
        cmp     eax, 403
        je      .forbidden
        cmp     eax, 404
        je      .device
        cmp     eax, 0
        je      .offline
        lea     rcx, [w_msg_playfail]
        call    ui_toast
        jmp     .out
.forbidden:
        mov     rcx, [rsi+JB_RESP]
        lea     rdx, [k_err_reason]
        call    jpu
        mov     loc(1), rax
        mov     rcx, rax
        lea     rdx, [s_premium_req]
        call    u8_eq
        mov     r12d, eax
        mov     rcx, loc(1)
        call    mem_free
        lea     rcx, [w_err_premium]
        test    r12d, r12d
        jnz     .banner
        lea     rcx, [w_msg_playfail]
        call    ui_toast
        jmp     .out
.device:
        mov     dword [sdk_ready], 0            ; the device we knew is gone: wait for a fresh 'ready'
        lea     rcx, [w_err_pdevice]
        jmp     .banner
.offline:
        lea     rcx, [w_err_offline]
.banner:
        xor     edx, edx
        xor     r8d, r8d
        call    ui_banner
        jmp     .out
.ok:    lea     rcx, [l_play_ok]
        call    log_msg
        mov     ecx, 1200
        call    queue_mark
.out:   EPROC

section .data
ZSTR s_premium_req, "PREMIUM_REQUIRED"
section .text

; Appends `"uri"` JSON-quoted unless the URI is empty, a local file, or holds characters that would need escaping.
; rcx = Buf*, rdx = uri (may be 0), r8d = 1 to put a comma first -> eax = 1 when it was added
PROC body_add_uri, 3
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        test    rdx, rdx
        jz      .skip
        cmp     byte [rdx], 0
        je      .skip
        mov     rcx, rdx
        lea     rdx, [u_local]
        call    u8_starts
        test    eax, eax
        jnz     .skip
        mov     rsi, loc(1)
.chk:   mov     al, [rsi]
        test    al, al
        jz      .clean
        cmp     al, '"'
        je      .skip
        cmp     al, '\'
        je      .skip
        cmp     al, 32
        jb      .skip
        inc     rsi
        jmp     .chk
.clean: cmp     dword loc(2), 0
        je      .nocomma
        mov     rcx, loc(0)
        lea     rdx, [b_comma]
        call    buf_append_z
.nocomma:
        mov     rcx, loc(0)
        lea     rdx, [b_quote]
        call    buf_append_z
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        call    buf_append_z
        mov     rcx, loc(0)
        lea     rdx, [b_quote]
        call    buf_append_z
        mov     eax, 1
        jmp     .out
.skip:  xor     eax, eax
.out:   EPROC

; rcx = context URI (UTF-8: album, playlist or artist): plays it from the start on our device.   Bufs: body top 5
PROC real_play_context, 6
        test    rcx, rcx
        jz      .out
        cmp     byte [rcx], 0
        je      .out
        mov     loc(0), rcx
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [b_ctx_pre]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     rdx, loc(0)
        call    buf_append_z
        lea     rcx, loc(5)
        lea     rdx, [b_ctx_close]
        call    buf_append_z
        mov     rcx, loc(5)
        mov     qword loc(5), 0
        call    audio_start
.out:   EPROC

; The Play entry point used by every list: rcx = List* of Track, edx = index of the track to start.
; A playlist or album page plays its context (Spotify keeps the order, shuffle and length); anything else sends
; up to 100 track URIs starting at the chosen row.   Locals: 0 list, 1 index, 2 track, 3 body ptr, 4 added;  Buf top 8
PROC real_play_list, 10
        mov     loc(0), rcx
        mov     loc(1), rdx
        cmp     rdx, [rcx+LS_COUNT]
        jae     .out                            ; the list is empty or still loading
        mov     rax, rdx
        imul    rax, TR_SIZE
        add     rax, [rcx+LS_PTR]
        mov     loc(2), rax
        test    dword [rax+TR_FLAGS], TF_UNPLAYABLE
        jz      .playable
        lea     rcx, [w_msg_unavailable]        ; a greyed-out row: say so instead of failing at Spotify
        call    ui_toast
        jmp     .out
.playable:
        BUFZERO 8
        lea     rax, [lst_detail]
        cmp     rcx, rax
        jne     .uris
        mov     rax, [det_uri]
        test    rax, rax
        jz      .uris
        cmp     byte [rax], 0
        je      .uris
        mov     rax, loc(2)
        mov     rdx, [rax+TR_URI]
        test    rdx, rdx
        jz      .uris
        cmp     byte [rdx], 0
        je      .uris
        lea     rcx, loc(8)
        lea     rdx, [b_ctx_pre]
        call    buf_append_z
        lea     rcx, loc(8)
        mov     rdx, [det_uri]
        call    buf_append_z
        lea     rcx, loc(8)
        lea     rdx, [b_ctx_mid]
        call    buf_append_z
        mov     rax, loc(2)
        lea     rcx, loc(8)
        mov     rdx, [rax+TR_URI]
        call    buf_append_z
        lea     rcx, loc(8)
        lea     rdx, [b_ctx_end]
        call    buf_append_z
        jmp     .send
.uris:  lea     rcx, loc(8)
        lea     rdx, [b_uris_pre]
        call    buf_append_z
        mov     dword loc(4), 0
        mov     rbx, loc(1)
.u:     mov     rax, loc(0)
        cmp     rbx, [rax+LS_COUNT]
        jae     .udone
        mov     rax, loc(1)
        add     rax, 100
        cmp     rbx, rax
        jae     .udone
        mov     rax, rbx
        imul    rax, TR_SIZE
        mov     rcx, loc(0)
        add     rax, [rcx+LS_PTR]
        test    dword [rax+TR_FLAGS], TF_UNPLAYABLE
        jnz     .skipu                          ; region-locked / removed / local tracks cannot go in the list
        mov     rdx, [rax+TR_URI]
        lea     rcx, loc(8)
        mov     r8d, dword loc(4)
        call    body_add_uri
        add     dword loc(4), eax
.skipu: inc     rbx
        jmp     .u
.udone: cmp     dword loc(4), 0
        jne     .close
        lea     rcx, loc(8)
        call    buf_free
        lea     rcx, [w_msg_unplayable]
        call    ui_toast
        jmp     .out
.close: lea     rcx, loc(8)
        lea     rdx, [b_uris_end]
        call    buf_append_z
.send:  mov     rcx, loc(2)                     ; show the track at once; the page's state events take over
        call    np_set_track
        mov     dword [np_paused], 0
        mov     rcx, loc(8)                     ; hand the body's storage to audio_start (it frees it)
        mov     qword loc(8), 0
        call    audio_start
.out:   EPROC

; Settings > Diagnostics > "Test audio": plays one well-known track
PROC audio_test, 6
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [b_uris_pre]
        call    buf_append_z
        lea     rcx, loc(5)
        lea     rdx, [u_test_track]
        xor     r8d, r8d
        call    body_add_uri
        lea     rcx, loc(5)
        lea     rdx, [b_uris_end]
        call    buf_append_z
        mov     rcx, loc(5)
        mov     qword loc(5), 0
        call    audio_start
        EPROC

; ---------------------------------------------------------------- messages from the page (UI thread)
; rcx = heap JSON (NUL-terminated copy), rdx = length.  Takes ownership.   Locals: 0 json, 1 type, 2 scratch, 3 scratch
PROC bridge_event, 6
        mov     loc(0), rcx
        lea     rdx, [k_type]
        call    jpu
        mov     loc(1), rax
        mov     rcx, rax
        lea     rdx, [ty_state]
        call    u8_eq
        test    eax, eax
        jnz     .state
        mov     rcx, loc(1)
        lea     rdx, [ty_ready]
        call    u8_eq
        test    eax, eax
        jnz     .ready
        mov     rcx, loc(1)
        lea     rdx, [ty_notready]
        call    u8_eq
        test    eax, eax
        jnz     .notready
        mov     rcx, loc(1)
        lea     rdx, [ty_error]
        call    u8_eq
        test    eax, eax
        jnz     .error
        mov     rcx, loc(1)
        lea     rdx, [ty_hello]
        call    u8_eq
        test    eax, eax
        jz      .quit
        lea     rcx, [l_hello]
        call    log_msg
        jmp     .free
.quit:  cmp     dword [cli_hold], 0             ; tests only: the fake page drives a --hold run
        je      .free
        mov     rcx, loc(1)
        lea     rdx, [ty_go]
        call    u8_eq
        test    eax, eax
        jz      .notgo
        call    run_late_act
        jmp     .free
.notgo: mov     rcx, loc(1)
        lea     rdx, [ty_quit]
        call    u8_eq
        test    eax, eax
        jz      .free
        call    dump_state
        xor     ecx, ecx
        call    ExitProcess
.state: mov     rcx, loc(0)
        call    audio_on_state
        jmp     .free
.ready: mov     rcx, loc(0)
        lea     rdx, [k_device]
        call    jpu
        mov     loc(2), rax
        lea     rdi, [sdk_device]
        mov     rsi, rax
        xor     ecx, ecx
.dv:    cmp     ecx, 90
        jae     .dvt
        mov     al, [rsi+rcx]
        test    al, al
        jz      .dvt
        mov     [rdi+rcx], al
        inc     ecx
        jmp     .dv
.dvt:   mov     byte [rdi+rcx], 0
        mov     rcx, loc(2)
        call    mem_free
        mov     dword [sdk_ready], 1
        mov     qword [idle_t0], 0
        lea     rcx, [l_ready]
        lea     rdx, [sdk_device]
        call    log_msg2
        mov     ecx, [np_vol]                   ; the page starts at its own default: push ours
        call    real_set_volume
        mov     rcx, [play_pending]
        test    rcx, rcx
        jz      .free
        mov     qword [play_pending], 0
        call    audio_do_play
        jmp     .free
.notready:
        mov     dword [sdk_ready], 0
        lea     rcx, [l_notready]
        call    log_msg
        jmp     .free
.error: mov     rcx, loc(0)
        call    audio_on_error
.free:  mov     rcx, loc(1)
        call    mem_free
        mov     rcx, loc(0)
        call    mem_free
        EPROC

; rcx = prefix (UTF-8), rdx = suffix (UTF-8): one log line "<prefix><suffix>"
PROC log_msg2, 6
        mov     loc(0), rdx
        BUFZERO 5
        mov     rdx, rcx
        lea     rcx, loc(5)
        call    buf_append_z
        lea     rcx, loc(5)
        mov     rdx, loc(0)
        call    buf_append_z
        mov     rcx, loc(5)
        call    log_msg
        lea     rcx, loc(5)
        call    buf_free
        EPROC

; rcx = JSON of {"type":"error","kind":..}
PROC audio_on_error, 4
        lea     rdx, [k_kind]
        call    jpu
        mov     loc(0), rax
        lea     rcx, [l_sdk_error]
        mov     rdx, rax
        call    log_msg2
        mov     rcx, loc(0)
        lea     rdx, [er_account]
        call    u8_eq
        lea     rcx, [w_err_premium]
        test    eax, eax
        jnz     .banner
        mov     rcx, loc(0)
        lea     rdx, [er_auth]
        call    u8_eq
        lea     rcx, [w_err_pauth]
        test    eax, eax
        jnz     .banner
        mov     rcx, loc(0)
        lea     rdx, [er_init]
        call    u8_eq
        lea     rcx, [w_err_pinit]
        test    eax, eax
        jnz     .banner
        mov     rcx, loc(0)
        lea     rdx, [er_playback]
        call    u8_eq
        test    eax, eax
        jnz     .toast
        mov     rcx, loc(0)
        lea     rdx, [er_autoplay]
        call    u8_eq
        test    eax, eax
        jnz     .toastauto
        lea     rcx, [w_err_pconn]              ; token / connect_failed / sdk_load_failed
.banner:
        xor     edx, edx
        xor     r8d, r8d
        call    ui_banner
        mov     rcx, [play_pending]
        call    mem_free
        mov     qword [play_pending], 0
        jmp     .out
.toast: lea     rcx, [w_msg_playfail]
        call    ui_toast
        jmp     .out
.toastauto:
        lea     rcx, [w_msg_autoplay]
        call    ui_toast
.out:   mov     rcx, loc(0)
        call    mem_free
        EPROC

; rcx = JSON of {"type":"state",...}: updates the now-playing state.   Locals: 0 json, 1 uri, 2 scratch, 3 count, 4 i
PROC audio_on_state, 8
        mov     loc(0), rcx
        lea     rdx, [a_empty]
        call    json_get
        test    rax, rax
        jz      .full
        mov     dword [np_valid], 0             ; nothing is loaded in the player any more
        jmp     .out
.full:  mov     rcx, loc(0)
        lea     rdx, [k_t_uri]
        call    jpu
        mov     loc(1), rax
        mov     rcx, [np_uri]
        test    rcx, rcx
        jz      .newtrack
        mov     rdx, loc(1)
        call    u8_eq
        test    eax, eax
        jnz     .same
.newtrack:
        call    np_clear
        mov     rcx, loc(0)
        lea     rdx, [k_t_name]
        call    jpw
        mov     [np_title], rax
        mov     rcx, loc(0)
        lea     rdx, [k_t_album]
        call    jpw
        mov     [np_album], rax
        mov     rcx, loc(1)
        call    u8_dup
        mov     [np_uri], rax
        mov     rcx, loc(0)
        call    audio_artists
        mov     [np_artist], rax
        ; covers: first image is the largest, last the smallest
        mov     rcx, loc(0)
        lea     rdx, [k_t_images]
        call    json_path
        mov     loc(2), rax
        mov     rcx, rax
        call    json_count
        mov     loc(3), rax
        test    rax, rax
        jz      .noimg
        mov     rcx, loc(2)
        xor     edx, edx
        call    json_at
        mov     rcx, rax
        call    json_str_u8
        mov     [np_img_l], rax
        mov     rcx, loc(2)
        mov     rdx, loc(3)
        dec     rdx
        call    json_at
        mov     rcx, rax
        call    json_str_u8
        mov     [np_img_s], rax
.noimg: inc     dword [np_gen]
        mov     ecx, 700                        ; a new song: what is up next may have changed
        call    queue_mark
        mov     rcx, [np_title]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(2), rax
        lea     rcx, [l_track]
        mov     rdx, rax
        call    log_msg2
        mov     rcx, loc(2)
        call    mem_free
.same:  mov     rcx, loc(1)
        call    mem_free
        mov     rcx, loc(0)
        lea     rdx, [k_paused]
        call    json_get
        mov     rcx, rax
        call    json_bool
        mov     [np_paused], eax
        mov     rcx, loc(0)
        lea     rdx, [k_position]
        call    jpi
        mov     [np_pos], eax
        mov     rcx, loc(0)
        lea     rdx, [k_duration]
        call    jpi
        mov     [np_dur], eax
        mov     rcx, loc(0)
        lea     rdx, [k_shuffle]
        call    json_get
        mov     rcx, rax
        call    json_bool
        mov     [np_shuffle], eax
        mov     rcx, loc(0)
        lea     rdx, [k_repeat]
        call    jpi
        cmp     eax, 2
        jbe     .rep
        xor     eax, eax
.rep:   mov     [np_repeat], eax
        call    GetTickCount64
        mov     [np_tick], rax
        mov     dword [np_valid], 1
        mov     qword [idle_t0], 0
.out:   EPROC

; rcx = JSON with track.artists = ["a","b"] -> rax = heap UTF-16 "a, b"
PROC audio_artists, 8
        lea     rdx, [k_t_artists]
        call    json_path
        mov     loc(0), rax
        BUFZERO 5
        mov     rcx, rax
        call    json_count
        mov     r12, rax
        xor     ebx, ebx
.l:     cmp     rbx, r12
        jae     .done
        mov     rcx, loc(0)
        mov     rdx, rbx
        call    json_at
        mov     rcx, rax
        call    json_str_u8
        mov     rsi, rax
        test    rbx, rbx
        jz      .name
        lea     rcx, loc(5)
        lea     rdx, [s_comma_sp]
        call    buf_append_z
.name:  lea     rcx, loc(5)
        mov     rdx, rsi
        call    buf_append_z
        mov     rcx, rsi
        call    mem_free
        inc     rbx
        jmp     .l
.done:  mov     rcx, loc(5)
        test    rcx, rcx
        jnz     .have
        lea     rcx, [a_empty+5]                ; (an empty string: the NUL after "empty")
.have:  mov     rdx, -1
        call    u8_to_w
        mov     rsi, rax
        lea     rcx, loc(5)
        call    buf_free
        mov     rax, rsi
        EPROC
