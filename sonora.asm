; sonora.asm - a tiny Sonora-style local music player in pure x86-64 assembly.
;
; Linux only, NASM syntax, no libc: every operation is a raw syscall.
;
;   nasm -felf64 sonora.asm -o sonora.o && ld -o sonora sonora.o
;   ./sonora [music-dir]
;
; Keys: j/k or arrows move, Enter plays, Space pause, n/p next/prev,
;       +/- volume, s stop, q quit.
;
; Plays 8/16-bit PCM .wav files through OSS (/dev/dsp). If no OSS device
; exists it falls back to "silent mode": the UI and clock run in real time
; but nothing is written to a sound card.

bits 64
default rel

%define SYS_read        0
%define SYS_write       1
%define SYS_open        2
%define SYS_close       3
%define SYS_poll        7
%define SYS_lseek       8
%define SYS_ioctl       16
%define SYS_exit        60
%define SYS_getdents64  217

%define TCGETS          0x5401
%define TCSETS          0x5402
%define SNDCTL_DSP_SPEED    0xC0045002
%define SNDCTL_DSP_SETFMT   0xC0045005
%define SNDCTL_DSP_CHANNELS 0xC0045006

%define MAXTR   256             ; max tracks
%define NAMELEN 256             ; bytes per name slot (incl. NUL)
%define VROWS   14              ; visible list rows
%define CHUNK   8192            ; bytes per playback step

section .bss
dirpath         resb 4104
dirlen          resq 1
names           resb MAXTR*NAMELEN
ntracks         resq 1
sel             resq 1
cur             resq 1          ; playing index, -1 if none
state           resq 1          ; 0 stopped, 1 playing, 2 paused
vol             resq 1          ; 0..10
sinkfd          resq 1          ; -1 = silent mode
filefd          resq 1          ; -1 = none
chans           resq 1
rate            resq 1
bitdepth        resq 1
dataoff         resq 1
datasize        resq 1
played          resq 1
byterate        resq 1
lastsec         resq 1
dirty           resq 1
have_tty        resq 1
msgptr          resq 1
ptimeout        resd 1
ioarg           resd 1
pollfd          resb 8
keybuf          resb 16
orig_termios    resb 64
raw_termios     resb 64
dents           resb 32768
iobuf           resb CHUNK
hdrbuf          resb 4096
pathbuf         resb 8400
outbuf          resb 32768

section .data
dot_str:        db ".", 0
dsp_path:       db "/dev/dsp", 0
s_enter:        db 27, "[?1049h", 27, "[?25l", 0
s_leave:        db 27, "[?25h", 27, "[?1049l", 0
s_clear:        db 27, "[H", 27, "[2J", 0
s_title:        db 27, "[1m  S O N O R A", 27, "[0m  (x86-64 assembly)", 10, 0
s_dir:          db "  library: ", 0
s_nl:           db 10, 0
s_nl2:          db 10, 10, 0
s_empty:        db "  no .wav files found in this directory", 10, 0
s_rev:          db 27, "[7m", 0
s_reset:        db 27, "[0m", 10, 0
s_mark_on:      db " ", 0xE2, 0x99, 0xAA, " ", 0          ; " ♪ "
s_mark_off:     db "   ", 0
s_stopped:      db "  ", 0xE2, 0x96, 0xA0, " stopped", 10, 0       ; ■
s_playing:      db "  ", 0xE2, 0x96, 0xB6, " playing: ", 0         ; ▶
s_paused:       db "  ", 0xE2, 0x8F, 0xB8, " paused:  ", 0         ; ⏸
s_full:         db 0xE2, 0x96, 0x88, 0                              ; █
s_light:        db 0xE2, 0x96, 0x91, 0                              ; ░
s_sp:           db " ", 0
s_slash:        db " / ", 0
s_vol:          db "  volume: ", 0
s_of10:         db "/10", 10, 0
s_silent:       db "  (no /dev/dsp - silent timing mode)", 10, 0
s_help:         db 10, "  j/k move  enter play  space pause  n/p skip  +/- vol  s stop  q quit", 10, 0
s_err_dir:      db "sonora: cannot open directory", 10
s_err_dir_len:  equ $ - s_err_dir
m_open:         db "  ! cannot open file", 10, 0
m_bad:          db "  ! unsupported file (need 8/16-bit PCM wav)", 10, 0

section .text
global _start

_start:
        mov     rcx, [rsp]              ; argc
        lea     rsi, [rsp+8]            ; argv
        cmp     rcx, 2
        jb      .use_dot
        mov     rsi, [rsi+8]            ; argv[1]
        jmp     .copy
.use_dot:
        lea     rsi, [dot_str]
.copy:
        lea     rdi, [dirpath]
        xor     ebx, ebx
.cl:    cmp     rbx, 4000
        jae     die_dir
        mov     al, [rsi+rbx]
        mov     [rdi+rbx], al
        inc     rbx
        test    al, al
        jnz     .cl
        dec     rbx                     ; length without NUL
        jnz     .nonempty
        mov     byte [rdi], '.'
        inc     rbx
.nonempty:
        cmp     byte [rdi+rbx-1], '/'
        je      .slashed
        mov     byte [rdi+rbx], '/'
        inc     rbx
        mov     byte [rdi+rbx], 0
.slashed:
        mov     [dirlen], rbx

        mov     qword [cur], -1
        mov     qword [filefd], -1
        mov     qword [sinkfd], -1
        mov     qword [vol], 8
        mov     qword [dirty], 1

        call    scan_dir
        call    sort_names

        ; raw terminal mode (best effort; works on pipes too)
        mov     eax, SYS_ioctl
        xor     edi, edi
        mov     esi, TCGETS
        lea     rdx, [orig_termios]
        syscall
        test    rax, rax
        js      .no_tty
        mov     qword [have_tty], 1
        lea     rsi, [orig_termios]
        lea     rdi, [raw_termios]
        mov     ecx, 60
        rep     movsb
        and     dword [raw_termios+12], ~(2|8)  ; clear ICANON|ECHO
        mov     eax, SYS_ioctl
        xor     edi, edi
        mov     esi, TCSETS
        lea     rdx, [raw_termios]
        syscall
.no_tty:
        lea     r15, [outbuf]
        lea     rsi, [s_enter]
        call    put_str
        call    flush

main_loop:
        cmp     qword [dirty], 0
        je      .nodraw
        call    render
        mov     qword [dirty], 0
.nodraw:
        mov     dword [ptimeout], -1
        cmp     qword [state], 1
        jne     .poll
        call    play_chunk
.poll:
        mov     dword [pollfd], 0       ; fd 0
        mov     word [pollfd+4], 1      ; POLLIN
        mov     word [pollfd+6], 0
        mov     eax, SYS_poll
        lea     rdi, [pollfd]
        mov     esi, 1
        mov     edx, [ptimeout]
        syscall
        test    rax, rax
        jle     main_loop               ; timeout / EINTR
        test    word [pollfd+6], 1
        jz      quit                    ; HUP without data
        xor     eax, eax                ; SYS_read
        xor     edi, edi
        lea     rsi, [keybuf]
        mov     edx, 16
        syscall
        test    rax, rax
        jle     quit
        call    handle_key
        jmp     main_loop

quit:
        call    close_track
        lea     r15, [outbuf]
        lea     rsi, [s_leave]
        call    put_str
        call    flush
        cmp     qword [have_tty], 0
        je      .out
        mov     eax, SYS_ioctl
        xor     edi, edi
        mov     esi, TCSETS
        lea     rdx, [orig_termios]
        syscall
.out:   xor     edi, edi
        mov     eax, SYS_exit
        syscall

die_dir:
        mov     eax, SYS_write
        mov     edi, 2
        lea     rsi, [s_err_dir]
        mov     edx, s_err_dir_len
        syscall
        mov     edi, 1
        mov     eax, SYS_exit
        syscall

; ---------------------------------------------------------------- library
scan_dir:
        lea     rdi, [dirpath]
        mov     esi, 0x10000            ; O_RDONLY|O_DIRECTORY
        mov     eax, SYS_open
        syscall
        test    rax, rax
        js      die_dir
        mov     r12, rax
.gd:    mov     rdi, r12
        lea     rsi, [dents]
        mov     edx, 32768
        mov     eax, SYS_getdents64
        syscall
        test    rax, rax
        jle     .done
        mov     r13, rax
        xor     r14d, r14d
.ent:   lea     rbx, [dents]
        add     rbx, r14
        movzx   r8d, word [rbx+16]      ; d_reclen
        lea     rsi, [rbx+19]           ; d_name
        xor     edx, edx
.ln:    cmp     byte [rsi+rdx], 0
        je      .ld
        inc     rdx
        jmp     .ln
.ld:    cmp     rdx, 5
        jb      .next
        cmp     rdx, 255
        ja      .next
        mov     eax, [rsi+rdx-4]
        or      eax, 0x20202020         ; ascii-lowercase
        cmp     eax, 0x7661772e         ; ".wav"
        jne     .next
        mov     rax, [ntracks]
        cmp     rax, MAXTR
        jae     .next
        shl     rax, 8
        lea     rdi, [names]
        add     rdi, rax
        lea     rcx, [rdx+1]
        rep     movsb
        inc     qword [ntracks]
.next:  add     r14, r8
        cmp     r14, r13
        jb      .ent
        jmp     .gd
.done:  mov     rdi, r12
        mov     eax, SYS_close
        syscall
        ret

; insertion sort of the name table (byte-wise strcmp)
sort_names:
        mov     r8d, 1
.outer: cmp     r8, [ntracks]
        jae     .ret
        mov     r9, r8
.inner: test    r9, r9
        jz      .onext
        lea     rsi, [names]
        mov     rax, r9
        shl     rax, 8
        add     rsi, rax                ; names[j]
        lea     rdi, [rsi-NAMELEN]      ; names[j-1]
        push    rsi
        push    rdi
.cmp:   mov     al, [rdi]
        mov     dl, [rsi]
        cmp     al, dl
        jne     .diff
        test    al, al
        jz      .diff
        inc     rdi
        inc     rsi
        jmp     .cmp
.diff:  pop     rdi
        pop     rsi
        cmp     al, dl
        jbe     .onext                  ; already ordered
        mov     ecx, NAMELEN/8          ; swap the two slots
.sw:    mov     rax, [rdi]
        mov     rdx, [rsi]
        mov     [rdi], rdx
        mov     [rsi], rax
        add     rdi, 8
        add     rsi, 8
        dec     ecx
        jnz     .sw
        dec     r9
        jmp     .inner
.onext: inc     r8
        jmp     .outer
.ret:   ret

; ---------------------------------------------------------------- playback
; rdi = track index
open_track:
        push    rbx
        push    r12
        push    r13
        mov     r13, rdi
        call    close_track
        mov     qword [msgptr], 0
        mov     qword [dirty], 1
        ; path = dirpath + name
        lea     rdi, [pathbuf]
        lea     rsi, [dirpath]
        mov     rcx, [dirlen]
        rep     movsb
        lea     rsi, [names]
        mov     rax, r13
        shl     rax, 8
        add     rsi, rax
.cp:    lodsb
        stosb
        test    al, al
        jnz     .cp
        lea     rdi, [pathbuf]
        xor     esi, esi
        mov     eax, SYS_open
        syscall
        test    rax, rax
        js      .fail_open
        mov     [filefd], rax
        mov     rdi, rax
        lea     rsi, [hdrbuf]
        mov     edx, 4096
        xor     eax, eax                ; SYS_read
        syscall
        mov     r12, rax                ; bytes in header buffer
        cmp     r12, 12
        jb      .bad
        cmp     dword [hdrbuf], 0x46464952      ; "RIFF"
        jne     .bad
        cmp     dword [hdrbuf+8], 0x45564157    ; "WAVE"
        jne     .bad
        xor     r8d, r8d                ; got fmt
        xor     r9d, r9d                ; got data
        mov     ebx, 12                 ; chunk position
.chunk: lea     rax, [rbx+8]
        cmp     rax, r12
        ja      .parsed
        lea     rsi, [hdrbuf]
        add     rsi, rbx
        mov     eax, [rsi]              ; chunk id
        mov     edx, [rsi+4]            ; chunk size
        cmp     eax, 0x20746d66         ; "fmt "
        jne     .notfmt
        lea     rcx, [rbx+24]
        cmp     rcx, r12
        ja      .parsed
        movzx   ecx, word [rsi+8]       ; format tag
        cmp     ecx, 1
        je      .tagok
        cmp     ecx, 0xFFFE             ; WAVE_FORMAT_EXTENSIBLE
        jne     .bad
.tagok: movzx   ecx, word [rsi+10]
        mov     [chans], rcx
        mov     ecx, [rsi+12]
        mov     [rate], rcx
        movzx   ecx, word [rsi+22]
        mov     [bitdepth], rcx
        mov     r8d, 1
        jmp     .adv
.notfmt:
        cmp     eax, 0x61746164         ; "data"
        jne     .adv
        lea     rcx, [rbx+8]
        mov     [dataoff], rcx
        mov     [datasize], rdx
        mov     r9d, 1
        jmp     .parsed
.adv:   lea     rbx, [rbx+rdx+8]
        and     edx, 1                  ; pad byte on odd sizes
        add     rbx, rdx
        jmp     .chunk
.parsed:
        test    r8d, r8d
        jz      .bad
        test    r9d, r9d
        jz      .bad
        mov     rax, [chans]
        test    rax, rax
        jz      .bad
        cmp     rax, 8
        ja      .bad
        mov     rax, [bitdepth]
        cmp     rax, 8
        je      .depth_ok
        cmp     rax, 16
        jne     .bad
.depth_ok:
        mov     rax, [rate]
        test    rax, rax
        jz      .bad
        imul    rax, [chans]
        imul    rax, [bitdepth]
        shr     rax, 3
        jz      .bad
        mov     [byterate], rax
        mov     rdi, [filefd]
        mov     rsi, [dataoff]
        xor     edx, edx
        mov     eax, SYS_lseek
        syscall
        test    rax, rax
        js      .bad

        ; open the sound card (OSS); silent mode if unavailable
        lea     rdi, [dsp_path]
        mov     esi, 1                  ; O_WRONLY
        mov     eax, SYS_open
        syscall
        test    rax, rax
        js      .silent
        mov     [sinkfd], rax
        mov     rdi, rax
        mov     dword [ioarg], 16       ; AFMT_S16_LE
        cmp     qword [bitdepth], 16
        je      .setfmt
        mov     dword [ioarg], 8        ; AFMT_U8
.setfmt:
        mov     esi, SNDCTL_DSP_SETFMT
        call    dsp_ioctl
        mov     eax, [chans]
        mov     [ioarg], eax
        mov     esi, SNDCTL_DSP_CHANNELS
        call    dsp_ioctl
        mov     eax, [rate]
        mov     [ioarg], eax
        mov     esi, SNDCTL_DSP_SPEED
        call    dsp_ioctl
.silent:
        mov     [cur], r13
        mov     [sel], r13
        mov     qword [played], 0
        mov     qword [lastsec], -1
        mov     qword [state], 1
        jmp     .ret
.fail_open:
        lea     rax, [m_open]
        jmp     .fail
.bad:   lea     rax, [m_bad]
.fail:  mov     [msgptr], rax
        call    close_track
        mov     qword [state], 0
        mov     qword [cur], -1
.ret:   pop     r13
        pop     r12
        pop     rbx
        ret

dsp_ioctl:                              ; rdi = fd, esi = request
        push    rdi
        lea     rdx, [ioarg]
        mov     eax, SYS_ioctl
        syscall
        pop     rdi
        ret

close_track:
        mov     rdi, [filefd]
        test    rdi, rdi
        js      .s
        mov     eax, SYS_close
        syscall
        mov     qword [filefd], -1
.s:     mov     rdi, [sinkfd]
        test    rdi, rdi
        js      .r
        mov     eax, SYS_close
        syscall
        mov     qword [sinkfd], -1
.r:     ret

; feed one chunk to the sound card (or just pace the clock in silent mode)
play_chunk:
        mov     rax, [datasize]
        sub     rax, [played]
        jbe     .eof
        cmp     rax, CHUNK
        jbe     .sz
        mov     eax, CHUNK
.sz:    mov     rdx, rax
        mov     rdi, [filefd]
        lea     rsi, [iobuf]
        xor     eax, eax                ; SYS_read
        syscall
        test    rax, rax
        jle     .eof
        mov     r12, rax                ; bytes read

        ; software volume (16-bit only)
        cmp     qword [bitdepth], 16
        jne     .nov
        mov     r8, [vol]
        cmp     r8, 10
        jae     .nov
        mov     rcx, r12
        shr     rcx, 1
        lea     rsi, [iobuf]
        mov     r9d, 10
.vl:    movsx   eax, word [rsi]
        imul    eax, r8d
        cdq
        idiv    r9d
        mov     [rsi], ax
        add     rsi, 2
        dec     rcx
        jnz     .vl
.nov:
        cmp     qword [sinkfd], 0
        jl      .nosink
        lea     rsi, [iobuf]
        mov     r13, r12
.wr:    mov     rdi, [sinkfd]
        mov     rdx, r13
        mov     eax, SYS_write
        syscall
        test    rax, rax
        jle     .acct                   ; device error: drop the rest
        add     rsi, rax
        sub     r13, rax
        jnz     .wr
        jmp     .acct
.nosink:
        mov     rax, r12
        imul    rax, 1000
        xor     edx, edx
        div     qword [byterate]
        mov     [ptimeout], eax         ; sleep roughly one chunk of audio
.acct:  add     [played], r12
        mov     rax, [played]
        xor     edx, edx
        div     qword [byterate]
        cmp     rax, [lastsec]
        je      .r
        mov     [lastsec], rax
        mov     qword [dirty], 1
.r:     ret
.eof:   jmp     next_auto

next_auto:
        mov     rax, [cur]
        inc     rax
        cmp     rax, [ntracks]
        jae     .stop
        mov     rdi, rax
        jmp     open_track
.stop:  call    close_track
        mov     qword [state], 0
        mov     qword [cur], -1
        mov     qword [dirty], 1
        ret

; ---------------------------------------------------------------- input
handle_key:                             ; rax = bytes in keybuf
        mov     qword [dirty], 1
        cmp     rax, 3
        jb      .single
        cmp     byte [keybuf], 27
        jne     .single
        cmp     byte [keybuf+1], '['
        jne     .single
        mov     cl, [keybuf+2]
        cmp     cl, 'A'
        je      key_up
        cmp     cl, 'B'
        je      key_down
        ret
.single:
        movzx   ecx, byte [keybuf]
        cmp     cl, 'q'
        je      quit
        cmp     cl, 'j'
        je      key_down
        cmp     cl, 'k'
        je      key_up
        cmp     cl, 10
        je      key_play
        cmp     cl, 13
        je      key_play
        cmp     cl, ' '
        je      key_pause
        cmp     cl, 'n'
        je      key_next
        cmp     cl, 'p'
        je      key_prev
        cmp     cl, '+'
        je      key_volup
        cmp     cl, '='
        je      key_volup
        cmp     cl, '-'
        je      key_voldn
        cmp     cl, 's'
        je      key_stop
        ret

key_down:
        mov     rax, [sel]
        inc     rax
        cmp     rax, [ntracks]
        jae     .r
        mov     [sel], rax
.r:     ret
key_up:
        mov     rax, [sel]
        test    rax, rax
        jz      .r
        dec     rax
        mov     [sel], rax
.r:     ret
key_play:
        cmp     qword [ntracks], 0
        je      .r
        mov     rdi, [sel]
        jmp     open_track
.r:     ret
key_pause:
        mov     rax, [state]
        cmp     rax, 1
        je      .pause
        cmp     rax, 2
        je      .resume
        jmp     key_play                ; stopped: play selection
.pause: mov     qword [state], 2
        ret
.resume:
        mov     qword [state], 1
        ret
key_next:
        mov     rax, [sel]
        cmp     qword [state], 0
        je      .go
        mov     rax, [cur]
.go:    inc     rax
        cmp     rax, [ntracks]
        jae     .r
        mov     rdi, rax
        jmp     open_track
.r:     ret
key_prev:
        mov     rax, [sel]
        cmp     qword [state], 0
        je      .go
        mov     rax, [cur]
.go:    test    rax, rax
        jz      .r
        dec     rax
        mov     rdi, rax
        jmp     open_track
.r:     ret
key_volup:
        cmp     qword [vol], 10
        jae     .r
        inc     qword [vol]
.r:     ret
key_voldn:
        cmp     qword [vol], 0
        je      .r
        dec     qword [vol]
.r:     ret
key_stop:
        call    close_track
        mov     qword [state], 0
        mov     qword [cur], -1
        ret

; ---------------------------------------------------------------- output
; r15 = output cursor (global within render)
put_str:                                ; rsi = NUL-terminated string
.l:     mov     al, [rsi]
        test    al, al
        jz      .r
        mov     [r15], al
        inc     r15
        inc     rsi
        jmp     .l
.r:     ret

put_char:                               ; al
        mov     [r15], al
        inc     r15
        ret

put_dec:                                ; rax = unsigned value
        mov     r8d, 10
        xor     ecx, ecx
.d:     xor     edx, edx
        div     r8
        add     dl, '0'
        push    rdx
        inc     ecx
        test    rax, rax
        jnz     .d
.p:     pop     rax
        mov     [r15], al
        inc     r15
        dec     ecx
        jnz     .p
        ret

put_dec2:                               ; rax < 100, zero padded
        xor     edx, edx
        mov     ecx, 10
        div     ecx
        add     al, '0'
        mov     [r15], al
        add     dl, '0'
        mov     [r15+1], dl
        add     r15, 2
        ret

put_time:                               ; rax = seconds -> m:ss
        xor     edx, edx
        mov     ecx, 60
        div     rcx
        push    rdx
        call    put_dec
        mov     al, ':'
        call    put_char
        pop     rax
        jmp     put_dec2

name_ptr:                               ; rax = index -> rsi = name
        lea     rsi, [names]
        shl     rax, 8
        add     rsi, rax
        ret

flush:
        lea     rsi, [outbuf]
        mov     rdx, r15
        sub     rdx, rsi
        mov     edi, 1
        mov     eax, SYS_write
        syscall
        ret

render:
        lea     r15, [outbuf]
        lea     rsi, [s_clear]
        call    put_str
        lea     rsi, [s_title]
        call    put_str
        lea     rsi, [s_dir]
        call    put_str
        lea     rsi, [dirpath]
        call    put_str
        lea     rsi, [s_nl2]
        call    put_str

        cmp     qword [ntracks], 0
        jne     .have
        lea     rsi, [s_empty]
        call    put_str
        jmp     .status
.have:
        mov     rbx, [sel]              ; top = clamp(sel-7, 0, n-VROWS)
        sub     rbx, 7
        jns     .t1
        xor     ebx, ebx
.t1:    mov     rax, [ntracks]
        sub     rax, VROWS
        jns     .t2
        xor     eax, eax
.t2:    cmp     rbx, rax
        jbe     .t3
        mov     rbx, rax
.t3:    lea     r12, [rbx+VROWS]        ; end = min(top+VROWS, n)
        cmp     r12, [ntracks]
        jbe     .row
        mov     r12, [ntracks]
.row:   cmp     rbx, r12
        jae     .status
        cmp     rbx, [sel]
        jne     .nosel
        lea     rsi, [s_rev]
        call    put_str
.nosel: lea     rsi, [s_mark_off]
        cmp     rbx, [cur]
        jne     .mk
        cmp     qword [state], 0
        je      .mk
        lea     rsi, [s_mark_on]
.mk:    call    put_str
        mov     rax, rbx
        call    name_ptr
        call    put_str
        lea     rsi, [s_reset]
        call    put_str
        inc     rbx
        jmp     .row

.status:
        lea     rsi, [s_nl]
        call    put_str
        mov     rax, [state]
        test    rax, rax
        jnz     .active
        lea     rsi, [s_stopped]
        call    put_str
        mov     rsi, [msgptr]
        test    rsi, rsi
        jz      .vol
        call    put_str
        jmp     .vol
.active:
        lea     rsi, [s_playing]
        cmp     rax, 1
        je      .lbl
        lea     rsi, [s_paused]
.lbl:   call    put_str
        mov     rax, [cur]
        call    name_ptr
        call    put_str
        lea     rsi, [s_nl]
        call    put_str
        lea     rsi, [s_sp]
        call    put_str
        call    put_sp2
        mov     rax, [played]
        xor     edx, edx
        div     qword [byterate]
        call    put_time
        lea     rsi, [s_slash]
        call    put_str
        mov     rax, [datasize]
        xor     edx, edx
        div     qword [byterate]
        call    put_time
        lea     rsi, [s_sp]
        call    put_str
        call    put_sp2
        ; progress bar, 30 cells
        mov     rax, [played]
        imul    rax, 30
        mov     rcx, [datasize]
        test    rcx, rcx
        jz      .bar0
        xor     edx, edx
        div     rcx
        jmp     .bar
.bar0:  xor     eax, eax
.bar:   cmp     rax, 30
        jbe     .barok
        mov     eax, 30
.barok: mov     r13, rax                ; filled
        xor     r14d, r14d
.bl:    cmp     r14, 30
        jae     .bdone
        lea     rsi, [s_full]
        cmp     r14, r13
        jb      .bp
        lea     rsi, [s_light]
.bp:    call    put_str
        inc     r14
        jmp     .bl
.bdone: lea     rsi, [s_nl]
        call    put_str
        cmp     qword [sinkfd], 0
        jge     .vol
        lea     rsi, [s_silent]
        call    put_str
.vol:   lea     rsi, [s_vol]
        call    put_str
        mov     rax, [vol]
        call    put_dec
        lea     rsi, [s_of10]
        call    put_str
        lea     rsi, [s_help]
        call    put_str
        jmp     flush

put_sp2:
        lea     rsi, [s_sp]
        jmp     put_str
