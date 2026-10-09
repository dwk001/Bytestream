; field.asm - single-line text inputs that the program draws and edits itself (search box, client id, port, the
; playlist dialog's name and description).  No EDIT controls: text, selection, caret, scrolling, mouse and keyboard
; editing and the clipboard are all here, drawn through gfx_* like everything else.
;
; A field is a record in fld_tab (FL_*), its text a UTF-16 buffer of fixed capacity.  The page painters call
; field_draw each frame with the rectangle they want; that also adds the hit rectangle (H_FIELD, index).  At most one
; field has the keyboard (fld_focus); the window procedure sends it WM_KEYDOWN / WM_CHAR first.

extern GetKeyState, GetClipboardData, IsClipboardFormatAvailable

%define FLD_SEARCH      0
%define FLD_CLIENT      1
%define FLD_PORT        2
%define FLD_DNAME       3
%define FLD_DDESC       4
%define FLD_N           5
%define FLD_CAPMAX      256

%define FL_BUF          0               ; qword: UTF-16 text, always NUL-terminated
%define FL_LEN          8               ; characters (UTF-16 units)
%define FL_CAP          12
%define FL_CARET        16
%define FL_ANCH         20              ; other end of the selection (= caret when nothing is selected)
%define FL_SCROLL       24              ; pixels the text is shifted left
%define FL_X            28              ; rectangle of the last draw
%define FL_Y            32
%define FL_W            36
%define FL_H            40
%define FL_STAMP        44              ; fld_stamp of the frame that drew it
%define FL_CUE          48              ; qword: UTF-16 hint shown while empty
%define FL_SIZE         64

%define TIMER_CARET     4
%define WM_DLG_OK       (WM_APP + 4)
%define WM_DLG_CANCEL   (WM_APP + 5)
%define WM_SEARCH_NOW   (WM_APP + 6)

%define VK_SHIFT        0x10
%define FK_SHIFT        1               ; modifier bits passed to field_key
%define FK_CTRL         2

section .bss
                align 8
fld_tab:        resb FL_SIZE*FLD_N
                align 8
fld_text:       resw FLD_N*(FLD_CAPMAX+2)
fld_focus:      resd 1                  ; index + 1 of the field that has the keyboard, 0 = none
fld_stamp:      resd 1                  ; counts full frames
fld_active:     resd 1                  ; the window itself has the keyboard (the caret shows and blinks)
fld_drag:       resd 1                  ; index + 1 while the mouse button is down inside a field
fld_timer:      resd 1                  ; the blink timer exists
                align 8
fld_blink0:     resq 1                  ; GetTickCount64 of the last keystroke / focus change (caret solid just after)
fld_ibuf:       resw 4
fld_frame:      resd 4                  ; set by the page before field_draw: the box drawn around the field (x y w h)

section .data
                align 4
fld_caps:       dd 256, 190, 5, 255, 255

section .text

PROC field_init, 2
        xor     ebx, ebx
.l:     imul    rsi, rbx, FL_SIZE
        lea     rax, [fld_tab]
        add     rsi, rax
        imul    rdx, rbx, (FLD_CAPMAX+2)*2
        lea     rax, [fld_text]
        add     rdx, rax
        mov     [rsi+FL_BUF], rdx
        lea     rax, [fld_caps]
        mov     eax, [rax+rbx*4]
        mov     [rsi+FL_CAP], eax
        inc     ebx
        cmp     ebx, FLD_N
        jb      .l
        lea     rax, [fld_tab]
        mov     [edit_search], rax
        add     rax, FL_SIZE
        mov     [edit_client], rax
        add     rax, FL_SIZE
        mov     [edit_port], rax
        add     rax, FL_SIZE
        mov     [edit_dn], rax
        add     rax, FL_SIZE
        mov     [edit_dd], rax
        lea     rax, [w_cue_search]
        mov     [fld_tab+FLD_SEARCH*FL_SIZE+FL_CUE], rax
        lea     rax, [w_cue_client]
        mov     [fld_tab+FLD_CLIENT*FL_SIZE+FL_CUE], rax
        mov     dword [fld_active], 1
        EPROC

; ecx = index -> rax = &fld_tab[index]
fld_ptr:
        imul    rax, rcx, FL_SIZE
        lea     rdx, [fld_tab]
        add     rax, rdx
        ret

; rcx = field -> eax = index
fld_index:
        lea     rax, [fld_tab]
        sub     rcx, rax
        mov     rax, rcx
        shr     rax, 6                          ; FL_SIZE = 64
        ret

; ---------------------------------------------------------------- text access (the GetWindowText / SetWindowText of EDIT)
; rcx = field, rdx = destination (UTF-16), r8d = capacity in characters including the NUL -> eax = characters copied
PROC field_get_text, 0
        test    r8d, r8d
        jz      .none
        mov     r9d, [rcx+FL_LEN]
        lea     eax, [r8-1]
        cmp     r9d, eax
        cmova   r9d, eax
        mov     rsi, [rcx+FL_BUF]
        mov     rdi, rdx
        mov     ecx, r9d
        rep     movsw
        mov     word [rdi], 0
        mov     eax, r9d
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC

; rcx = field, rdx = UTF-16 z-string (0 = empty): replaces the text, caret to the end, notifies like EN_CHANGE
PROC field_set_text, 2
        mov     loc(0), rcx
        mov     rdi, [rcx+FL_BUF]
        mov     ebx, [rcx+FL_CAP]
        xor     eax, eax
        test    rdx, rdx
        jz      .end
.cp:    cmp     eax, ebx
        jae     .end
        movzx   ecx, word [rdx+rax*2]
        test    ecx, ecx
        jz      .end
        mov     [rdi+rax*2], cx
        inc     eax
        jmp     .cp
.end:   mov     word [rdi+rax*2], 0
        mov     rcx, loc(0)
        mov     [rcx+FL_LEN], eax
        mov     [rcx+FL_CARET], eax
        mov     [rcx+FL_ANCH], eax
        mov     dword [rcx+FL_SCROLL], 0
        call    field_changed
        EPROC

; rcx = field: what the program does when its text changed
PROC field_changed, 2
        cmp     rcx, [edit_client]
        je      .client
        cmp     rcx, [edit_port]
        je      .port
        cmp     rcx, [edit_search]
        jne     .out
        mov     rcx, [hwnd]                     ; search: run the query after a typing pause
        mov     edx, TIMER_SEARCH
        mov     r8d, 350
        xor     r9d, r9d
        call    SetTimer
        jmp     .out
.client: call   on_client_changed
        jmp     .out
.port:  call    on_port_changed
.out:   EPROC

; ---------------------------------------------------------------- selection and cursor helpers
; rcx = field -> eax = selection start, edx = selection end
fld_sel:
        mov     eax, [rcx+FL_CARET]
        mov     edx, [rcx+FL_ANCH]
        cmp     eax, edx
        jbe     .ok
        xchg    eax, edx
.ok:    ret

; rcx = field, edx = position -> eax = the position one character to the left (a surrogate pair counts as one)
fld_prev:
        test    edx, edx
        jz      .zero
        dec     edx
        mov     rax, [rcx+FL_BUF]
        movzx   eax, word [rax+rdx*2]
        and     eax, 0xFC00
        cmp     eax, 0xDC00                     ; a low surrogate: step over its high half too
        jne     .done
        test    edx, edx
        jz      .done
        mov     rax, [rcx+FL_BUF]
        movzx   eax, word [rax+rdx*2-2]
        and     eax, 0xFC00
        cmp     eax, 0xD800
        jne     .done
        dec     edx
.done:  mov     eax, edx
        ret
.zero:  xor     eax, eax
        ret

; rcx = field, edx = position -> eax = the position one character to the right
fld_next:
        mov     eax, [rcx+FL_LEN]
        cmp     edx, eax
        jae     .end
        mov     r8, [rcx+FL_BUF]
        movzx   r9d, word [r8+rdx*2]
        inc     edx
        and     r9d, 0xFC00
        cmp     r9d, 0xD800
        jne     .done
        cmp     edx, eax
        jae     .done
        movzx   r9d, word [r8+rdx*2]
        and     r9d, 0xFC00
        cmp     r9d, 0xDC00
        jne     .done
        inc     edx
.done:  mov     eax, edx
        ret
.end:   ret

; rcx = field, edx = position -> eax = start of the word to the left (blanks, then the word itself)
fld_word_prev:
        mov     r8, [rcx+FL_BUF]
.sp:    test    edx, edx
        jz      .done
        cmp     word [r8+rdx*2-2], ' '
        ja      .wd
        dec     edx
        jmp     .sp
.wd:    test    edx, edx
        jz      .done
        cmp     word [r8+rdx*2-2], ' '
        jbe     .done
        dec     edx
        jmp     .wd
.done:  mov     eax, edx
        ret

; rcx = field, edx = position -> eax = start of the next word
fld_word_next:
        mov     r8, [rcx+FL_BUF]
        mov     eax, [rcx+FL_LEN]
.wd:    cmp     edx, eax
        jae     .done
        cmp     word [r8+rdx*2], ' '
        jbe     .sp
        inc     edx
        jmp     .wd
.sp:    cmp     edx, eax
        jae     .done
        cmp     word [r8+rdx*2], ' '
        ja      .done
        inc     edx
        jmp     .sp
.done:  mov     eax, edx
        ret

; Replaces characters [start, end) by n characters from src.  rcx = field, edx = start, r8d = end, r9 = src, [rbp+48] = n
; Afterwards the caret sits behind the inserted text and nothing is selected.  Notifies.
PROC fld_replace, 4
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r9
        mov     eax, stk5
        mov     loc(3), rax                     ; n
        mov     rbx, rcx
        mov     esi, [rbx+FL_LEN]
        mov     edi, r8d
        sub     edi, edx                        ; removed
        sub     esi, edi                        ; length without the removed part
        mov     eax, [rbx+FL_CAP]
        sub     eax, esi                        ; room for the insertion
        jns     .room
        xor     eax, eax
.room:  mov     ecx, dword loc(3)
        cmp     ecx, eax
        cmova   ecx, eax
        mov     dword loc(3), ecx               ; n clamped to the capacity
        ; move the tail [end, len) to start + n
        mov     rax, [rbx+FL_BUF]
        mov     edx, dword loc(1)               ; start
        mov     r10d, edx
        add     r10d, ecx                       ; new position of the tail
        mov     r11d, r8d                       ; old position of the tail (end)
        mov     r9d, [rbx+FL_LEN]
        sub     r9d, r11d                       ; tail length
        cmp     r10d, r11d
        je      .moved
        ja      .back
        xor     ecx, ecx                        ; towards the front: copy forwards
.fw:    cmp     ecx, r9d
        jae     .moved
        lea     edx, [r11+rcx]
        movzx   edx, word [rax+rdx*2]
        lea     r8d, [r10+rcx]
        mov     [rax+r8*2], dx
        inc     ecx
        jmp     .fw
.back:  mov     ecx, r9d                        ; towards the back: copy backwards
.bw:    test    ecx, ecx
        jz      .moved
        dec     ecx
        lea     edx, [r11+rcx]
        movzx   edx, word [rax+rdx*2]
        lea     r8d, [r10+rcx]
        mov     [rax+r8*2], dx
        jmp     .bw
.moved: ; the new text
        mov     rdi, [rbx+FL_BUF]
        mov     eax, dword loc(1)
        lea     rdi, [rdi+rax*2]
        mov     rsi, loc(2)
        mov     ecx, dword loc(3)
        test    rsi, rsi
        jz      .nosrc
        rep     movsw
.nosrc: mov     ecx, dword loc(1)
        add     ecx, dword loc(3)               ; caret = start + n
        mov     eax, ecx                        ; new length = start + n + tail (the tail length is still in r9d)
        add     eax, r9d
        mov     [rbx+FL_LEN], eax
        mov     rdx, [rbx+FL_BUF]
        mov     word [rdx+rax*2], 0
        mov     [rbx+FL_CARET], ecx
        mov     [rbx+FL_ANCH], ecx
        mov     rcx, rbx
        call    field_changed
        EPROC

; ---------------------------------------------------------------- focus
; ecx = index, edx = 1: select all text (keyboard focus) / 0: caret at the end
PROC field_focus_set, 2
        mov     loc(0), rdx
        mov     [fld_focus], ecx
        inc     dword [fld_focus]
        call    fld_ptr
        mov     ecx, [rax+FL_LEN]
        mov     [rax+FL_CARET], ecx
        xor     edx, edx
        cmp     dword loc(0), 0
        je      .ca
        mov     [rax+FL_ANCH], edx
        jmp     .t
.ca:    mov     [rax+FL_ANCH], ecx
.t:     call    GetTickCount64
        mov     [fld_blink0], rax
        EPROC

field_blur:
        mov     dword [fld_focus], 0
        mov     dword [fld_drag], 0
        ret

; ---------------------------------------------------------------- frame bookkeeping
field_begin_frame:
        inc     dword [fld_stamp]
        ret

; After a frame: honour a focus request, drop the focus of a field that is no longer on screen, run the blink timer.
PROC field_end_frame, 2
        mov     eax, [focus_req]
        test    eax, eax
        jz      .valid
        dec     eax                             ; 1 search, 2 client, 3 port, 4 dialog name  ->  index
        mov     dword [focus_req], 0
        mov     ebx, eax
        mov     ecx, eax
        call    fld_ptr
        mov     ecx, [fld_stamp]
        cmp     [rax+FL_STAMP], ecx
        jne     .valid
        mov     ecx, ebx
        mov     edx, 1
        call    field_focus_set
.valid: mov     eax, [fld_focus]
        test    eax, eax
        jz      .timer
        dec     eax
        mov     ecx, eax
        mov     ebx, eax
        call    fld_ptr
        mov     ecx, [fld_stamp]
        cmp     [rax+FL_STAMP], ecx
        jne     .drop                           ; its page is gone
        cmp     dword [fullscreen], 0
        jne     .drop
        cmp     dword [dlg_kind], 0
        je      .timer
        cmp     ebx, FLD_DNAME                  ; a dialog is open: only its own fields may keep the keyboard
        jae     .timer
.drop:  call    field_blur
.timer: cmp     dword [fld_focus], 0
        je      .stop
        cmp     dword [fld_active], 0
        je      .stop
        cmp     dword [fld_timer], 0
        jne     .out
        mov     dword [fld_timer], 1
        mov     rcx, [hwnd]
        mov     edx, TIMER_CARET
        mov     r8d, 530
        xor     r9d, r9d
        call    SetTimer
        jmp     .out
.stop:  cmp     dword [fld_timer], 0
        je      .out
        mov     dword [fld_timer], 0
        mov     rcx, [hwnd]
        mov     edx, TIMER_CARET
        call    KillTimer
.out:   EPROC

; ---------------------------------------------------------------- drawing
; ecx = index, edx = x, r8d = y, r9d = w, [rbp+48] = h: draws the text (or the hint), selection and caret, and adds the
; hit rectangle.  The caller has already drawn the frame / background.
PROC field_draw, 14
        mov     loc(0), rcx                     ; index
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        mov     eax, stk5
        mov     loc(4), rax
        call    fld_ptr
        mov     rbx, rax
        mov     eax, dword loc(1)
        mov     [rbx+FL_X], eax
        mov     eax, dword loc(2)
        mov     [rbx+FL_Y], eax
        mov     eax, dword loc(3)
        mov     [rbx+FL_W], eax
        mov     eax, dword loc(4)
        mov     [rbx+FL_H], eax
        mov     eax, [fld_stamp]
        mov     [rbx+FL_STAMP], eax
        ; hit rectangle and focus ring: the box the page drew around the field
        mov     eax, dword loc(0)
        mov     [rsp+40], rax
        mov     eax, H_FIELD
        mov     [rsp+32], rax
        mov     ecx, [fld_frame]
        mov     edx, [fld_frame+4]
        mov     r8d, [fld_frame+8]
        mov     r9d, [fld_frame+12]
        call    hit_add
        mov     eax, [fld_focus]
        dec     eax
        cmp     eax, dword loc(0)
        jne     .noring
        cmp     dword [fld_active], 0
        je      .noring
        SETCOL_A T_PRIMARY, 0xB0
        mov     eax, [fld_frame+12]
        shr     eax, 1
        mov     outarg(5), rax
        mov     ecx, [fld_frame]
        mov     edx, [fld_frame+4]
        mov     r8d, [fld_frame+8]
        mov     r9d, [fld_frame+12]
        call    gfx_rrect_line
.noring:
        SETFONT F_BODY
        ; clip to the text rectangle
        mov     ecx, dword loc(1)
        mov     edx, dword loc(2)
        mov     r8d, dword loc(3)
        mov     r9d, dword loc(4)
        call    gfx_clip
        xor     r14d, r14d                      ; focused?
        mov     eax, [fld_focus]
        dec     eax
        cmp     eax, dword loc(0)
        jne     .nf
        mov     r14d, 1
.nf:    mov     esi, [rbx+FL_LEN]
        mov     rdi, [rbx+FL_BUF]
        ; ---- keep the caret in view
        test    r14d, r14d
        jz      .scrolled
        mov     rcx, rdi
        mov     edx, [rbx+FL_CARET]
        call    gfx_tw
        mov     r15d, eax                       ; caret x within the text
        mov     eax, dword loc(3)
        sub     eax, 2
        mov     ecx, r15d
        sub     ecx, [rbx+FL_SCROLL]
        cmp     ecx, eax
        jle     .l1
        mov     ecx, r15d
        sub     ecx, eax
        mov     [rbx+FL_SCROLL], ecx
.l1:    mov     ecx, r15d
        sub     ecx, [rbx+FL_SCROLL]
        jns     .l2
        mov     [rbx+FL_SCROLL], r15d
.l2:    mov     rcx, rdi                        ; text shorter than the box again: no scroll
        mov     edx, esi
        call    gfx_tw
        mov     ecx, dword loc(3)
        cmp     eax, ecx
        jbe     .noscroll
        mov     edx, eax
        sub     edx, ecx
        add     edx, 2
        cmp     [rbx+FL_SCROLL], edx
        jle     .scrolled
        mov     [rbx+FL_SCROLL], edx
        jmp     .scrolled
.noscroll:
        mov     dword [rbx+FL_SCROLL], 0
.scrolled:
        ; ---- selection
        test    r14d, r14d
        jz      .text
        mov     rcx, rbx
        call    fld_sel
        cmp     eax, edx
        je      .text
        mov     r12d, edx                       ; end
        mov     r13d, eax                       ; start
        mov     rcx, rdi
        mov     edx, r13d
        call    gfx_tw
        mov     r15d, eax
        mov     rcx, rdi
        mov     edx, r12d
        call    gfx_tw
        sub     eax, r15d
        mov     r12d, eax                       ; selection width
        SETCOL_A T_ACCENT, 0x90
        mov     ecx, dword loc(1)
        add     ecx, r15d
        sub     ecx, [rbx+FL_SCROLL]
        mov     edx, dword loc(2)
        inc     edx
        mov     r8d, r12d
        mov     r9d, dword loc(4)
        sub     r9d, 2
        call    gfx_rect
.text:  test    esi, esi
        jz      .cue
        SETCOL  T_FG
        mov     rcx, rdi
        mov     edx, esi
        mov     r8d, dword loc(1)
        sub     r8d, [rbx+FL_SCROLL]
        mov     r9d, dword loc(2)
        mov     eax, 20000
        mov     outarg(5), rax
        mov     eax, dword loc(4)
        mov     outarg(6), rax
        call    gfx_tdraw
        jmp     .caret
.cue:   mov     rsi, [rbx+FL_CUE]
        test    rsi, rsi
        jz      .caret
        SETCOL  T_MUTED_FG
        xor     edx, edx                        ; length of the hint
.cl:    cmp     word [rsi+rdx*2], 0
        je      .cd
        inc     edx
        jmp     .cl
.cd:    mov     rcx, rsi
        mov     r8d, dword loc(1)
        mov     r9d, dword loc(2)
        mov     eax, dword loc(3)
        mov     outarg(5), rax
        mov     eax, dword loc(4)
        mov     outarg(6), rax
        call    gfx_tdraw
.caret: test    r14d, r14d
        jz      .unclip
        cmp     dword [fld_active], 0
        je      .unclip
        call    GetTickCount64
        sub     rax, [fld_blink0]
        xor     edx, edx
        mov     ecx, 530
        div     rcx
        test    al, 1
        jnz     .unclip                         ; blinked off
        mov     rcx, [rbx+FL_BUF]
        mov     edx, [rbx+FL_CARET]
        call    gfx_tw
        mov     r15d, eax
        SETCOL  T_FG
        S       18
        mov     r12d, eax                       ; caret height
        mov     eax, dword loc(4)
        sub     eax, r12d
        sar     eax, 1
        add     eax, dword loc(2)
        mov     edx, eax
        S       1
        mov     r8d, eax
        mov     ecx, dword loc(1)
        add     ecx, r15d
        sub     ecx, [rbx+FL_SCROLL]
        mov     r9d, r12d
        call    gfx_rect
.unclip:
        mov     ecx, [clip_x0]                  ; back to the page's own clip
        mov     edx, [clip_y0]
        mov     r8d, [clip_x1]
        sub     r8d, ecx
        mov     r9d, [clip_y1]
        sub     r9d, edx
        call    gfx_clip
        EPROC

; ---------------------------------------------------------------- mouse
; ecx = index, edx = mouse x, r8d = 1: keep the selection anchor (dragging / shift)
PROC field_mouse, 6
        mov     loc(0), rcx
        mov     loc(1), r8
        mov     loc(3), rdx                     ; fld_ptr uses rdx
        call    fld_ptr
        mov     rbx, rax
        SETFONT F_BODY
        mov     eax, dword loc(3)
        sub     eax, [rbx+FL_X]
        add     eax, [rbx+FL_SCROLL]
        mov     loc(2), rax                     ; x inside the text
        xor     esi, esi                        ; lo
        mov     edi, [rbx+FL_LEN]               ; hi
.bs:    cmp     esi, edi
        jae     .found
        lea     r12d, [rsi+rdi+1]
        shr     r12d, 1                         ; mid, rounded up
        mov     rcx, [rbx+FL_BUF]
        mov     edx, r12d
        call    gfx_tw
        cmp     eax, dword loc(2)
        jg      .hi
        mov     esi, r12d
        jmp     .bs
.hi:    lea     edi, [r12-1]
        jmp     .bs
.found: cmp     esi, [rbx+FL_LEN]               ; between esi and esi + 1: the nearer boundary
        jae     .pos
        mov     rcx, [rbx+FL_BUF]
        mov     edx, esi
        call    gfx_tw
        mov     r12d, eax
        mov     rcx, rbx
        mov     edx, esi
        call    fld_next
        mov     r13d, eax
        mov     rcx, [rbx+FL_BUF]
        mov     edx, r13d
        call    gfx_tw
        mov     ecx, dword loc(2)
        sub     ecx, r12d                       ; distance to the left boundary
        sub     eax, dword loc(2)               ; distance to the right one
        cmp     ecx, eax
        jle     .pos
        mov     esi, r13d
.pos:   mov     [rbx+FL_CARET], esi
        cmp     dword loc(1), 0
        jne     .keep
        mov     [rbx+FL_ANCH], esi
.keep:  call    GetTickCount64
        mov     [fld_blink0], rax
        EPROC

; ---------------------------------------------------------------- keyboard
; ecx = index, edx = unit: one typed character
PROC field_char, 2
        cmp     edx, 32
        jb      .out
        cmp     edx, 127
        je      .out
        cmp     ecx, FLD_PORT                   ; the port takes digits only
        jne     .ok
        cmp     edx, '0'
        jb      .out
        cmp     edx, '9'
        ja      .out
.ok:    mov     word [fld_ibuf], dx
        call    fld_ptr
        mov     rbx, rax
        mov     rcx, rbx
        call    fld_sel
        mov     rcx, rbx
        mov     r8d, edx
        mov     edx, eax
        lea     r9, [fld_ibuf]
        mov     qword outarg(5), 1
        call    fld_replace
        call    GetTickCount64
        mov     [fld_blink0], rax
.out:   EPROC

; ecx = index, edx = virtual key, r8d = FK_* modifiers -> eax = 1 when the key belongs to the field
PROC field_key, 6
        mov     loc(0), rcx
        mov     esi, edx                        ; key
        mov     edi, r8d                        ; modifiers
        call    fld_ptr
        mov     rbx, rax
        call    GetTickCount64
        mov     [fld_blink0], rax
        mov     eax, 1
        cmp     esi, 0x70                       ; F1.. : not ours (F11 toggles full screen)
        jb      .mine
        xor     eax, eax
        jmp     .out
.mine:  cmp     esi, 8                          ; VK_BACK
        je      .back
        cmp     esi, 46                         ; VK_DELETE
        je      .del
        cmp     esi, 37
        je      .left
        cmp     esi, 39
        je      .right
        cmp     esi, 36
        je      .home
        cmp     esi, 35
        je      .end
        cmp     esi, 13
        je      .enter
        cmp     esi, 27
        je      .esc
        cmp     esi, 9
        je      .tab
        test    edi, FK_CTRL
        jz      .ret1
        cmp     esi, 'A'
        je      .all
        cmp     esi, 'C'
        je      .copy
        cmp     esi, 'X'
        je      .cut
        cmp     esi, 'V'
        je      .paste
.ret1:  mov     eax, 1
        jmp     .out
; ---- editing
.back:  mov     rcx, rbx
        call    fld_sel
        cmp     eax, edx
        jne     .delsel
        test    eax, eax
        jz      .ret1
        mov     r12d, eax                       ; caret
        mov     rcx, rbx
        mov     edx, eax
        test    edi, FK_CTRL
        jz      .bone
        call    fld_word_prev
        jmp     .bdo
.bone:  call    fld_prev
.bdo:   mov     edx, eax
        mov     r8d, r12d
        jmp     .rm
.del:   mov     rcx, rbx
        call    fld_sel
        cmp     eax, edx
        jne     .delsel
        cmp     eax, [rbx+FL_LEN]
        jae     .ret1
        mov     r12d, eax
        mov     rcx, rbx
        mov     edx, eax
        test    edi, FK_CTRL
        jz      .done1
        call    fld_word_next
        jmp     .ddo
.done1: call    fld_next
.ddo:   mov     r8d, eax
        mov     edx, r12d
        jmp     .rm
.delsel: mov     r8d, edx
        mov     edx, eax
.rm:    mov     rcx, rbx
        xor     r9d, r9d
        mov     qword outarg(5), 0
        call    fld_replace
        jmp     .ret1
; ---- movement (shift extends the selection)
.left:  mov     rcx, rbx
        mov     edx, [rbx+FL_CARET]
        test    edi, FK_SHIFT
        jnz     .lmove
        mov     r12d, [rbx+FL_ANCH]
        cmp     r12d, edx
        je      .lmove
        call    fld_sel                         ; a selection collapses to its start
        mov     edx, eax
        jmp     .setc
.lmove: test    edi, FK_CTRL
        jz      .l1
        call    fld_word_prev
        jmp     .setc2
.l1:    call    fld_prev
        jmp     .setc2
.right: mov     rcx, rbx
        mov     edx, [rbx+FL_CARET]
        test    edi, FK_SHIFT
        jnz     .rmove
        mov     r12d, [rbx+FL_ANCH]
        cmp     r12d, edx
        je      .rmove
        call    fld_sel                         ; ... and to its end
        jmp     .setc
.rmove: test    edi, FK_CTRL
        jz      .r1
        call    fld_word_next
        jmp     .setc2
.r1:    call    fld_next
        jmp     .setc2
.home:  xor     eax, eax
        jmp     .setc2
.end:   mov     eax, [rbx+FL_LEN]
        jmp     .setc2
.setc:  mov     eax, edx
        mov     [rbx+FL_CARET], eax
        mov     [rbx+FL_ANCH], eax
        jmp     .ret1
.setc2: mov     [rbx+FL_CARET], eax
        test    edi, FK_SHIFT
        jnz     .ret1
        mov     [rbx+FL_ANCH], eax
        jmp     .ret1
.all:   mov     dword [rbx+FL_ANCH], 0
        mov     eax, [rbx+FL_LEN]
        mov     [rbx+FL_CARET], eax
        jmp     .ret1
; ---- clipboard
.copy:  mov     rcx, rbx
        call    fld_copy
        jmp     .ret1
.cut:   mov     rcx, rbx
        call    fld_copy
        mov     rcx, rbx
        call    fld_sel
        cmp     eax, edx
        je      .ret1
        jmp     .delsel
.paste: mov     rcx, rbx
        call    fld_paste
        jmp     .ret1
; ---- Enter / Esc / Tab
.enter: cmp     dword [dlg_kind], 0
        je      .searchq
        mov     edx, WM_DLG_OK
        jmp     .post
.searchq: cmp   dword loc(0), FLD_SEARCH
        jne     .ret1
        mov     edx, WM_SEARCH_NOW
        jmp     .post
.esc:   cmp     dword [dlg_kind], 0
        je      .blur
        mov     edx, WM_DLG_CANCEL
.post:  mov     rcx, [hwnd]
        xor     r8d, r8d
        xor     r9d, r9d
        call    PostMessageW
        jmp     .ret1
.blur:  call    field_blur
        jmp     .ret1
.tab:   mov     ecx, dword loc(0)
        mov     edx, 1
        test    edi, FK_SHIFT
        jz      .tn
        mov     edx, FLD_N-1                    ; one step back = FLD_N - 1 forward
.tn:    mov     r12d, edx
        mov     r13d, ecx
        xor     r14d, r14d
.try:   inc     r14d
        cmp     r14d, FLD_N
        ja      .ret1
        lea     eax, [r13+r12]
        xor     edx, edx
        mov     ecx, FLD_N
        div     ecx
        mov     r13d, edx                       ; candidate index
        mov     ecx, r13d
        call    fld_ptr
        mov     ecx, [fld_stamp]
        cmp     [rax+FL_STAMP], ecx             ; shown on this page?
        jne     .try
        mov     ecx, r13d
        mov     edx, 1
        call    field_focus_set
        jmp     .ret1
.out:   EPROC

; rcx = field: the selection to the clipboard (UTF-8 through os_clipboard)
PROC fld_copy, 4
        mov     loc(0), rcx
        call    fld_sel
        cmp     eax, edx
        je      .out
        mov     rcx, loc(0)
        mov     rsi, [rcx+FL_BUF]
        lea     rsi, [rsi+rax*2]                ; start of the selection
        sub     edx, eax
        mov     loc(1), rdx                     ; characters
        lea     rcx, [rdx*2+2]
        call    mem_alloc                       ; zeroed: the copy is NUL-terminated
        mov     loc(2), rax
        mov     rcx, rax
        mov     rdx, rsi
        mov     r8, loc(1)
        shl     r8, 1
        call    mem_copy
        mov     rcx, loc(2)
        mov     rdx, -1
        call    w_to_u8
        mov     loc(3), rax
        mov     rcx, rax
        call    os_clipboard
        mov     rcx, loc(3)
        call    mem_free
        mov     rcx, loc(2)
        call    mem_free
.out:   EPROC

; rcx = field: the clipboard text replaces the selection (line breaks become blanks)
PROC fld_paste, 4
        mov     loc(0), rcx
        call    os_clipboard_get
        test    rax, rax
        jz      .out
        mov     loc(1), rax
        mov     rsi, rax                        ; flatten and measure
        xor     ecx, ecx
.f:     movzx   eax, word [rsi+rcx*2]
        test    eax, eax
        jz      .done
        cmp     eax, 32
        jae     .n
        mov     word [rsi+rcx*2], ' '
.n:     inc     ecx
        jmp     .f
.done:  mov     loc(2), rcx
        mov     rcx, loc(0)
        call    fld_sel
        mov     rcx, loc(0)
        mov     r8d, edx
        mov     edx, eax
        mov     r9, loc(1)
        mov     rax, loc(2)
        mov     outarg(5), rax
        call    fld_replace
        mov     rcx, loc(1)
        call    mem_free
.out:   EPROC

; the dialog / search shortcuts of the old EDIT subclass, now part of field_key; kept for the test hook
; ecx = key -> eax = 1 when a field is focused and took it (used by the window procedure)
PROC field_win_key, 2
        mov     eax, [fld_focus]
        test    eax, eax
        jz      .no
        mov     loc(0), rcx
        mov     ecx, VK_SHIFT
        call    GetKeyState
        xor     r8d, r8d
        test    ax, 0x8000
        jz      .s
        mov     r8d, FK_SHIFT
.s:     mov     esi, r8d
        mov     ecx, VK_CONTROL
        call    GetKeyState
        test    ax, 0x8000
        jz      .c
        or      esi, FK_CTRL
.c:     mov     ecx, [fld_focus]
        dec     ecx
        mov     rdx, loc(0)
        mov     r8d, esi
        call    field_key
        jmp     .out
.no:    xor     eax, eax
.out:   EPROC

; ecx = unit: a typed character for the focused field -> eax = 1 when taken
PROC field_win_char, 2
        mov     edx, ecx
        mov     ecx, [fld_focus]
        test    ecx, ecx
        jz      .no
        dec     ecx
        call    field_char
        mov     eax, 1
        jmp     .out
.no:    xor     eax, eax
.out:   EPROC
