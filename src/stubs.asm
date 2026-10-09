; stubs.asm - placeholders for the live-Spotify pieces that land in later milestones.
; Each one is replaced by a real implementation; until then the app runs in --demo mode only.

; installs a fresh access token using the stored refresh token; 1 = success (milestone 2)
auth_refresh_blocking:
        xor     eax, eax
        ret

real_play_list:
real_toggle:
real_next:
real_prev:
real_seek:
real_set_volume:
real_load_detail:
real_sign_out:
real_search:
fetch_image_async:
        ret

; Sign in with Spotify (milestone 2 replaces the second half)
PROC real_sign_in, 0
        call    app_sign_in_check
        test    eax, eax
        jz      .out
        lea     rcx, [w_signin_soon]
        xor     edx, edx
        xor     r8d, r8d
        call    ui_banner
.out:   EPROC

; WM_APP+n messages posted by worker threads: rcx = wParam, rdx = lParam, r8d = message
PROC app_message, 0
        cmp     r8d, WM_NET_DONE
        jne     .out
        call    net_dispatch
.out:   EPROC
