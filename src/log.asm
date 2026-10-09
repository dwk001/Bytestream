; log.asm - diagnostics: %APPDATA%\ByteStream\bytestream.log and a crash reporter.
;
; log_msg writes one timestamped line (thread-safe).  Secrets never go through here: callers log request
; methods, URLs, status codes and timings, never headers or bodies.
; The crash handler records the exception code, the faulting address, the registers and a walk of the rbp
; frame chain, all as RVAs, so a report can be matched against build/bytestream.map (tools/crashmap.py).

extern SetUnhandledExceptionFilter, MoveFileExW, GetLocalTime, MessageBoxW, GetModuleHandleW
extern RtlGetVersion, CreateMutexW, FindWindowW, SetForegroundWindow, GetLastError, GetProcAddress

%define LOG_ROTATE_BYTES  524288

%ifndef BUILD_ID
%define BUILD_ID "dev"
%endif

section .bss
log_h:          resq 1
log_lock:       resd 1
log_path:       resw 560
log_old_path:   resw 560
os_ver:         resd 7                  ; major, minor, build (RTL_OSVERSIONINFOW is 276 bytes; we keep the head)
os_ver_big:     resb 280
st_now:         resw 8

section .data
ZSTR build_id, BUILD_ID
ZSTR app_version, "0.1"
WSTR w_kernel32_dll, "kernel32.dll"
a_get_policy: db "GetProcessUserModeExceptionPolicy", 0
a_set_policy: db "SetProcessUserModeExceptionPolicy", 0
WSTR w_log_name, "\bytestream.log"
WSTR w_log_old, "\bytestream.old.log"
WSTR w_crash_title, "ByteStream crashed"
WSTR w_crash_body, `ByteStream hit an internal error and has to close.\n\nA report was saved to the log file in %APPDATA%\\ByteStream (Settings > Diagnostics > Open log folder).`
ZSTR l_crash, "CRASH "
ZSTR l_code, "code=0x"
ZSTR l_addr, " rva=0x"
ZSTR l_base, " base=0x"
ZSTR l_regs, "     "
ZSTR l_frame, "     frame "
ZSTR l_rbp, " rbp=0x"
ZSTR l_start, "start ByteStream "
ZSTR l_build, " build "
ZSTR l_win, ", Windows "
ZSTR l_dot, "."
ZSTR l_dpi, ", dpi "
ZSTR l_sp1, " "
ZSTR l_eq, "="
ZSTR l_0x, "=0x"
ZSTR l_nl, `\n`
reg_names:      db "rax", 0, "rcx", 0, "rdx", 0, "rbx", 0, "rsp", 0, "rbp", 0, "rsi", 0, "rdi", 0
                db "r8", 0, 0, "r9", 0, 0, "r10", 0, "r11", 0, "r12", 0, "r13", 0, "r14", 0, "r15", 0

section .text

; rcx = Buf*, rdx = value, r8d = minimum digits -> appends zero-padded decimal
PROC buf_append_dec_pad, 4
        mov     loc(0), rcx
        mov     loc(1), r8
        lea     rcx, loc(3)                     ; 16-byte digit scratch: loc(3)..loc(2)
        call    u8_put_u64
        lea     rdx, loc(3)
        sub     rax, rdx
        mov     r12, rax                        ; digits written
        mov     r13, loc(1)
        sub     r13, r12                        ; zeros to add
        jbe     .copy
.pad:   mov     rcx, loc(0)
        mov     edx, '0'
        call    buf_append_char
        dec     r13
        jnz     .pad
.copy:  mov     rcx, loc(0)
        lea     rdx, loc(3)
        mov     r8, r12
        call    buf_append
        EPROC

; rcx = Buf*, rdx = value, r8d = digits -> appends lower-case hex with a fixed width
PROC buf_append_hex, 2
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     r12d, r8d
.l:     test    r12d, r12d
        jz      .done
        dec     r12d
        mov     ecx, r12d
        shl     ecx, 2
        mov     rax, loc(1)
        shr     rax, cl
        and     eax, 15
        cmp     eax, 10
        jb      .d
        add     eax, 'a' - 10
        jmp     .e
.d:     add     eax, '0'
.e:     mov     rcx, loc(0)
        mov     edx, eax
        call    buf_append_char
        jmp     .l
.done:  EPROC

; rcx = data directory (UTF-16).  Opens the log, rotating a large one, and writes the start line.
PROC log_init, 6
        mov     loc(0), rcx
        lea     rcx, [log_path]
        mov     rdx, loc(0)
        call    lstrcpyW
        lea     rcx, [log_path]
        lea     rdx, [w_log_name]
        call    lstrcatW
        lea     rcx, [log_old_path]
        mov     rdx, loc(0)
        call    lstrcpyW
        lea     rcx, [log_old_path]
        lea     rdx, [w_log_old]
        call    lstrcatW
        ; rotate when the current file is big
        lea     rcx, [log_path]
        mov     edx, 0x80000000
        mov     r8d, 3
        xor     r9d, r9d
        mov     qword outarg(5), 3
        mov     qword outarg(6), 0x80
        mov     qword outarg(7), 0
        call    CreateFileW
        cmp     rax, -1
        je      .open
        mov     loc(3), rax
        mov     rcx, rax
        lea     rdx, loc(4)
        call    GetFileSizeEx
        mov     rcx, loc(3)
        call    CloseHandle
        cmp     qword loc(4), LOG_ROTATE_BYTES
        jbe     .open
        lea     rcx, [log_path]
        lea     rdx, [log_old_path]
        mov     r8d, 1                          ; MOVEFILE_REPLACE_EXISTING
        call    MoveFileExW
.open:  lea     rcx, [log_path]
        mov     edx, 4                          ; FILE_APPEND_DATA
        mov     r8d, 3                          ; share read | write
        xor     r9d, r9d
        mov     qword outarg(5), 4              ; OPEN_ALWAYS
        mov     qword outarg(6), 0x80
        mov     qword outarg(7), 0
        call    CreateFileW
        mov     [log_h], rax
        call    os_version_probe
        call    log_start_line
        EPROC

PROC os_version_probe, 0
        lea     rdi, [os_ver_big]
        mov     dword [rdi], 276
        mov     rcx, rdi
        call    RtlGetVersion
        mov     eax, [os_ver_big+4]
        mov     [os_ver], eax
        mov     eax, [os_ver_big+8]
        mov     [os_ver+4], eax
        mov     eax, [os_ver_big+12]
        mov     [os_ver+8], eax
        EPROC

PROC log_start_line, 6
        mov     qword loc(1), 0                 ; Buf based at &loc(3)
        mov     qword loc(2), 0
        mov     qword loc(3), 0
        lea     rcx, loc(3)
        lea     rdx, [l_start]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [app_version]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [l_build]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [build_id]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [l_win]
        call    buf_append_z
        lea     rcx, loc(3)
        mov     edx, [os_ver]
        call    buf_append_u64
        lea     rcx, loc(3)
        lea     rdx, [l_dot]
        call    buf_append_z
        lea     rcx, loc(3)
        mov     edx, [os_ver+4]
        call    buf_append_u64
        lea     rcx, loc(3)
        lea     rdx, [l_dot]
        call    buf_append_z
        lea     rcx, loc(3)
        mov     edx, [os_ver+8]
        call    buf_append_u64
        mov     rcx, loc(3)
        call    log_msg
        lea     rcx, loc(3)
        call    buf_free
        EPROC

; rcx = message (UTF-8, no newline).  Writes "YYYY-MM-DD HH:MM:SS.mmm message".
PROC log_msg, 6
        mov     loc(0), rcx
        cmp     qword [log_h], 0
        je      .out
        cmp     qword [log_h], -1
        je      .out
        lea     rcx, [st_now]
        call    GetLocalTime
        mov     qword loc(2), 0                 ; Buf based at &loc(4)
        mov     qword loc(3), 0
        mov     qword loc(4), 0
        movzx   edx, word [st_now]
        lea     rcx, loc(4)
        mov     r8d, 4
        call    buf_append_dec_pad
        lea     rcx, loc(4)
        mov     edx, '-'
        call    buf_append_char
        movzx   edx, word [st_now+2]
        lea     rcx, loc(4)
        mov     r8d, 2
        call    buf_append_dec_pad
        lea     rcx, loc(4)
        mov     edx, '-'
        call    buf_append_char
        movzx   edx, word [st_now+6]
        lea     rcx, loc(4)
        mov     r8d, 2
        call    buf_append_dec_pad
        lea     rcx, loc(4)
        mov     edx, ' '
        call    buf_append_char
        movzx   edx, word [st_now+8]
        lea     rcx, loc(4)
        mov     r8d, 2
        call    buf_append_dec_pad
        lea     rcx, loc(4)
        mov     edx, ':'
        call    buf_append_char
        movzx   edx, word [st_now+10]
        lea     rcx, loc(4)
        mov     r8d, 2
        call    buf_append_dec_pad
        lea     rcx, loc(4)
        mov     edx, ':'
        call    buf_append_char
        movzx   edx, word [st_now+12]
        lea     rcx, loc(4)
        mov     r8d, 2
        call    buf_append_dec_pad
        lea     rcx, loc(4)
        mov     edx, '.'
        call    buf_append_char
        movzx   edx, word [st_now+14]
        lea     rcx, loc(4)
        mov     r8d, 3
        call    buf_append_dec_pad
        lea     rcx, loc(4)
        mov     edx, ' '
        call    buf_append_char
        lea     rcx, loc(4)
        mov     rdx, loc(0)
        call    buf_append_z
        lea     rcx, loc(4)
        lea     rdx, [l_nl]
        call    buf_append_z
        lea     rcx, [log_lock]
        call    lock_acquire
        mov     rcx, [log_h]
        mov     rdx, loc(4)
        mov     r8, loc(3)
        lea     r9, loc(5)
        mov     qword outarg(5), 0
        call    WriteFile
        lea     rcx, [log_lock]
        call    lock_release
        lea     rcx, loc(4)
        call    buf_free
.out:   EPROC

; rcx = prefix (UTF-8), rdx = number -> "<prefix><number>"
PROC log_num, 6
        mov     loc(0), rdx
        mov     qword loc(2), 0
        mov     qword loc(3), 0
        mov     qword loc(4), 0
        mov     rdx, rcx
        lea     rcx, loc(4)
        call    buf_append_z
        lea     rcx, loc(4)
        mov     rdx, loc(0)
        call    buf_append_u64
        mov     rcx, loc(4)
        call    log_msg
        lea     rcx, loc(4)
        call    buf_free
        EPROC

; ---------------------------------------------------------------- crash reporter
; 64-bit Windows silently swallows an exception raised inside a window procedure (the kernel-callback boundary
; eats it), so a fault while painting would leave a blank window and no report.  Clearing
; PROCESS_CALLBACK_FILTER_ENABLED lets those exceptions reach the filter.  The two functions are looked up at run
; time because Windows does not document them; if they are missing nothing changes.
PROC crash_install, 2
        lea     rcx, [crash_filter]
        call    SetUnhandledExceptionFilter
        lea     rcx, [w_kernel32_dll]
        call    GetModuleHandleW
        test    rax, rax
        jz      .out
        mov     rbx, rax
        mov     rcx, rbx
        lea     rdx, [a_get_policy]
        call    GetProcAddress
        mov     rsi, rax
        mov     rcx, rbx
        lea     rdx, [a_set_policy]
        call    GetProcAddress
        test    rax, rax
        jz      .out
        test    rsi, rsi
        jz      .out
        mov     rdi, rax
        lea     rcx, loc(0)
        mov     dword [rcx], 0
        call    rsi                             ; GetProcessUserModeExceptionPolicy(&flags)
        mov     ecx, dword loc(0)
        and     ecx, ~1                         ; PROCESS_CALLBACK_FILTER_ENABLED
        call    rdi                             ; SetProcessUserModeExceptionPolicy(flags)
.out:   EPROC

; LONG WINAPI crash_filter(EXCEPTION_POINTERS* rcx)
PROC crash_filter, 8
        mov     rbx, [rcx]                      ; EXCEPTION_RECORD*
        mov     rsi, [rcx+8]                    ; CONTEXT*
        xor     ecx, ecx
        call    GetModuleHandleW
        mov     loc(0), rax                     ; image base
        mov     qword loc(2), 0                 ; Buf based at &loc(4)
        mov     qword loc(3), 0
        mov     qword loc(4), 0
        lea     rcx, loc(4)
        lea     rdx, [l_crash]
        call    buf_append_z
        lea     rcx, loc(4)
        lea     rdx, [l_code]
        call    buf_append_z
        lea     rcx, loc(4)
        mov     edx, [rbx]
        mov     r8d, 8
        call    buf_append_hex
        lea     rcx, loc(4)
        lea     rdx, [l_addr]
        call    buf_append_z
        mov     rdx, [rbx+16]                   ; ExceptionAddress
        sub     rdx, loc(0)
        lea     rcx, loc(4)
        mov     r8d, 8
        call    buf_append_hex
        lea     rcx, loc(4)
        lea     rdx, [l_base]
        call    buf_append_z
        lea     rcx, loc(4)
        mov     rdx, loc(0)
        mov     r8d, 12
        call    buf_append_hex
        mov     rcx, loc(4)
        call    log_msg
        lea     rcx, loc(4)
        call    buf_free
        ; registers, four per line: CONTEXT.Rax is at +0x78, r15 at +0xF8
        xor     r12d, r12d
.reg:   cmp     r12d, 16
        jae     .frames
        test    r12d, 3
        jnz     .more
        mov     qword loc(2), 0
        mov     qword loc(3), 0
        mov     qword loc(4), 0
        lea     rcx, loc(4)
        lea     rdx, [l_regs]
        call    buf_append_z
.more:  lea     rcx, loc(4)
        lea     rax, [reg_names]
        mov     edx, r12d
        shl     edx, 2                          ; names are 4 bytes each
        add     rdx, rax
        call    buf_append_z
        lea     rcx, loc(4)
        lea     rdx, [l_0x]
        call    buf_append_z
        mov     rdx, [rsi+0x78+r12*8]
        lea     rcx, loc(4)
        mov     r8d, 16
        call    buf_append_hex
        lea     rcx, loc(4)
        lea     rdx, [l_sp1]
        call    buf_append_z
        inc     r12d
        test    r12d, 3
        jnz     .reg
        mov     rcx, loc(4)
        call    log_msg
        lea     rcx, loc(4)
        call    buf_free
        jmp     .reg
.frames:
        ; walk the rbp chain: [rbp] = caller's rbp, [rbp+8] = return address
        mov     r13, [rsi+0xA0]                 ; rbp
        mov     r12d, 0
.fr:    cmp     r12d, 24
        jae     .box
        test    r13, 7
        jnz     .box
        mov     rax, r13
        shr     rax, 16
        jz      .box                            ; tiny / null pointer
        mov     r14, [r13+8]                    ; return address
        mov     rax, r14
        sub     rax, loc(0)
        cmp     rax, 0x400000
        ja      .box                            ; not inside our image
        mov     qword loc(2), 0
        mov     qword loc(3), 0
        mov     qword loc(4), 0
        lea     rcx, loc(4)
        lea     rdx, [l_frame]
        call    buf_append_z
        lea     rcx, loc(4)
        lea     rdx, [l_addr+1]                 ; "rva=0x"
        call    buf_append_z
        mov     rdx, r14
        sub     rdx, loc(0)
        lea     rcx, loc(4)
        mov     r8d, 8
        call    buf_append_hex
        mov     rcx, loc(4)
        call    log_msg
        lea     rcx, loc(4)
        call    buf_free
        mov     rax, [r13]
        cmp     rax, r13
        jbe     .box                            ; chain must move up the stack
        mov     rdx, rax
        sub     rdx, r13
        cmp     rdx, 0x100000
        ja      .box
        mov     r13, rax
        inc     r12d
        jmp     .fr
.box:   cmp     dword [cli_no_shell], 0
        jne     .done                           ; tests: no dialog
        mov     rcx, [hwnd]
        lea     rdx, [w_crash_body]
        lea     r8, [w_crash_title]
        mov     r9d, 0x10                       ; MB_ICONERROR
        call    MessageBoxW
.done:  mov     eax, 1                          ; EXCEPTION_EXECUTE_HANDLER
        EPROC

; developer flag --crash-test: fault inside a known function so the report can be checked against the map
PROC crash_test_fn, 0
        xor     eax, eax
        mov     dword [rax], 1
        EPROC

section .data
ZSTR v_pre, "Version "
ZSTR v_mid, " (build "
ZSTR v_post, ")"
WSTR w_mutex_pre, `Local\\ByteStream-`
WSTR w_class_name, "ByteStreamWindow"
section .bss
mutex_name:     resw 40
section .text

PROC version_string_init, 4
        mov     qword loc(1), 0
        mov     qword loc(2), 0
        mov     qword loc(3), 0
        lea     rcx, loc(3)
        lea     rdx, [v_pre]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [app_version]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [v_mid]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [build_id]
        call    buf_append_z
        lea     rcx, loc(3)
        lea     rdx, [v_post]
        call    buf_append_z
        mov     rcx, loc(3)
        mov     rdx, -1
        call    u8_to_w
        mov     [ver_w], rax
        lea     rcx, loc(3)
        call    buf_free
        EPROC

; One ByteStream per data directory: a second launch brings the first one to the front and exits.
PROC single_instance_check, 4
        ; FNV-1a over the data directory, so different --data-dir values may run side by side
        mov     eax, 0x811C9DC5
        lea     rsi, [data_dir]
.h:     movzx   ecx, word [rsi]
        test    ecx, ecx
        jz      .named
        xor     eax, ecx
        imul    eax, eax, 0x01000193
        add     rsi, 2
        jmp     .h
.named: mov     loc(0), rax
        lea     rcx, [mutex_name]
        lea     rdx, [w_mutex_pre]
        call    lstrcpyW
        lea     rdi, [mutex_name]
        lea     rdi, [rdi+34]                   ; after "Local\ByteStream-" (17 wide chars)
        mov     ecx, 8
        mov     rdx, loc(0)
.hex:   rol     edx, 4
        mov     eax, edx
        and     eax, 15
        cmp     eax, 10
        jb      .dg
        add     eax, 'a' - 10
        jmp     .st
.dg:    add     eax, '0'
.st:    mov     [rdi], ax
        add     rdi, 2
        dec     ecx
        jnz     .hex
        mov     word [rdi], 0
        xor     ecx, ecx
        xor     edx, edx
        lea     r8, [mutex_name]
        call    CreateMutexW
        call    GetLastError
        cmp     eax, 183                        ; ERROR_ALREADY_EXISTS
        jne     .out
        lea     rcx, [w_class_name]
        xor     edx, edx
        call    FindWindowW
        test    rax, rax
        jz      .exit
        mov     loc(1), rax
        mov     rcx, rax
        mov     edx, 9                          ; SW_RESTORE
        call    ShowWindow
        mov     rcx, loc(1)
        call    SetForegroundWindow
.exit:  xor     ecx, ecx
        call    ExitProcess
.out:   EPROC
