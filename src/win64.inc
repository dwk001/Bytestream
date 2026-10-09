; win64.inc - calling-convention macros and Win32 constants for the Sonora port.
;
; Every PROC gets the same frame:
;   [rbp+16..48]  caller's home slots for rcx, rdx, r8, r9
;   [rbp-8..-56]  saved rbx rsi rdi r12 r13 r14 r15
;   loc(n)        n-th 8-byte local (loc(0) = [rbp-72], grows down)
;   [rsp+0..95]   outgoing shadow space + 8 stack arguments (args 5..12 at [rsp+32+8*(i-5)])
; rsp is 16-byte aligned at every call.

%ifndef WIN64_INC
%define WIN64_INC

bits 64
default rel

%macro PROC 1-2 0
%1:
        push    rbp
        mov     rbp, rsp
        sub     rsp, (176 + 8*%2 + 15) & ~15
        mov     [rbp-8],  rbx
        mov     [rbp-16], rsi
        mov     [rbp-24], rdi
        mov     [rbp-32], r12
        mov     [rbp-40], r13
        mov     [rbp-48], r14
        mov     [rbp-56], r15
%endmacro

%macro EPROC 0
        mov     rbx, [rbp-8]
        mov     rsi, [rbp-16]
        mov     rdi, [rbp-24]
        mov     r12, [rbp-32]
        mov     r13, [rbp-40]
        mov     r14, [rbp-48]
        mov     r15, [rbp-56]
        mov     rsp, rbp
        pop     rbp
        ret
%endmacro

%define loc(n)  [rbp-72-8*(n)]
%define home1   [rbp+16]
%define home2   [rbp+24]
%define home3   [rbp+32]
%define home4   [rbp+40]
%define stk5    [rbp+48]
%define stk6    [rbp+56]

; stack-argument slot for outgoing call (5th arg = 5, 6th = 6, ...)
%define outarg(i) [rsp+32+8*((i)-5)]

; ---- window messages
%define WM_CREATE       0x0001
%define WM_DESTROY      0x0002
%define WM_SIZE         0x0005
%define WM_SETFOCUS     0x0007
%define WM_PAINT        0x000F
%define WM_CLOSE        0x0010
%define WM_ERASEBKGND   0x0014
%define WM_SETCURSOR    0x0020
%define WM_GETMINMAXINFO 0x0024
%define WM_COMMAND      0x0111
%define WM_TIMER        0x0113
%define WM_KEYDOWN      0x0100
%define WM_CHAR         0x0102
%define WM_CTLCOLOREDIT 0x0133
%define WM_MOUSEMOVE    0x0200
%define WM_LBUTTONDOWN  0x0201
%define WM_LBUTTONUP    0x0202
%define WM_RBUTTONDOWN  0x0204
%define WM_MOUSEWHEEL   0x020A
%define WM_MOUSELEAVE   0x02A3
%define WM_DPICHANGED   0x02E0
%define WM_APP          0x8000

; ---- window styles / misc
%define WS_OVERLAPPEDWINDOW 0x00CF0000
%define WS_VISIBLE      0x10000000
%define WS_CHILD        0x40000000
%define WS_BORDER       0x00800000
%define ES_AUTOHSCROLL  0x0080
%define CW_USEDEFAULT   0x80000000
%define SW_SHOW         5
%define IDC_ARROW       32512
%define IDC_HAND        32649
%define IDC_IBEAM       32513
%define SRCCOPY         0x00CC0020
%define VK_RETURN       0x0D
%define VK_ESCAPE       0x1B
%define VK_SPACE        0x20
%define VK_LEFT         0x25
%define VK_UP           0x26
%define VK_RIGHT        0x27
%define VK_DOWN         0x28
%define VK_F11          0x7A
%define VK_CONTROL      0x11
%define TME_LEAVE       0x2

; ---- heap
%define HEAP_ZERO_MEMORY 8

; ---- GDI+
%define SmoothingModeAntiAlias      4
%define TextRenderingHintAntiAlias  4
%define InterpolationModeHighQualityBicubic 7
%define UnitPixel       2
%define FontStyleBold   1
%define StringAlignmentNear   0
%define StringAlignmentCenter 1
%define StringAlignmentFar    2
%define StringTrimmingEllipsisCharacter 3
%define StringFormatFlagsNoWrap 0x1000

%endif
