; settings.asm - %APPDATA%\ByteStream\settings.ini (or --data-dir), edited from the GUI.
;
; File format: one "key=value" per line, UTF-8.   Keys: client_id, port, theme, scale, volume.

extern SHGetFolderPathW, CreateDirectoryW, CreateFileW, ReadFile, WriteFile, CloseHandle, GetFileSizeEx
extern lstrcpyW, lstrcatW

%define SET_PORT_DEFAULT 8989

section .bss
data_dir:       resw 520                ; UTF-16, no trailing backslash
set_path:       resw 540
set_client_id:  resb 160                ; UTF-8, NUL-terminated
set_port:       resd 1
set_scale:      resd 1                  ; percent; 0 = follow the system DPI
set_theme:      resd 1
set_volume:     resd 1
set_win_w:      resd 1                  ; window client size in logical pixels (0 = default)
set_win_h:      resd 1
set_loaded:     resd 1                  ; 1 once a settings file was found

section .data
WSTR w_app_dir, "\ByteStream"
WSTR w_ini_name, "\settings.ini"
ZSTR k_s_client, "client_id="
ZSTR k_s_port, "port="
ZSTR k_s_theme, "theme="
ZSTR k_s_scale, "scale="
ZSTR k_s_volume, "volume="
ZSTR k_s_winw, "winw="
ZSTR k_s_winh, "winh="
ZSTR s_nl_lf, `\n`
ZSTR s_redirect_pre, "http://127.0.0.1:"
ZSTR s_redirect_post, "/callback"
ZSTR s_dashboard_url, "https://developer.spotify.com/dashboard"

section .text

; rcx = directory override (UTF-16) or 0.  Resolves the data directory, creates it, loads settings.ini.
PROC settings_init, 2
        mov     dword [set_port], SET_PORT_DEFAULT
        mov     dword [set_theme], 0
        mov     dword [set_volume], 70
        mov     dword [set_scale], 0
        test    rcx, rcx
        jz      .appdata
        mov     rdx, rcx
        lea     rcx, [data_dir]
        call    lstrcpyW
        jmp     .mk
.appdata:
        xor     ecx, ecx
        mov     edx, 0x801A                     ; CSIDL_APPDATA | CSIDL_FLAG_CREATE
        xor     r8d, r8d
        xor     r9d, r9d
        lea     rax, [data_dir]
        mov     outarg(5), rax
        call    SHGetFolderPathW
        lea     rcx, [data_dir]
        lea     rdx, [w_app_dir]
        call    lstrcatW
.mk:    lea     rcx, [data_dir]
        xor     edx, edx
        call    CreateDirectoryW                ; fine if it already exists
        lea     rcx, [set_path]
        lea     rdx, [data_dir]
        call    lstrcpyW
        lea     rcx, [set_path]
        lea     rdx, [w_ini_name]
        call    lstrcatW
        call    settings_load
        EPROC

; reads a whole file -> rax = heap bytes (NUL-terminated) or 0, rdx = length
; rcx = UTF-16 path
PROC file_read_all, 4
        mov     edx, 0x80000000                 ; GENERIC_READ
        mov     r8d, 1                          ; FILE_SHARE_READ
        xor     r9d, r9d
        mov     qword outarg(5), 3              ; OPEN_EXISTING
        mov     qword outarg(6), 0x80
        mov     qword outarg(7), 0
        call    CreateFileW
        cmp     rax, -1
        je      .none
        mov     loc(0), rax
        mov     rcx, rax
        lea     rdx, loc(1)
        call    GetFileSizeEx
        mov     rcx, loc(1)
        cmp     rcx, 16777216
        ja      .close
        inc     rcx
        call    mem_alloc
        mov     loc(2), rax
        mov     rcx, loc(0)
        mov     rdx, rax
        mov     r8, loc(1)
        lea     r9, loc(3)
        mov     qword outarg(5), 0
        call    ReadFile
        mov     rcx, loc(0)
        call    CloseHandle
        mov     rax, loc(2)
        mov     rdx, loc(3)
        and     edx, 0xFFFFFFFF
        jmp     .out
.close: mov     rcx, loc(0)
        call    CloseHandle
.none:  xor     eax, eax
        xor     edx, edx
.out:   EPROC

; rcx = UTF-16 path, rdx = bytes, r8 = length -> eax = 1 on success
PROC file_write_all, 4
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     edx, 0x40000000                 ; GENERIC_WRITE
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword outarg(5), 2              ; CREATE_ALWAYS
        mov     qword outarg(6), 0x80
        mov     qword outarg(7), 0
        call    CreateFileW
        cmp     rax, -1
        je      .bad
        mov     loc(0), rax
        mov     rcx, rax
        mov     rdx, loc(1)
        mov     r8, loc(2)
        lea     r9, loc(3)
        mov     qword outarg(5), 0
        call    WriteFile
        mov     loc(1), rax
        mov     rcx, loc(0)
        call    CloseHandle
        mov     rax, loc(1)
        jmp     .out
.bad:   xor     eax, eax
.out:   EPROC

; one "key=value" line (NUL-terminated at rcx) -> applied to the settings
PROC settings_apply_line, 2
        mov     loc(0), rcx
        lea     rdx, [k_s_client]
        call    u8_starts
        test    eax, eax
        jz      .port
        mov     rsi, loc(0)
        add     rsi, 10
        lea     rdi, [set_client_id]
        xor     ecx, ecx
.cp:    cmp     ecx, 150
        jae     .term
        mov     al, [rsi+rcx]
        test    al, al
        jz      .term
        mov     [rdi+rcx], al
        inc     ecx
        jmp     .cp
.term:  mov     byte [rdi+rcx], 0
        jmp     .out
.port:  mov     rcx, loc(0)
        lea     rdx, [k_s_port]
        call    u8_starts
        test    eax, eax
        jz      .theme
        mov     rcx, loc(0)
        add     rcx, 5
        call    json_int
        cmp     eax, 1024
        jb      .out
        cmp     eax, 65535
        ja      .out
        mov     [set_port], eax
        jmp     .out
.theme: mov     rcx, loc(0)
        lea     rdx, [k_s_theme]
        call    u8_starts
        test    eax, eax
        jz      .scale
        mov     rcx, loc(0)
        add     rcx, 6
        call    json_int
        cmp     eax, 2
        ja      .out
        mov     [set_theme], eax
        jmp     .out
.scale: mov     rcx, loc(0)
        lea     rdx, [k_s_scale]
        call    u8_starts
        test    eax, eax
        jz      .vol
        mov     rcx, loc(0)
        add     rcx, 6
        call    json_int
        mov     [set_scale], eax
        jmp     .out
.vol:   mov     rcx, loc(0)
        lea     rdx, [k_s_volume]
        call    u8_starts
        test    eax, eax
        jz      .winw
        mov     rcx, loc(0)
        add     rcx, 7
        call    json_int
        cmp     eax, 100
        ja      .out
        mov     [set_volume], eax
        jmp     .out
.winw:  mov     rcx, loc(0)
        lea     rdx, [k_s_winw]
        call    u8_starts
        test    eax, eax
        jz      .winh
        mov     rcx, loc(0)
        add     rcx, 5
        call    json_int
        cmp     eax, 640
        jb      .out
        cmp     eax, 8192
        ja      .out
        mov     [set_win_w], eax
        jmp     .out
.winh:  mov     rcx, loc(0)
        lea     rdx, [k_s_winh]
        call    u8_starts
        test    eax, eax
        jz      .out
        mov     rcx, loc(0)
        add     rcx, 5
        call    json_int
        cmp     eax, 400
        jb      .out
        cmp     eax, 8192
        ja      .out
        mov     [set_win_h], eax
.out:   EPROC

PROC settings_load, 3
        lea     rcx, [set_path]
        call    file_read_all
        test    rax, rax
        jz      .out
        mov     loc(0), rax
        mov     dword [set_loaded], 1
        mov     rsi, rax
.line:  cmp     byte [rsi], 0
        je      .free
        mov     rdi, rsi                        ; line start
.scan:  mov     al, [rsi]
        test    al, al
        jz      .last
        cmp     al, 10
        je      .eol
        cmp     al, 13
        je      .eol
        inc     rsi
        jmp     .scan
.eol:   mov     byte [rsi], 0
        inc     rsi
        mov     rcx, rdi
        call    settings_apply_line
        jmp     .line
.last:  mov     rcx, rdi
        call    settings_apply_line
.free:  mov     rcx, loc(0)
        call    mem_free
.out:   EPROC

PROC settings_save, 4
        mov     qword loc(1), 0                 ; Buf based at &loc(3)
        mov     qword loc(2), 0
        mov     qword loc(3), 0
        lea     rcx, loc(3)
        lea     rdx, [k_s_client]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [set_client_id]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [s_nl_lf]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [k_s_port]
        call    buf_append_z
        lea     rcx, loc(3)
        mov     edx, [set_port]
        call    buf_append_u64
        lea     rcx, loc(3)
        lea     rdx, [s_nl_lf]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [k_s_theme]
        call    buf_append_z
        lea     rcx, loc(3)
        mov     edx, [theme_idx]
        call    buf_append_u64
        lea     rcx, loc(3)
        lea     rdx, [s_nl_lf]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [k_s_scale]
        call    buf_append_z
        lea     rcx, loc(3)
        mov     edx, [set_scale]
        call    buf_append_u64
        lea     rcx, loc(3)
        lea     rdx, [s_nl_lf]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [k_s_volume]
        call    buf_append_z
        lea     rcx, loc(3)
        mov     edx, [np_vol]
        call    buf_append_u64
        lea     rcx, loc(3)
        lea     rdx, [s_nl_lf]
        call    buf_append_z
        cmp     dword [ui_w], 0
        je      .nowin
        mov     eax, [ui_w]                     ; physical -> logical pixels
        imul    rax, 65536
        xor     edx, edx
        mov     ecx, [ui_scale]
        test    ecx, ecx
        jz      .nowin
        div     rcx
        mov     [set_win_w], eax
        mov     eax, [ui_h]
        imul    rax, 65536
        xor     edx, edx
        mov     ecx, [ui_scale]
        div     rcx
        mov     [set_win_h], eax
.nowin: lea     rcx, loc(3)
        lea     rdx, [k_s_winw]
        call    buf_append_z
        lea     rcx, loc(3)
        mov     edx, [set_win_w]
        call    buf_append_u64
        lea     rcx, loc(3)
        lea     rdx, [s_nl_lf]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [k_s_winh]
        call    buf_append_z
        lea     rcx, loc(3)
        mov     edx, [set_win_h]
        call    buf_append_u64
        lea     rcx, loc(3)
        lea     rdx, [s_nl_lf]
        call    buf_append_z
        lea     rcx, [set_path]
        mov     rdx, loc(3)
        mov     r8, loc(2)
        call    file_write_all
        lea     rcx, loc(3)
        call    buf_free
        EPROC

; rcx = Buf* -> appends "http://127.0.0.1:<port>/callback"
PROC redirect_uri_append, 1
        mov     loc(0), rcx
        lea     rdx, [s_redirect_pre]
        call    buf_append_z
        mov     rcx, loc(0)
        mov     edx, [set_port]
        call    buf_append_u64
        mov     rcx, loc(0)
        lea     rdx, [s_redirect_post]
        call    buf_append_z
        EPROC
