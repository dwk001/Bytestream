; stubs.asm - placeholders for the live-Spotify pieces that land in later milestones.
; Each one is replaced by a real implementation; until then the app runs in --demo mode only.

real_play_list:
real_toggle:
real_next:
real_prev:
real_seek:
real_set_volume:
real_load_detail:
real_sign_in:
real_sign_out:
real_search:
fetch_image_async:
        ret

; WM_APP+n messages posted by worker threads: rcx = wParam, rdx = lParam, r8d = message
app_message:
        ret
