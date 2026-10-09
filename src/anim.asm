; anim.asm - frame clock and eased values.
;
; Nothing here runs while the window is idle.  A frame timer (TIMER_ANIM, 16 ms) exists only while something is
; moving: a hover fade, a smooth scroll, the queue panel or the full-screen view sliding.  Every step measures
; real time with QueryPerformanceCounter, so a slow frame moves things further instead of slowing them down.
;
; Values are 16.16 fractions (0 .. 65536).  anim_get / anim_hv return them eased (ease-out cubic) as 0 .. 256.
; With anim_on = 0 (tests: --dump / --screenshot without --anim) every value snaps to its target at once.

extern QueryPerformanceCounter, QueryPerformanceFrequency, SetTimer, KillTimer

%define TIMER_ANIM      3
%define ANIM_FRAME_MS   16

%define AC_QUEUE        0               ; fixed channels: the state they follow
%define AC_FULL         1
%define AC_MENU         2
%define AC_DLG          3
%define AC_TOAST        4
%define AC_N            5

%define AH_N            8               ; hover fades running at the same time
%define AS_N            3               ; smooth-scroll areas: main page, sidebar, queue

section .bss
                align 8
anim_freq:      resq 1
anim_last:      resq 1                  ; milliseconds at the previous step (0 = no animation running)
anim_tmp:       resq 1
anim_on:        resd 1                  ; animations enabled
anim_running:   resd 1                  ; the frame timer exists
anim_busy:      resd 1                  ; something still moving after the last step
anim_dt:        resd 1                  ; milliseconds covered by the current step
anim_frames:    resd 1                  ; steps taken (--dump)
ui_dy:          resd 1                  ; vertical shift applied to what is being drawn (hit rectangles follow it)
anim_hk_id:     resd 1                  ; hovered thing, rows and cards normalised
anim_hk_arg:    resd 1
anim_v:         resd AC_N
anim_tg:        resd AC_N
anim_h_id:      resd AH_N
anim_h_arg:     resd AH_N
anim_h_v:       resd AH_N
anim_s_t:       resd AS_N               ; smooth scroll: target, the value we last wrote, active
anim_s_last:    resd AS_N
anim_s_on:      resd AS_N

section .data
                align 8
anim_dur:       dd 240, 280, 120, 140, 200      ; ms to travel 0 -> 1 per fixed channel
anim_s_ptr:     dq scroll_main, scroll_side, scroll_queue

section .text

PROC anim_init, 0
        lea     rcx, [anim_freq]
        call    QueryPerformanceFrequency
        cmp     qword [anim_freq], 0
        jne     .ok
        mov     qword [anim_freq], 1000
.ok:    mov     dword [anim_on], 1
        EPROC

; -> rax = milliseconds on the performance counter
PROC anim_now, 0
        lea     rcx, [anim_tmp]
        call    QueryPerformanceCounter
        mov     rax, [anim_tmp]
        imul    rax, 1000
        xor     edx, edx
        div     qword [anim_freq]
        EPROC

; ecx = 0 .. 65536 -> eax = eased 0 .. 256 (ease-out cubic)
anim_ease:
        mov     eax, 65536
        sub     eax, ecx                        ; u = 1 - t
        mov     edx, eax
        imul    rax, rdx
        shr     rax, 16
        imul    rax, rdx
        shr     rax, 16                         ; u^3
        mov     ecx, 65536
        sub     ecx, eax
        shr     ecx, 8
        mov     eax, ecx
        ret

; ecx = AC_* -> eax = eased value 0 .. 256
anim_get:
        lea     rax, [anim_v]
        mov     ecx, [rax+rcx*4]
        jmp     anim_ease

; ecx = id, edx = arg -> eax = eased fade 0 .. 256 of a hover on that row / card / button (0 = none running)
anim_hv:
        lea     r8, [anim_h_id]
        xor     r9d, r9d
.l:     cmp     [r8+r9*4], ecx
        jne     .n
        lea     rax, [anim_h_arg]
        cmp     [rax+r9*4], edx
        jne     .n
        lea     rax, [anim_h_v]
        mov     ecx, [rax+r9*4]
        jmp     anim_ease
.n:     inc     r9d
        cmp     r9d, AH_N
        jb      .l
        xor     eax, eax
        ret

; ecx = ARGB, edx = factor 0 .. 256 -> eax = the colour with its alpha scaled
col_alpha_scale:
        mov     eax, ecx
        shr     eax, 24
        imul    eax, edx
        shr     eax, 8
        shl     eax, 24
        and     ecx, 0x00FFFFFF
        or      eax, ecx
        ret

; ecx = colour 0, edx = colour 1, r8d = factor 0 .. 256 -> eax = colour 0 + (colour 1 - colour 0) * factor, per byte
col_lerp:
        mov     r9d, 256
        sub     r9d, r8d                        ; weight of colour 0
        mov     eax, ecx
        and     eax, 0x00FF00FF
        imul    eax, r9d
        mov     r10d, edx
        and     r10d, 0x00FF00FF
        imul    r10d, r8d
        add     eax, r10d
        shr     eax, 8
        and     eax, 0x00FF00FF                 ; red and blue
        mov     r11d, ecx
        shr     r11d, 8
        and     r11d, 0x00FF00FF
        imul    r11d, r9d
        mov     r10d, edx
        shr     r10d, 8
        and     r10d, 0x00FF00FF
        imul    r10d, r8d
        add     r11d, r10d
        and     r11d, 0xFF00FF00                ; alpha and green
        or      eax, r11d
        ret

; SETCOL_F token, factor : the theme colour with its alpha scaled by factor (0 .. 256, a register)
%macro SETCOL_F 2
        mov     ecx, [th+4*(%1)]
        mov     edx, %2
        call    col_alpha_scale
        mov     ecx, eax
        call    gfx_color
%endmacro

; SETCOL_AR token, alpha : the theme colour with this alpha (0 .. 255, a register)
%macro SETCOL_AR 2
        mov     ecx, [th+4*(%1)]
        and     ecx, 0x00FFFFFF
        mov     edx, %2
        shl     edx, 24
        or      ecx, edx
        call    gfx_color
%endmacro

; SETCOL_MIX token0, token1, factor : colour fading from token0 to token1
%macro SETCOL_MIX 3
        mov     ecx, [th+4*(%1)]
        mov     edx, [th+4*(%2)]
        mov     r8d, %3
        call    col_lerp
        mov     ecx, eax
        call    gfx_color
%endmacro

; Moves v (eax) towards target (edx) by step (ecx); returns the new v in eax
anim_approach:
        cmp     eax, edx
        je      .done
        jb      .up
        sub     eax, ecx
        jbe     .snap
        cmp     eax, edx
        jb      .snap
        ret
.up:    add     eax, ecx
        cmp     eax, edx
        ja      .snap
        ret
.snap:  mov     eax, edx
.done:  ret

; One frame of animation, called before a full repaint.
PROC anim_step, 8
        inc     dword [anim_frames]
        mov     dword [anim_busy], 0
        call    anim_now
        mov     rcx, [anim_last]
        mov     [anim_last], rax
        xor     edx, edx                        ; first step of a run: nothing has moved yet
        test    rcx, rcx
        jz      .dt
        sub     rax, rcx
        mov     edx, eax
        cmp     edx, 50
        jbe     .dt
        mov     edx, 50
.dt:    mov     [anim_dt], edx
        ; ---- targets of the fixed channels follow the UI state
        lea     r8, [anim_tg]
        xor     eax, eax
        cmp     dword [queue_open], 0
        je      .t0
        cmp     dword [page], PAGE_LOGIN
        je      .t0
        mov     eax, 65536
.t0:    mov     [r8+AC_QUEUE*4], eax
        xor     eax, eax
        cmp     dword [fullscreen], 0
        je      .t1
        mov     eax, 65536
.t1:    mov     [r8+AC_FULL*4], eax
        xor     eax, eax
        cmp     dword [menu_open], 0
        je      .t2
        mov     eax, 65536
.t2:    mov     [r8+AC_MENU*4], eax
        xor     eax, eax
        cmp     dword [dlg_kind], 0
        je      .t3
        mov     eax, 65536
.t3:    mov     [r8+AC_DLG*4], eax
        xor     eax, eax
        cmp     qword [toast_text], 0
        je      .t4
        mov     eax, 65536
.t4:    mov     [r8+AC_TOAST*4], eax
        xor     r12d, r12d
.fix:   lea     rax, [anim_tg]
        mov     edx, [rax+r12*4]
        lea     rax, [anim_v]
        mov     eax, [rax+r12*4]
        cmp     dword [anim_on], 0
        je      .snap
        cmp     r12d, AC_MENU                   ; what they show is gone the moment they close: no fade-out
        jb      .move
        test    edx, edx
        jnz     .move
.snap:  mov     eax, edx
        jmp     .store
.move:  lea     rcx, [anim_dur]
        mov     ecx, [rcx+r12*4]
        mov     r8d, 65536
        imul    r8d, dword [anim_dt]
        mov     eax, r8d
        mov     r8d, edx                        ; keep the target
        xor     edx, edx
        div     ecx                             ; step = dt * 65536 / duration
        mov     ecx, eax
        lea     rax, [anim_v]
        mov     eax, [rax+r12*4]
        mov     edx, r8d
        call    anim_approach
.store: cmp     r12d, AC_FULL                   ; --anim-hold: the two sliding views stand still part of the way
        ja      .st2
        cmp     dword [cli_anim_hold], 0
        je      .st2
        test    edx, edx
        jz      .st2
        mov     eax, [cli_anim_hold]
        imul    eax, 655
        lea     rcx, [anim_v]
        mov     [rcx+r12*4], eax
        jmp     .fixn                           ; held: not moving, so no frame timer
.st2:   lea     rcx, [anim_v]
        mov     [rcx+r12*4], eax
        lea     rcx, [anim_tg]
        cmp     eax, [rcx+r12*4]
        je      .fixn
        mov     dword [anim_busy], 1
.fixn:  inc     r12d
        cmp     r12d, AC_N
        jb      .fix
        ; ---- hover fades: rows and cards count as hovered while their heart / play button is under the mouse
        mov     eax, [hover_id]
        mov     edx, [hover_arg]
        cmp     eax, H_LIKE
        jne     .h1
        mov     eax, H_TRACK
.h1:    cmp     eax, H_CARD_PLAY
        jne     .h2
        mov     eax, H_CARD
.h2:    mov     [anim_hk_id], eax
        mov     [anim_hk_arg], edx
        test    eax, eax
        jz      .hscan
        xor     r12d, r12d                      ; already has a channel?
.hf:    lea     rcx, [anim_h_id]
        cmp     [rcx+r12*4], eax
        jne     .hn
        lea     rcx, [anim_h_arg]
        cmp     [rcx+r12*4], edx
        je      .hscan
.hn:    inc     r12d
        cmp     r12d, AH_N
        jb      .hf
        xor     r12d, r12d                      ; no: take a free slot, else the weakest one
        mov     r13d, 0xFFFFFFFF
        xor     r14d, r14d
.hs:    lea     rcx, [anim_h_id]
        cmp     dword [rcx+r12*4], 0
        je      .hpick
        lea     rcx, [anim_h_v]
        mov     ecx, [rcx+r12*4]
        cmp     ecx, r13d
        jae     .hsn
        mov     r13d, ecx
        mov     r14d, r12d
.hsn:   inc     r12d
        cmp     r12d, AH_N
        jb      .hs
        mov     r12d, r14d
.hpick: mov     eax, [anim_hk_id]
        mov     edx, [anim_hk_arg]
        lea     rcx, [anim_h_id]
        mov     [rcx+r12*4], eax
        lea     rcx, [anim_h_arg]
        mov     [rcx+r12*4], edx
        lea     rcx, [anim_h_v]
        mov     dword [rcx+r12*4], 0
.hscan: xor     r12d, r12d
.hl:    lea     rcx, [anim_h_id]
        mov     eax, [rcx+r12*4]
        test    eax, eax
        jz      .hnext
        xor     edx, edx                        ; target: 65536 while hovered
        cmp     eax, [anim_hk_id]
        jne     .hc
        lea     rcx, [anim_h_arg]
        mov     ecx, [rcx+r12*4]
        cmp     ecx, [anim_hk_arg]
        jne     .hc
        mov     edx, 65536
.hc:    lea     rcx, [anim_h_v]
        mov     eax, [rcx+r12*4]
        cmp     dword [anim_on], 0
        je      .hsnap
        mov     r13d, edx                       ; fade in over 100 ms, out over 170 ms
        mov     r8d, 65536
        imul    r8d, dword [anim_dt]
        mov     eax, r8d
        mov     ecx, 100
        test    edx, edx
        jnz     .hdiv
        mov     ecx, 170
.hdiv:  xor     edx, edx
        div     ecx
        mov     ecx, eax
        lea     rax, [anim_h_v]
        mov     eax, [rax+r12*4]
        mov     edx, r13d
        call    anim_approach
        jmp     .hstore
.hsnap: mov     eax, edx
.hstore: lea     rcx, [anim_h_v]
        mov     [rcx+r12*4], eax
        test    eax, eax
        jnz     .hbusy
        test    edx, edx
        jnz     .hbusy
        lea     rcx, [anim_h_id]                ; faded out and not hovered: free the slot
        mov     dword [rcx+r12*4], 0
        jmp     .hnext
.hbusy: cmp     eax, edx
        je      .hnext
        mov     dword [anim_busy], 1
.hnext: inc     r12d
        cmp     r12d, AH_N
        jb      .hl
        ; ---- smooth scrolling
        xor     r12d, r12d
.sl:    lea     rax, [anim_s_on]
        cmp     dword [rax+r12*4], 0
        je      .sn
        lea     rax, [anim_s_ptr]
        mov     rsi, [rax+r12*8]
        mov     eax, [rsi]                      ; the value painted last frame
        lea     rcx, [anim_s_last]
        cmp     eax, [rcx+r12*4]
        jne     .sstop                          ; something else moved it (page change, clamp): leave it there
        lea     rcx, [anim_s_t]
        mov     edx, [rcx+r12*4]
        sub     edx, eax                        ; distance left
        jz      .sstop
        mov     ecx, edx
        sar     ecx, 31
        mov     r13d, ecx                       ; sign mask
        xor     edx, ecx
        sub     edx, ecx                        ; |distance|
        mov     r8d, [anim_dt]
        imul    r8d, edx
        mov     eax, r8d
        xor     edx, edx
        mov     ecx, 90                         ; closes 1 - e^(-dt/90ms) of the distance, about 16 % at 60 fps
        div     ecx
        test    eax, eax
        jnz     .smv
        mov     eax, 1                          ; always move at least a pixel
.smv:   xor     eax, r13d
        sub     eax, r13d                       ; back to signed
        lea     rcx, [anim_s_t]
        mov     edx, [rcx+r12*4]
        mov     ecx, [rsi]
        add     ecx, eax
        ; do not step past the target
        mov     r8d, edx
        sub     r8d, ecx
        xor     r8d, eax
        jns     .sok                            ; same direction: still short of it
        mov     ecx, edx
.sok:   mov     [rsi], ecx
        lea     rax, [anim_s_last]
        mov     [rax+r12*4], ecx
        cmp     ecx, edx
        je      .sstop
        mov     dword [anim_busy], 1
        jmp     .sn
.sstop: lea     rax, [anim_s_on]
        mov     dword [rax+r12*4], 0
.sn:    inc     r12d
        cmp     r12d, AS_N
        jb      .sl
        EPROC

; ecx = area (0 main, 1 sidebar, 2 queue), edx = pixels: scrolls by that much, smoothly when animations are on
PROC anim_scroll_add, 0
        lea     rax, [anim_s_ptr]
        mov     r8, [rax+rcx*8]
        cmp     dword [anim_on], 0
        jne     .smooth
        add     [r8], edx
        jmp     .out
.smooth:
        lea     rax, [anim_s_on]
        cmp     dword [rax+rcx*4], 0
        jne     .have
        mov     dword [rax+rcx*4], 1
        mov     r9d, [r8]
        lea     rax, [anim_s_t]
        mov     [rax+rcx*4], r9d
        lea     rax, [anim_s_last]
        mov     [rax+rcx*4], r9d
.have:  lea     rax, [anim_s_t]
        add     [rax+rcx*4], edx
.out:   EPROC

; After a full repaint: keep the frame timer running while something moves, drop it (and the clock) when not.
PROC anim_frame_end, 0
        cmp     dword [anim_busy], 0
        je      .stop
        cmp     dword [anim_running], 0
        jne     .out
        mov     dword [anim_running], 1
        mov     rcx, [hwnd]
        mov     edx, TIMER_ANIM
        mov     r8d, ANIM_FRAME_MS
        xor     r9d, r9d
        call    SetTimer
        jmp     .out
.stop:  mov     qword [anim_last], 0
        cmp     dword [anim_running], 0
        je      .out
        mov     dword [anim_running], 0
        mov     rcx, [hwnd]
        mov     edx, TIMER_ANIM
        call    KillTimer
.out:   EPROC
