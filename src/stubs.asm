; stubs.asm - placeholders for the live-Spotify pieces that land in later milestones.
; Each one is replaced by a real implementation; until then the app runs in --demo mode only.

; Sign in with Spotify: validate the setup fields, then start the browser flow
PROC real_sign_in, 0
        call    app_sign_in_check
        test    eax, eax
        jz      .out
        call    auth_begin
.out:   EPROC

PROC real_sign_out, 0
        cmp     dword [g_demo], 0
        jne     .out                            ; demo mode is handled by the caller
        call    auth_sign_out
.out:   EPROC

; WM_APP+n messages posted by worker threads: rcx = wParam, rdx = lParam, r8d = message
PROC app_message, 0
        cmp     r8d, WM_NET_DONE
        je      .net
        cmp     r8d, WM_AUTH_CB
        je      .auth
        cmp     r8d, WM_BRIDGE_EVENT
        je      .bridge
        cmp     r8d, WM_DLG_OK
        je      .dlgok
        cmp     r8d, WM_DLG_CANCEL
        je      .dlgcancel
        cmp     r8d, WM_SEARCH_NOW
        je      .searchnow
        jmp     .out
.net:   call    net_dispatch
        jmp     .out
.auth:  call    auth_on_callback                ; rcx = heap string, rdx = kind
        jmp     .out
.bridge: call   bridge_event                    ; rcx = heap JSON, rdx = length
        jmp     .out
.dlgok: cmp     dword [dlg_kind], 0             ; Enter in a dialog field
        je      .out
        call    dlg_commit
        jmp     .repaint
.dlgcancel:
        call    dlg_clear                       ; Esc in a dialog field
        jmp     .repaint
.searchnow:
        mov     rcx, [hwnd]                     ; Enter in the search box: do not wait for the typing pause
        mov     edx, TIMER_SEARCH
        call    KillTimer
        call    ui_run_search
.repaint:
        mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
.out:   EPROC
