; main.asm - Sonora for Windows, x86-64 assembly. Single translation unit.
%include "win64.inc"
%include "core.asm"
%include "json.asm"
%include "selftest.asm"

extern GetCommandLineW, CommandLineToArgvW, lstrcmpW

section .data
WSTR a_selftest, "--selftest"

section .text
global start
PROC start, 4
        call    core_init
        call    GetCommandLineW
        mov     rcx, rax
        lea     rdx, loc(0)
        call    CommandLineToArgvW
        mov     loc(1), rax
        mov     rcx, loc(0)
        cmp     ecx, 2
        jb      .gui
        mov     rax, loc(1)
        mov     rcx, [rax+8]
        lea     rdx, [a_selftest]
        call    lstrcmpW
        test    eax, eax
        jnz     .gui
        call    selftest
        mov     ecx, eax
        call    ExitProcess
.gui:   xor     ecx, ecx
        call    ExitProcess
        EPROC
