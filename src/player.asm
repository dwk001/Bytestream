; player.asm - "now playing" state and the transport API the UI talks to.
;
; In --demo mode a small in-process engine simulates playback (position clock, queue, auto-advance)
; so the whole UI can be exercised offline.  In normal mode every player_* call is forwarded to the
; Spotify Web Playback SDK bridge (spotify_player.asm), which feeds np_* back from SDK events.

extern GetTickCount64, lstrlenW

%define REPEAT_OFF   0
%define REPEAT_ALL   1
%define REPEAT_ONE   2

section .bss
g_demo:         resd 1
np_valid:       resd 1
np_paused:      resd 1
np_pos:         resd 1                  ; ms at np_tick
np_dur:         resd 1
np_vol:         resd 1                  ; 0..100
np_shuffle:     resd 1
np_repeat:      resd 1
np_tick:        resq 1
np_gen:         resd 1                  ; bumped whenever the current track changes
np_title:       resq 1                  ; UTF-16, owned
np_artist:      resq 1
np_album:       resq 1
np_uri:         resq 1                  ; UTF-8, owned
np_img_s:       resq 1
np_img_l:       resq 1
q_up:           resq 3                  ; upcoming tracks (List of Track, owned copies)

section .text

; rcx = UTF-16 string (or 0) -> rax = heap copy ("" when 0)
PROC w_dup, 1
        test    rcx, rcx
        jnz     .go
        mov     ecx, 2
        call    mem_alloc
        jmp     .out
.go:    mov     loc(0), rcx
        call    lstrlenW
        lea     rcx, [rax*2+2]
        mov     loc(1), rcx
        call    mem_alloc
        mov     rcx, rax
        mov     rdx, loc(0)
        mov     r8, loc(1)
        call    mem_copy
.out:   EPROC

; rcx = UTF-8 string (or 0) -> rax = heap copy (0 stays 0)
u8_dup0:
        test    rcx, rcx
        jz      .z
        jmp     u8_dup
.z:     xor     eax, eax
        ret

; rcx = source Track*, rdx = destination Track* (zeroed): deep copy
PROC track_copy, 2
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     rcx, [rcx+TR_TITLE]
        call    w_dup
        mov     rdx, loc(1)
        mov     [rdx+TR_TITLE], rax
        mov     rcx, loc(0)
        mov     rcx, [rcx+TR_ARTIST]
        call    w_dup
        mov     rdx, loc(1)
        mov     [rdx+TR_ARTIST], rax
        mov     rcx, loc(0)
        mov     rcx, [rcx+TR_ALBUM]
        call    w_dup
        mov     rdx, loc(1)
        mov     [rdx+TR_ALBUM], rax
        mov     rcx, loc(0)
        mov     rcx, [rcx+TR_URI]
        call    u8_dup0
        mov     rdx, loc(1)
        mov     [rdx+TR_URI], rax
        mov     rcx, loc(0)
        mov     rcx, [rcx+TR_IMG_S]
        call    u8_dup0
        mov     rdx, loc(1)
        mov     [rdx+TR_IMG_S], rax
        mov     rcx, loc(0)
        mov     rcx, [rcx+TR_IMG_L]
        call    u8_dup0
        mov     rdx, loc(1)
        mov     [rdx+TR_IMG_L], rax
        mov     rcx, loc(0)
        mov     eax, [rcx+TR_DUR]
        mov     [rdx+TR_DUR], eax
        EPROC

PROC np_clear, 0
        mov     rcx, [np_title]
        call    mem_free
        mov     rcx, [np_artist]
        call    mem_free
        mov     rcx, [np_album]
        call    mem_free
        mov     rcx, [np_uri]
        call    mem_free
        mov     rcx, [np_img_s]
        call    mem_free
        mov     rcx, [np_img_l]
        call    mem_free
        xor     eax, eax
        mov     [np_title], rax
        mov     [np_artist], rax
        mov     [np_album], rax
        mov     [np_uri], rax
        mov     [np_img_s], rax
        mov     [np_img_l], rax
        EPROC

; rcx = Track*: becomes the current track (copies the strings)
PROC np_set_track, 1
        mov     loc(0), rcx
        call    np_clear
        mov     rbx, loc(0)
        mov     rcx, [rbx+TR_TITLE]
        call    w_dup
        mov     [np_title], rax
        mov     rcx, [rbx+TR_ARTIST]
        call    w_dup
        mov     [np_artist], rax
        mov     rcx, [rbx+TR_ALBUM]
        call    w_dup
        mov     [np_album], rax
        mov     rcx, [rbx+TR_URI]
        call    u8_dup0
        mov     [np_uri], rax
        mov     rcx, [rbx+TR_IMG_S]
        call    u8_dup0
        mov     [np_img_s], rax
        mov     rcx, [rbx+TR_IMG_L]
        call    u8_dup0
        mov     [np_img_l], rax
        mov     eax, [rbx+TR_DUR]
        mov     [np_dur], eax
        mov     dword [np_pos], 0
        mov     dword [np_paused], 0
        mov     dword [np_valid], 1
        inc     dword [np_gen]
        call    GetTickCount64
        mov     [np_tick], rax
        EPROC

; -> eax = current position in ms (interpolated while playing)
PROC np_position, 0
        cmp     dword [np_valid], 0
        je      .zero
        mov     ebx, [np_pos]
        cmp     dword [np_paused], 0
        jne     .clamp
        call    GetTickCount64
        sub     rax, [np_tick]
        add     rbx, rax
.clamp: mov     eax, [np_dur]
        cmp     rbx, rax
        cmova   rbx, rax
        mov     eax, ebx
        jmp     .out
.zero:  xor     eax, eax
.out:   EPROC

; ---------------------------------------------------------------- transport API
; rcx = List* of Track (the visible list), edx = index to start from
PROC player_play_list, 3
        mov     loc(0), rcx
        mov     loc(1), rdx
        cmp     dword [g_demo], 0
        jne     .demo
        call    real_play_list
        jmp     .out
.demo:  lea     rcx, [q_up]
        call    tracks_free
        mov     rax, loc(0)
        mov     rdx, loc(1)
        imul    rdx, TR_SIZE
        add     rdx, [rax+LS_PTR]
        mov     rcx, rdx
        call    np_set_track
        ; the rest of the list becomes the queue
        mov     rbx, loc(1)
        inc     rbx
.q:     mov     rax, loc(0)
        cmp     rbx, [rax+LS_COUNT]
        jae     .out
        lea     rcx, [q_up]
        mov     edx, TR_SIZE
        call    list_push
        mov     rdx, rax
        mov     rax, loc(0)
        imul    rcx, rbx, TR_SIZE
        add     rcx, [rax+LS_PTR]
        call    track_copy
        inc     rbx
        jmp     .q
.out:   EPROC

PROC player_toggle, 0
        cmp     dword [g_demo], 0
        jne     .demo
        call    real_toggle
        jmp     .out
.demo:  cmp     dword [np_valid], 0
        je      .out
        call    np_position
        mov     [np_pos], eax
        call    GetTickCount64
        mov     [np_tick], rax
        xor     dword [np_paused], 1
.out:   EPROC

PROC player_next, 0
        cmp     dword [g_demo], 0
        jne     .demo
        call    real_next
        jmp     .out
.demo:  cmp     qword [q_up+LS_COUNT], 0
        je      .end
        ; pop the first queued track
        mov     rbx, [q_up+LS_PTR]
        mov     rcx, rbx
        call    np_set_track
        ; free its strings and shift the rest down
        mov     rcx, [rbx+TR_TITLE]
        call    mem_free
        mov     rcx, [rbx+TR_ARTIST]
        call    mem_free
        mov     rcx, [rbx+TR_ALBUM]
        call    mem_free
        mov     rcx, [rbx+TR_URI]
        call    mem_free
        mov     rcx, [rbx+TR_IMG_S]
        call    mem_free
        mov     rcx, [rbx+TR_IMG_L]
        call    mem_free
        mov     rcx, rbx
        lea     rdx, [rbx+TR_SIZE]
        mov     r8, [q_up+LS_COUNT]
        dec     r8
        mov     [q_up+LS_COUNT], r8
        imul    r8, TR_SIZE
        call    mem_copy
        jmp     .out
.end:   cmp     dword [np_valid], 0
        je      .out
        mov     eax, [np_dur]
        mov     [np_pos], eax
        mov     dword [np_paused], 1
.out:   EPROC

PROC player_prev, 0
        cmp     dword [g_demo], 0
        jne     .demo
        call    real_prev
        jmp     .out
.demo:  xor     ecx, ecx
        call    player_seek
.out:   EPROC

PROC player_seek, 0                     ; ecx = ms
        cmp     dword [g_demo], 0
        jne     .demo
        call    real_seek
        jmp     .out
.demo:  cmp     dword [np_valid], 0
        je      .out
        mov     eax, [np_dur]
        cmp     ecx, eax
        cmova   ecx, eax
        mov     [np_pos], ecx
        call    GetTickCount64
        mov     [np_tick], rax
.out:   EPROC

PROC player_set_volume, 0               ; ecx = 0..100
        cmp     ecx, 100
        jbe     .ok
        mov     ecx, 100
.ok:    mov     [np_vol], ecx
        cmp     dword [g_demo], 0
        jne     .out
        call    real_set_volume
.out:   EPROC

PROC player_shuffle_toggle, 0
        xor     dword [np_shuffle], 1
        cmp     dword [g_demo], 0
        jne     .out
        cmp     dword [sdk_ready], 0
        je      .out
        mov     ecx, [np_shuffle]
        call    real_shuffle
.out:   EPROC

PROC player_repeat_cycle, 0
        mov     eax, [np_repeat]
        inc     eax
        cmp     eax, 3
        jb      .s
        xor     eax, eax
.s:     mov     [np_repeat], eax
        cmp     dword [g_demo], 0
        jne     .out
        cmp     dword [sdk_ready], 0
        je      .out
        mov     ecx, eax
        call    real_repeat
.out:   EPROC

; Called from the UI timer. -> eax = 1 when the display needs a repaint (something is playing).
PROC player_tick, 0
        cmp     dword [np_valid], 0
        je      .none
        cmp     dword [np_paused], 0
        jne     .none
        cmp     dword [g_demo], 0
        je      .real
        call    np_position
        cmp     eax, [np_dur]
        jb      .paint
        cmp     dword [np_repeat], REPEAT_ONE
        jne     .adv
        xor     ecx, ecx
        call    player_seek
        jmp     .paint
.adv:   call    player_next
.paint: mov     eax, 1
        jmp     .out
.real:  mov     eax, 1
        jmp     .out
.none:  xor     eax, eax
.out:   EPROC
