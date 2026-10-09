; engine.asm - the lightweight playback engine: go-librespot as a small helper program instead of a browser.
;
; go-librespot (GPL-3.0, https://github.com/devgianlu/go-librespot) is a separate program that sits next to
; bytestream.exe.  It registers a Spotify Connect device called "ByteStream" and plays through Windows' own audio
; (WASAPI).  Unlike the Edge engine in audio.asm it needs no browser, so the whole player stays far below the
; browser's memory use.  Note that it speaks Spotify's own protocol, which Spotify's terms do not allow third-party
; programs to do; the README says so, and the Edge engine remains available in Settings.
;
; How the pieces fit (everything here runs on the UI thread; the HTTP calls run on their own worker queue):
;
;   hp_launch      starts go-librespot hidden, in the same kill-on-close job object the Edge helper uses, with its
;                  local control API on a random 127.0.0.1 port; its console output goes to librespot.log
;   hp_tick        every 250 ms: asks GET /status (1 s while playing, 2.5 s otherwise) and, while the helper has no
;                  Spotify session yet, GET /auth/code for the one-time pairing code
;   hp_on_status   /status -> the same now-playing state the Edge page's "state" events feed
;   hp_cmd/seek/volume   play/pause, next, previous, seek and volume go to the local API (they use no Spotify quota)
;
; "Play this list", shuffle and repeat still go through the Spotify Web API, aimed at the helper's device id: to
; Spotify the helper is just another Connect device, exactly like the Edge page's device was.

extern GetModuleFileNameW, CreateFileW, MoveFileExW, CreateDirectoryW, DeleteFileW, GetFileAttributesW

%define HP_POLL_START 700               ; ms between status polls while the helper is starting up
%define HP_POLL_PLAY  1000
%define HP_POLL_IDLE  2500
%define HP_HOLD_MS    5000              ; after "play this", ignore the old track the helper still reports

section .bss
hp_mode:        resd 1                  ; 1 = this run plays through the helper (decided when it is launched)
hp_started:     resd 1                  ; launched (also in test runs, where the test plays the helper)
hp_busy:        resd 1                  ; a /status request is in flight
hp_auth_busy:   resd 1
hp_auth_shown:  resd 1                  ; the pairing banner has been raised
hp_port:        resd 1
cli_engine:     resd 1                  ; tests: --engine 1 = helper, 2 = Edge
set_engine:     resd 1                  ; Settings: 0 = lightweight helper when it is installed, 1 = Edge (saved)
                align 8
hp_next_poll:   resq 1
hp_next_auth:   resq 1
hp_hold_until:  resq 1                  ; GetTickCount64 value (0 = not holding)
hp_hold_uri:    resq 1                  ; owned UTF-8: the track that was playing when "play this" was sent
hp_last_uri:    resq 1                  ; owned UTF-8: the track of the last status that was accepted
hp_pair_url:    resq 1                  ; owned UTF-8
hp_pair_code:   resq 1                  ; owned UTF-8
hp_sa:          resb 24                 ; SECURITY_ATTRIBUTES (inheritable handle for the log file)
                align 8
hp_exe:         resw 540
hp_cfg:         resw 540
hp_log:         resw 540
hp_log_old:     resw 540

section .data
WSTR w_hp_name, "go-librespot.exe"
WSTR w_hp_cfgname, `\\librespot`
WSTR w_hp_logname, `\\librespot.log`
WSTR w_hp_logold, `\\librespot.old.log`
WSTR w_hp_state, `\\librespot\\state.json`
WSTR w_lbl_openpage, "Open page"
WSTR w_err_hpdied, "ByteStream's audio helper stopped unexpectedly. Press play to start it again; details are in librespot.log (Settings > Diagnostics > Open log folder)."
WSTR w_err_hpspawn, "ByteStream's audio helper could not be started. Reinstall ByteStream (go-librespot.exe must sit next to bytestream.exe) or switch to the Edge engine in Settings."
ZSTR hp_q, `"`
ZSTR hp_cfgarg, ` --config_dir "`
ZSTR hp_flags, `" -c device_name=ByteStream -c device_type=computer -c audio_backend=wasapi -c credentials.type=device_auth -c zeroconf_enabled=false -c log_level=info -c bitrate=320 -c volume_steps=100 -c server.enabled=true -c server.address=127.0.0.1 -c server.image_size=large -c server.port=`
ZSTR hp_initvol, ` -c initial_volume=`
ZSTR hp_p_status, "/status"
ZSTR hp_p_authcode, "/auth/code"
ZSTR hp_p_playpause, "/player/playpause"
ZSTR hp_p_next, "/player/next"
ZSTR hp_p_prev, "/player/prev"
ZSTR hp_p_seek, "/player/seek"
ZSTR hp_p_volume, "/player/volume"
ZSTR hp_b_empty, "{}"
ZSTR hp_j_pos, `{"position":`
ZSTR hp_j_vol, `{"volume":`
ZSTR k_hp_devid, "device_id"
ZSTR k_hp_stopped, "stopped"
ZSTR k_hp_album, "track.album_name"
ZSTR k_hp_artists, "track.artist_names"
ZSTR k_hp_cover, "track.album_cover_url"
ZSTR k_hp_pos, "track.position"
ZSTR k_hp_dur, "track.duration"
ZSTR k_hp_shuffle, "shuffle_context"
ZSTR k_hp_rep_ctx, "repeat_context"
ZSTR k_hp_rep_trk, "repeat_track"
ZSTR k_hp_code, "code"
ZSTR k_hp_url, "url"
ZSTR l_hp_launch, "audio: starting go-librespot, API port "
ZSTR l_hp_ready, "audio: go-librespot ready, device "
ZSTR l_hp_nosession, "audio: go-librespot has no Spotify session (waiting for pairing or reconnecting)"
ZSTR l_hp_pair, "audio: pairing code issued, waiting for the user"
ZSTR l_hp_fail, "audio: could not start go-librespot, error "
ZSTR l_hp_nofile, "audio: go-librespot.exe not found next to bytestream.exe"
ZSTR e_hp_launch_pre, "helper-launch:port="
ZSTR e_hp_msg_pre, "One-time step: link ByteStream's player to your Spotify account. Open the page and enter the code "
ZSTR e_hp_msg_post, "."

section .text

; ---------------------------------------------------------------- finding and choosing
; -> eax = 1 when go-librespot.exe sits next to bytestream.exe (hp_exe then holds its path)
PROC hp_find, 0
        xor     ecx, ecx
        lea     rdx, [hp_exe]
        mov     r8d, 520
        call    GetModuleFileNameW
        test    eax, eax
        jz      .no
        lea     rsi, [hp_exe]
        mov     ecx, eax                        ; length in characters
.l:     test    ecx, ecx
        jz      .no
        cmp     word [rsi+rcx*2-2], 0x5C        ; backslash
        je      .cut
        dec     ecx
        jmp     .l
.cut:   lea     rcx, [rsi+rcx*2]
        lea     rdx, [w_hp_name]
        call    lstrcpyW
        lea     rcx, [hp_exe]
        call    GetFileAttributesW
        cmp     eax, -1
        je      .no
        mov     eax, 1
        jmp     .out
.no:    xor     eax, eax
.out:   EPROC

; Which engine the next launch uses -> eax = 1 helper, 0 Edge
PROC hp_pick, 0
        mov     eax, [cli_engine]
        cmp     eax, 1
        je      .yes
        cmp     eax, 2
        je      .no
        cmp     dword [set_engine], 0
        jne     .no
        call    hp_find
        jmp     .out
.yes:   mov     eax, 1
        jmp     .out
.no:    xor     eax, eax
.out:   mov     [hp_mode], eax
        EPROC

; The one entry point audio_start uses: starts whichever engine is chosen (once).  -> eax = 1 when running/launched
PROC hp_launch_any, 0
        call    edge_alive
        test    eax, eax
        jnz     .running
        cmp     dword [hp_started], 0           ; (test runs have no process: "started" stands in for it)
        jne     .running
        call    hp_pick
        test    eax, eax
        jz      .edge
        call    hp_launch
        jmp     .out
.edge:  call    edge_launch
        jmp     .out
.running:
        mov     eax, 1
.out:   EPROC

; ---------------------------------------------------------------- launching
; Starts go-librespot hidden.  -> eax = 1 when it is running or was launched.   Locals: 0 scratch, 1 log handle;  Bufs: command line top 5
PROC hp_launch, 8
        call    edge_stop                       ; forget a dead helper's handles
        lea     rcx, loc(0)
        mov     edx, 4
        call    rand_bytes
        mov     eax, dword loc(0)
        xor     edx, edx
        mov     ecx, 40000
        div     ecx
        add     edx, 20000
        mov     [hp_port], edx                  ; a random port in 20000..59999: not guessable by a web page
        mov     dword [hp_busy], 0
        mov     dword [hp_auth_busy], 0
        mov     dword [hp_auth_shown], 0
        mov     qword [hp_next_poll], 0
        mov     qword [hp_next_auth], 0
        mov     qword [hp_hold_until], 0
        cmp     dword [cli_no_shell], 0
        jne     .test
        ; --- the program must be there
        call    hp_find
        test    eax, eax
        jnz     .have
        lea     rcx, [l_hp_nofile]
        call    log_msg
        lea     rcx, [w_err_hpspawn]
        xor     edx, edx
        xor     r8d, r8d
        call    ui_banner
        xor     eax, eax
        jmp     .out
.have:  ; --- paths: <data>\librespot (its config + saved login), <data>\librespot.log (this run), .old.log (the run before)
        lea     rcx, [hp_cfg]
        lea     rdx, [data_dir]
        call    lstrcpyW
        lea     rcx, [hp_cfg]
        lea     rdx, [w_hp_cfgname]
        call    lstrcatW
        lea     rcx, [hp_cfg]
        xor     edx, edx
        call    CreateDirectoryW
        lea     rcx, [hp_log]
        lea     rdx, [data_dir]
        call    lstrcpyW
        lea     rcx, [hp_log]
        lea     rdx, [w_hp_logname]
        call    lstrcatW
        lea     rcx, [hp_log_old]
        lea     rdx, [data_dir]
        call    lstrcpyW
        lea     rcx, [hp_log_old]
        lea     rdx, [w_hp_logold]
        call    lstrcatW
        lea     rcx, [hp_log]
        lea     rdx, [hp_log_old]
        mov     r8d, 1                          ; MOVEFILE_REPLACE_EXISTING
        call    MoveFileExW
.cmd:   ; --- command line (UTF-8 first, then converted)
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [hp_q]
        call    buf_append_z
        lea     rcx, [hp_exe]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(0), rax
        lea     rcx, loc(5)
        mov     rdx, rax
        call    buf_append_z
        mov     rcx, loc(0)
        call    mem_free
        lea     rcx, loc(5)
        lea     rdx, [hp_cfgarg]
        call    buf_append_z
        lea     rcx, [hp_cfg]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(0), rax
        lea     rcx, loc(5)
        mov     rdx, rax
        call    buf_append_z
        mov     rcx, loc(0)
        call    mem_free
        lea     rcx, loc(5)
        lea     rdx, [hp_flags]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     edx, [hp_port]
        call    buf_append_u64
        lea     rcx, loc(5)
        lea     rdx, [hp_initvol]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     edx, [np_vol]
        call    buf_append_u64
        lea     rcx, [l_hp_launch]
        mov     edx, [hp_port]
        call    log_num
        mov     rcx, loc(5)
        mov     rdx, -1
        call    u8_to_w
        mov     loc(0), rax                     ; mutable wide command line
        lea     rcx, loc(5)
        call    buf_free
        ; --- its output goes to librespot.log (an inheritable handle)
        lea     rdi, [hp_sa]
        mov     dword [rdi], 24
        mov     qword [rdi+8], 0
        mov     dword [rdi+16], 1               ; bInheritHandle
        lea     rcx, [hp_log]
        mov     edx, 0x40000000                 ; GENERIC_WRITE
        mov     r8d, 3                          ; share read + write
        lea     r9, [hp_sa]
        mov     qword outarg(5), 2              ; CREATE_ALWAYS
        mov     qword outarg(6), 0x80
        mov     qword outarg(7), 0
        call    CreateFileW
        mov     loc(1), rax
        ; --- a job object that kills the helper with ByteStream (shared with the Edge engine)
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
        mov     dword [edge_si+60], 0x101       ; STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES
        mov     word [edge_si+64], 0            ; SW_HIDE
        mov     rax, loc(1)
        cmp     rax, -1
        jne     .h
        xor     eax, eax
.h:     mov     [edge_si+88], rax               ; hStdOutput
        mov     [edge_si+96], rax               ; hStdError
        lea     rcx, [hp_exe]
        mov     rdx, loc(0)
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword outarg(5), 1              ; inherit the log handle
        mov     qword outarg(6), 0x08000004     ; CREATE_NO_WINDOW | CREATE_SUSPENDED (join the job before it can spawn anything)
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
        mov     rcx, loc(1)
        cmp     rcx, -1
        je      .nolog
        test    rcx, rcx
        jz      .nolog
        call    CloseHandle                     ; the child holds its own copy
.nolog: test    r12d, r12d
        jnz     .started
        call    GetLastError
        mov     edx, eax
        lea     rcx, [l_hp_fail]
        call    log_num
        lea     rcx, [w_err_hpspawn]
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
        mov     dword [hp_started], 1
        mov     eax, 1
        jmp     .out
.test:  ; tests: nobody starts a program; announce the port so the test can play the helper's part.  The loopback
        ; server (which the helper engine itself does not need) gives --hold runs their "go"/"quit" control channel.
        call    srv_start
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [e_hp_launch_pre]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     edx, [hp_port]
        call    buf_append_u64
        lea     rcx, loc(5)
        lea     rdx, [s_lf]
        call    buf_append_z
        mov     rcx, loc(5)
        call    out_z
        lea     rcx, loc(5)
        call    buf_free
        call    GetTickCount64
        mov     [edge_t0], rax
        mov     dword [hp_started], 1
        mov     eax, 1
.out:   EPROC

; Signing out forgets the helper's saved Spotify login too (otherwise the next account would play on the old one's device)
PROC hp_forget_login, 2
        lea     rcx, [hp_cfg]
        lea     rdx, [data_dir]
        call    lstrcpyW
        lea     rcx, [hp_cfg]
        lea     rdx, [w_hp_state]
        call    lstrcatW
        lea     rcx, [hp_cfg]
        call    DeleteFileW
        EPROC

; ---------------------------------------------------------------- calls to the helper's local API
; rcx = Buf* (reset), rdx = path (UTF-8, starts with '/')  ->  "http://127.0.0.1:<port><path>"
PROC hp_url, 1
        mov     loc(0), rdx
        mov     rbx, rcx
        call    buf_reset
        mov     rcx, rbx
        lea     rdx, [s_redirect_pre]
        call    buf_append_z
        mov     rcx, rbx
        mov     edx, [hp_port]
        call    buf_append_u64
        mov     rcx, rbx
        mov     rdx, loc(0)
        call    buf_append_z
        EPROC

; rcx = path, rdx = JSON body (UTF-8, copied): a POST nobody waits for.   Locals: 0 body;  Bufs: url top 5
PROC hp_post, 6
        mov     loc(0), rdx
        BUFZERO 5
        mov     rdx, rcx
        lea     rcx, loc(5)
        call    hp_url
        mov     ecx, NQ_LOCAL
        xor     edx, edx                        ; TAG_NONE
        xor     r8d, r8d
        lea     r9, [w_post]
        mov     rax, loc(5)
        mov     outarg(5), rax
        mov     rax, loc(0)
        mov     outarg(6), rax
        mov     qword outarg(7), JF_JSON | JF_NOAUTH
        mov     qword outarg(8), 0
        call    net_submit
        lea     rcx, loc(5)
        call    buf_free
        EPROC

; ecx = tag, rdx = path: a GET whose answer a handler wants.   Locals: 0 tag;  Bufs: url top 5
PROC hp_get, 6
        mov     loc(0), rcx
        BUFZERO 5
        lea     rcx, loc(5)
        call    hp_url
        mov     ecx, NQ_LOCAL
        mov     rdx, loc(0)
        xor     r8d, r8d
        lea     r9, [w_get]
        mov     rax, loc(5)
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        mov     qword outarg(7), JF_NOAUTH
        mov     qword outarg(8), 0
        call    net_submit
        lea     rcx, loc(5)
        call    buf_free
        EPROC

; Called from audio_cmd: rcx = c_toggle / c_next / c_prev (the page's JSON command strings)
PROC hp_cmd, 0
        lea     rax, [c_toggle]
        cmp     rcx, rax
        je      .t
        lea     rax, [c_next]
        cmp     rcx, rax
        je      .n
        lea     rax, [c_prev]
        cmp     rcx, rax
        jne     .no
        lea     rcx, [hp_p_prev]
        jmp     .go
.t:     lea     rcx, [hp_p_playpause]
        jmp     .go
.n:     lea     rcx, [hp_p_next]
.go:    lea     rdx, [hp_b_empty]
        call    hp_post
        call    hp_poll_soon
.no:    EPROC

; ecx = position in milliseconds.   Locals: 0 ms;  Bufs: body top 5
PROC hp_seek, 6
        mov     dword loc(0), ecx
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [hp_j_pos]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     edx, dword loc(0)
        call    buf_append_u64
        lea     rcx, loc(5)
        lea     rdx, [c_close]
        call    buf_append_z
        lea     rcx, [hp_p_seek]
        mov     rdx, loc(5)
        call    hp_post
        lea     rcx, loc(5)
        call    buf_free
        call    hp_poll_soon
        EPROC

; ecx = 0..100.   Locals: 0 volume;  Bufs: body top 5
PROC hp_volume, 6
        mov     dword loc(0), ecx
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [hp_j_vol]
        call    buf_append_z
        lea     rcx, loc(5)
        mov     edx, dword loc(0)
        call    buf_append_u64
        lea     rcx, loc(5)
        lea     rdx, [c_close]
        call    buf_append_z
        lea     rcx, [hp_p_volume]
        mov     rdx, loc(5)
        call    hp_post
        lea     rcx, loc(5)
        call    buf_free
        EPROC

; The next status poll happens in 350 ms (after a command, so the answer already includes it)
hp_poll_soon:
        sub     rsp, 40
        call    GetTickCount64
        add     rax, 350
        mov     [hp_next_poll], rax
        add     rsp, 40
        ret

; ---------------------------------------------------------------- the 250 ms timer
PROC hp_tick, 2
        cmp     dword [hp_mode], 0
        je      .out
        cmp     dword [hp_started], 0
        je      .out
        cmp     dword [hp_busy], 0
        jne     .out
        call    GetTickCount64
        cmp     rax, [hp_next_poll]
        jb      .out
        mov     ecx, HP_POLL_START
        cmp     dword [sdk_ready], 0
        je      .set
        mov     ecx, HP_POLL_IDLE
        cmp     dword [np_valid], 0
        je      .set
        cmp     dword [np_paused], 0
        jne     .set
        mov     ecx, HP_POLL_PLAY
.set:   add     rax, rcx
        mov     [hp_next_poll], rax
        mov     dword [hp_busy], 1
        mov     ecx, TAG_HPSTAT
        lea     rdx, [hp_p_status]
        call    hp_get
.out:   EPROC

; ---------------------------------------------------------------- answers (UI thread)
; TAG_HPSTAT: rcx = job.   204 = running but no Spotify session, 200 = the status
PROC h_hpstat, 2
        mov     rsi, rcx
        mov     dword [hp_busy], 0
        mov     eax, [rsi+JB_STATUS]
        cmp     eax, 200
        je      .ok
        cmp     eax, 204
        jne     .out                            ; 0: the helper is not listening yet (or just died; hp_tick's process check notices)
        cmp     dword [sdk_ready], 0
        je      .ask
        mov     dword [sdk_ready], 0            ; it lost its session: the next "play" waits for it to come back
        lea     rcx, [l_hp_nosession]
        call    log_msg
.ask:   cmp     dword [hp_auth_busy], 0
        jne     .out
        call    GetTickCount64
        cmp     rax, [hp_next_auth]
        jb      .out
        add     rax, 2000
        mov     [hp_next_auth], rax
        mov     dword [hp_auth_busy], 1
        mov     ecx, TAG_HPAUTH
        lea     rdx, [hp_p_authcode]
        call    hp_get
        jmp     .out
.ok:    mov     rcx, [rsi+JB_RESP]
        test    rcx, rcx
        jz      .out
        call    hp_on_status
.out:   EPROC

; TAG_HPAUTH: rcx = job: {"code","url","expires_at"} while the helper waits for the user to pair it.
; Locals: 0 code, 1 url, 2 job, 3 wide message;  Bufs: message top 8
PROC h_hpauth, 10
        mov     loc(2), rcx
        mov     dword [hp_auth_busy], 0
        mov     rax, loc(2)
        cmp     dword [rax+JB_STATUS], 200
        jne     .out
        mov     rcx, [rax+JB_RESP]
        test    rcx, rcx
        jz      .out
        lea     rdx, [k_hp_code]
        call    jpu
        mov     loc(0), rax
        mov     rax, loc(2)
        mov     rcx, [rax+JB_RESP]
        lea     rdx, [k_hp_url]
        call    jpu
        mov     loc(1), rax
        mov     rax, loc(0)
        cmp     byte [rax], 0
        je      .free                           ; no code (yet)
        mov     rcx, [hp_pair_code]
        test    rcx, rcx
        jz      .fresh
        mov     rdx, loc(0)
        call    u8_eq
        test    eax, eax
        jnz     .free                           ; the same code: the banner is already up (or the user closed it)
.fresh: mov     rcx, [hp_pair_code]
        call    mem_free
        mov     rcx, [hp_pair_url]
        call    mem_free
        mov     rax, loc(0)
        mov     [hp_pair_code], rax
        mov     rax, loc(1)
        mov     [hp_pair_url], rax
        mov     qword loc(0), 0                 ; both strings now belong to the globals
        mov     qword loc(1), 0
        lea     rcx, [l_hp_pair]
        call    log_msg
        BUFZERO 8
        lea     rcx, loc(8)
        lea     rdx, [e_hp_msg_pre]
        call    buf_append_z
        lea     rcx, loc(8)
        mov     rdx, [hp_pair_code]
        call    buf_append_z
        lea     rcx, loc(8)
        lea     rdx, [e_hp_msg_post]
        call    buf_append_z
        mov     rcx, loc(8)
        mov     rdx, -1
        call    u8_to_w
        mov     loc(3), rax
        lea     rcx, loc(8)
        call    buf_free
        mov     rcx, loc(3)
        lea     rdx, [w_lbl_openpage]
        mov     r8d, BA_PAIR
        call    ui_banner                       ; (it keeps its own copy)
        mov     rcx, loc(3)
        call    mem_free
        mov     dword [hp_auth_shown], 1
.free:  mov     rcx, loc(0)
        call    mem_free
        mov     rcx, loc(1)
        call    mem_free
.out:   EPROC

; rcx = /status JSON (UTF-8).   Locals: 0 json, 1 string, 2 stopped flag, 3 scratch
PROC hp_on_status, 6
        mov     loc(0), rcx
        ; --- the Connect device: its id is what "play on this device" needs
        lea     rdx, [k_hp_devid]
        call    jpu
        mov     loc(1), rax
        mov     rsi, rax
        cmp     byte [rsi], 0
        je      .nodev
        mov     r12d, [sdk_ready]
        lea     rdi, [sdk_device]
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
        mov     rcx, loc(1)
        call    mem_free
        test    r12d, r12d
        jnz     .state                          ; it was ready already
        mov     dword [sdk_ready], 1
        mov     qword [idle_t0], 0
        lea     rcx, [l_hp_ready]
        lea     rdx, [sdk_device]
        call    log_msg2
        cmp     dword [hp_auth_shown], 0
        je      .nopair
        mov     dword [hp_auth_shown], 0
        cmp     dword [banner_code], BA_PAIR
        jne     .nopair
        call    ui_banner_clear                 ; paired: the banner has done its job
.nopair:
        mov     rcx, [play_pending]
        test    rcx, rcx
        jz      .state
        mov     qword [play_pending], 0
        call    audio_do_play
        jmp     .state
.nodev: mov     rcx, loc(1)
        call    mem_free
        jmp     .out
.state: ; --- what is playing
        mov     rcx, loc(0)
        lea     rdx, [k_t_uri]
        call    jpu
        mov     loc(1), rax
        mov     rcx, loc(0)
        lea     rdx, [k_hp_stopped]
        call    json_get
        mov     rcx, rax
        call    json_bool
        mov     dword loc(2), eax
        ; just after "play this" the helper still reports the previous track: wait for something new (or 5 s)
        cmp     qword [hp_hold_until], 0
        je      .nohold
        call    GetTickCount64
        cmp     rax, [hp_hold_until]
        jae     .endhold
        mov     rsi, loc(1)
        cmp     byte [rsi], 0
        je      .discard                        ; nothing loaded yet
        mov     rcx, [hp_hold_uri]
        test    rcx, rcx
        jz      .endhold
        mov     rdx, loc(1)
        call    u8_eq
        test    eax, eax
        jnz     .discard                        ; still the old track
.endhold:
        mov     qword [hp_hold_until], 0
.nohold:
        mov     rsi, loc(1)
        cmp     byte [rsi], 0
        je      .empty
        cmp     dword loc(2), 0
        jne     .empty
        ; a new track?
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
        lea     rdx, [k_hp_album]
        call    jpw
        mov     [np_album], rax
        mov     rcx, loc(1)
        call    u8_dup
        mov     [np_uri], rax
        mov     rcx, loc(0)
        lea     rdx, [k_hp_artists]
        call    audio_artists
        mov     [np_artist], rax
        mov     rcx, loc(0)
        lea     rdx, [k_hp_cover]
        call    jpu
        mov     loc(3), rax
        mov     rsi, rax
        cmp     byte [rsi], 0
        je      .nocover
        mov     rcx, rax
        call    u8_dup
        mov     [np_img_l], rax                 ; one size only: large and small share the URL (and the cache entry)
        mov     rcx, loc(3)
        call    u8_dup
        mov     [np_img_s], rax
.nocover:
        mov     rcx, loc(3)
        call    mem_free
        inc     dword [np_gen]
        mov     ecx, 700                        ; a new song: what is up next may have changed
        call    queue_mark
        mov     rcx, [np_title]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(3), rax
        lea     rcx, [l_track]
        mov     rdx, rax
        call    log_msg2
        mov     rcx, loc(3)
        call    mem_free
.same:  mov     rcx, [hp_last_uri]
        call    mem_free
        mov     rcx, loc(1)
        call    u8_dup
        mov     [hp_last_uri], rax
        mov     rcx, loc(0)
        lea     rdx, [k_paused]
        call    json_get
        mov     rcx, rax
        call    json_bool
        mov     [np_paused], eax
        mov     rcx, loc(0)
        lea     rdx, [k_hp_pos]
        call    jpi
        mov     [np_pos], eax
        mov     rcx, loc(0)
        lea     rdx, [k_hp_dur]
        call    jpi
        mov     [np_dur], eax
        mov     rcx, loc(0)
        lea     rdx, [k_hp_shuffle]
        call    json_get
        mov     rcx, rax
        call    json_bool
        mov     [np_shuffle], eax
        mov     qword loc(3), 0                 ; repeat: 2 = this track, 1 = the context, 0 = off
        mov     rcx, loc(0)
        lea     rdx, [k_hp_rep_ctx]
        call    json_get
        mov     rcx, rax
        call    json_bool
        test    eax, eax
        jz      .rt
        mov     qword loc(3), 1
.rt:    mov     rcx, loc(0)
        lea     rdx, [k_hp_rep_trk]
        call    json_get
        mov     rcx, rax
        call    json_bool
        test    eax, eax
        jz      .rset
        mov     qword loc(3), 2
.rset:  mov     eax, dword loc(3)
        mov     [np_repeat], eax
        call    GetTickCount64
        mov     [np_tick], rax
        mov     dword [np_valid], 1
        mov     qword [idle_t0], 0
        jmp     .done
.empty: mov     dword [np_valid], 0             ; nothing is loaded in the player any more
.done:  mov     rcx, loc(1)
        call    mem_free
        jmp     .out
.discard:
        mov     rcx, loc(1)
        call    mem_free
.out:   EPROC

; Called when a play request is sent in helper mode: remember what is playing now so its leftover status is ignored
PROC hp_hold_start, 2
        cmp     dword [hp_mode], 0
        je      .out
        mov     rcx, [hp_hold_uri]
        call    mem_free
        mov     qword [hp_hold_uri], 0
        mov     rcx, [hp_last_uri]
        test    rcx, rcx
        jz      .t
        call    u8_dup
        mov     [hp_hold_uri], rax
.t:     call    GetTickCount64
        add     rax, HP_HOLD_MS
        mov     [hp_hold_until], rax
        call    hp_poll_soon
.out:   EPROC
