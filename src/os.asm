; os.asm - thin OS helpers the GUI calls: open a link in the browser, copy text to the clipboard.
; With --no-browser (developer/test flag) nothing is launched; the intended action is printed instead.

extern ShellExecuteW, OpenClipboard, EmptyClipboard, SetClipboardData, CloseClipboard
extern GlobalAlloc, GlobalLock, GlobalUnlock

section .bss
cli_no_shell:   resd 1

section .data
WSTR w_verb_open, "open"
ZSTR s_open_pre, "open:"
ZSTR s_clip_pre, "clipboard:"
s_lf:           db 10, 0

section .text

; rcx = URL (UTF-8)
PROC os_open_url, 2
        mov     loc(0), rcx
        cmp     dword [cli_no_shell], 0
        je      .real
        lea     rcx, [s_open_pre]
        call    out_z
        mov     rcx, loc(0)
        call    out_z
        lea     rcx, [s_lf]
        call    out_z
        jmp     .out
.real:  mov     rcx, loc(0)
        mov     rdx, -1
        call    u8_to_w
        mov     loc(1), rax
        mov     rcx, [hwnd]
        lea     rdx, [w_verb_open]
        mov     r8, rax
        xor     r9d, r9d
        mov     qword outarg(5), 0
        mov     qword outarg(6), SW_SHOW
        call    ShellExecuteW
        mov     rcx, loc(1)
        call    mem_free
.out:   EPROC

; rcx = text (UTF-8) -> clipboard as Unicode text
PROC os_clipboard, 4
        mov     loc(0), rcx
        cmp     dword [cli_no_shell], 0
        je      .real
        lea     rcx, [s_clip_pre]
        call    out_z
        mov     rcx, loc(0)
        call    out_z
        lea     rcx, [s_lf]
        call    out_z
        jmp     .out
.real:  mov     rcx, loc(0)
        mov     rdx, -1
        call    u8_to_w
        mov     loc(1), rax
        mov     rcx, rax
        call    lstrlenW
        lea     rcx, [rax*2+2]
        mov     loc(2), rcx
        mov     ecx, 2                          ; GMEM_MOVEABLE
        mov     rdx, loc(2)
        call    GlobalAlloc
        mov     loc(3), rax
        test    rax, rax
        jz      .free
        mov     rcx, rax
        call    GlobalLock
        mov     rcx, rax
        mov     rdx, loc(1)
        mov     r8, loc(2)
        call    mem_copy
        mov     rcx, loc(3)
        call    GlobalUnlock
        mov     rcx, [hwnd]
        call    OpenClipboard
        test    eax, eax
        jz      .free
        call    EmptyClipboard
        mov     ecx, 13                         ; CF_UNICODETEXT
        mov     rdx, loc(3)
        call    SetClipboardData
        call    CloseClipboard
.free:  mov     rcx, loc(1)
        call    mem_free
.out:   EPROC
