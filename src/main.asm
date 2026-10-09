; main.asm - ByteStream for Windows, x86-64 assembly.  Single translation unit: this file includes the rest.
%include "win64.inc"
%include "core.asm"
%include "json.asm"
%include "model.asm"
%include "fixtures.asm"
%include "theme.asm"
%include "gfx.asm"
%include "icons.asm"
%include "img.asm"
%include "player.asm"
%include "ui_core.asm"
%include "ui_widgets.asm"
%include "ui_chrome.asm"
%include "ui_overlays.asm"
%include "ui_pages.asm"
%include "app.asm"
%include "window.asm"
%include "stubs.asm"
%include "selftest.asm"

extern GetCommandLineW, CommandLineToArgvW, lstrcmpW, GetDpiForSystem, SetWindowTextW

section .bss
cli_selftest:   resd 1
cli_demo:       resd 1
cli_page:       resd 1                  ; -1 = default
cli_theme:      resd 1
cli_w:          resd 1
cli_h:          resd 1
cli_scale:      resd 1                  ; percent, 0 = system DPI
cli_play:       resd 1
cli_full:       resd 1
cli_queue:      resd 1
cli_tab:        resd 1                  ; -1 = default
cli_detail:     resd 1                  ; -1 = none
cli_hover:      resd 1                  ; 1 = apply cli_hx/cli_hy
cli_hx:         resd 1
cli_hy:         resd 1
cli_search:     resq 1                  ; UTF-16 text or 0
cli_vol:        resd 1                  ; -1 = default
cli_pos:        resd 1                  ; -1 = default (seek position in seconds)
cli_dump:       resd 1
cli_nact:       resd 1
cli_ready:      resd 1                  ; set once scripted actions are done (screenshot may be taken)
cli_act_id:     resd 8
cli_act_arg:    resd 8
dump_buf:       resb 512

section .data
WSTR a_selftest, "--selftest"
WSTR a_demo, "--demo"
WSTR a_shot, "--screenshot"
WSTR a_size, "--size"
WSTR a_page, "--page"
WSTR a_theme, "--theme"
WSTR a_scale, "--scale"
WSTR a_play, "--play"
WSTR a_full, "--fullscreen"
WSTR a_queue, "--queue"
WSTR a_tab, "--tab"
WSTR a_detail, "--detail"
WSTR a_hover, "--hover"
WSTR a_search, "--search"
WSTR a_vol, "--volume"
WSTR a_pos, "--seek"
ZSTR s_act_missing, "error: --act target not on screen"
ZSTR d_page, "page="
ZSTR d_tab, "tab="
ZSTR d_theme, "theme="
ZSTR d_valid, "playing_loaded="
ZSTR d_paused, "paused="
ZSTR d_vol, "volume="
ZSTR d_queue, "queue_open="
ZSTR d_full, "fullscreen="
ZSTR d_shuffle, "shuffle="
ZSTR d_repeat, "repeat="
ZSTR d_detail_count, "detail_tracks="
ZSTR d_queued, "queued="
ZSTR d_search_t, "search_tracks="
ZSTR d_playlists, "playlists="
ZSTR d_title, "title="
ZSTR d_detail, "detail="
WSTR a_act, "--act"
WSTR a_dump, "--dump"

section .text

; rcx = wide string -> eax = leading decimal number (non-digits before it are skipped)
w_atoi:
.skip:  movzx   eax, word [rcx]
        test    eax, eax
        jz      .zero
        cmp     eax, '0'
        jb      .next
        cmp     eax, '9'
        jbe     .num
.next:  add     rcx, 2
        jmp     .skip
.num:   xor     edx, edx
.d:     movzx   eax, word [rcx]
        sub     eax, '0'
        cmp     eax, 9
        ja      .done
        imul    edx, edx, 10
        add     edx, eax
        add     rcx, 2
        jmp     .d
.done:  mov     eax, edx
        ret
.zero:  xor     eax, eax
        ret

; rcx = "A<sep>B" -> eax = A, edx = B
PROC w_pair, 2
        mov     loc(0), rcx
        call    w_atoi
        mov     loc(1), rax
        mov     rcx, loc(0)
.skipa: movzx   eax, word [rcx]
        test    eax, eax
        jz      .nob
        cmp     eax, '0'
        jb      .sep
        cmp     eax, '9'
        ja      .sep
        add     rcx, 2
        jmp     .skipa
.sep:   add     rcx, 2
        call    w_atoi
        mov     edx, eax
        mov     eax, dword loc(1)
        jmp     .out
.nob:   xor     edx, edx
        mov     eax, dword loc(1)
.out:   EPROC

; rcx = argument, rdx = flag -> eax = 1 when equal
arg_is:
        sub     rsp, 40
        call    lstrcmpW
        xor     ecx, ecx
        test    eax, eax
        sete    cl
        mov     eax, ecx
        add     rsp, 40
        ret

; Parses argv into the cli_* globals.   loc(0) = argc, loc(1) = argv, loc(2) = index
PROC parse_cli, 4
        mov     dword [cli_page], -1
        mov     dword [cli_tab], -1
        mov     dword [cli_detail], -1
        mov     dword [cli_vol], -1
        mov     dword [cli_pos], -1
        mov     dword [cli_w], 1280
        mov     dword [cli_h], 800
        call    GetCommandLineW
        mov     rcx, rax
        lea     rdx, loc(0)
        call    CommandLineToArgvW
        mov     loc(1), rax
        mov     qword loc(2), 1
.next:  mov     rax, loc(2)
        cmp     eax, dword loc(0)
        jge     .out
        mov     rcx, loc(1)
        mov     rbx, [rcx+rax*8]                ; current argument
        ; the next argument (value), when there is one
        xor     esi, esi
        lea     rdx, [rax+1]
        cmp     edx, dword loc(0)
        jge     .nov
        mov     rsi, [rcx+rdx*8]
.nov:   inc     qword loc(2)
        mov     rcx, rbx
        lea     rdx, [a_selftest]
        call    arg_is
        test    eax, eax
        jz      .a1
        mov     dword [cli_selftest], 1
        jmp     .next
.a1:    mov     rcx, rbx
        lea     rdx, [a_demo]
        call    arg_is
        test    eax, eax
        jz      .a2
        mov     dword [cli_demo], 1
        jmp     .next
.a2:    mov     rcx, rbx
        lea     rdx, [a_play]
        call    arg_is
        test    eax, eax
        jz      .a3
        mov     dword [cli_play], 1
        jmp     .next
.a3:    mov     rcx, rbx
        lea     rdx, [a_full]
        call    arg_is
        test    eax, eax
        jz      .a4
        mov     dword [cli_full], 1
        jmp     .next
.a4:    mov     rcx, rbx
        lea     rdx, [a_queue]
        call    arg_is
        test    eax, eax
        jz      .a5
        mov     dword [cli_queue], 1
        jmp     .next
.a5:    mov     rcx, rbx
        lea     rdx, [a_dump]
        call    arg_is
        test    eax, eax
        jz      .a6
        mov     dword [cli_dump], 1
        jmp     .next
.a6:    test    rsi, rsi
        jz      .next                           ; remaining flags all take a value
        mov     rcx, rbx
        lea     rdx, [a_shot]
        call    arg_is
        test    eax, eax
        jz      .b1
        mov     [cli_shot], rsi
        inc     qword loc(2)
        jmp     .next
.b1:    mov     rcx, rbx
        lea     rdx, [a_size]
        call    arg_is
        test    eax, eax
        jz      .b2
        mov     rcx, rsi
        call    w_pair
        mov     [cli_w], eax
        mov     [cli_h], edx
        inc     qword loc(2)
        jmp     .next
.b2:    mov     rcx, rbx
        lea     rdx, [a_page]
        call    arg_is
        test    eax, eax
        jz      .b3
        mov     rcx, rsi
        call    w_atoi
        mov     [cli_page], eax
        inc     qword loc(2)
        jmp     .next
.b3:    mov     rcx, rbx
        lea     rdx, [a_theme]
        call    arg_is
        test    eax, eax
        jz      .b4
        mov     rcx, rsi
        call    w_atoi
        mov     [cli_theme], eax
        inc     qword loc(2)
        jmp     .next
.b4:    mov     rcx, rbx
        lea     rdx, [a_scale]
        call    arg_is
        test    eax, eax
        jz      .b5
        mov     rcx, rsi
        call    w_atoi
        mov     [cli_scale], eax
        inc     qword loc(2)
        jmp     .next
.b5:    mov     rcx, rbx
        lea     rdx, [a_tab]
        call    arg_is
        test    eax, eax
        jz      .b6
        mov     rcx, rsi
        call    w_atoi
        mov     [cli_tab], eax
        inc     qword loc(2)
        jmp     .next
.b6:    mov     rcx, rbx
        lea     rdx, [a_detail]
        call    arg_is
        test    eax, eax
        jz      .b7
        mov     rcx, rsi
        call    w_atoi
        mov     [cli_detail], eax
        inc     qword loc(2)
        jmp     .next
.b7:    mov     rcx, rbx
        lea     rdx, [a_hover]
        call    arg_is
        test    eax, eax
        jz      .b8
        mov     rcx, rsi
        call    w_pair
        mov     [cli_hx], eax
        mov     [cli_hy], edx
        mov     dword [cli_hover], 1
        inc     qword loc(2)
        jmp     .next
.b8:    mov     rcx, rbx
        lea     rdx, [a_search]
        call    arg_is
        test    eax, eax
        jz      .b9
        mov     [cli_search], rsi
        inc     qword loc(2)
        jmp     .next
.b9:    mov     rcx, rbx
        lea     rdx, [a_vol]
        call    arg_is
        test    eax, eax
        jz      .b10
        mov     rcx, rsi
        call    w_atoi
        mov     [cli_vol], eax
        inc     qword loc(2)
        jmp     .next
.b10:   mov     rcx, rbx
        lea     rdx, [a_pos]
        call    arg_is
        test    eax, eax
        jz      .b11
        mov     rcx, rsi
        call    w_atoi
        mov     [cli_pos], eax
        inc     qword loc(2)
        jmp     .next
.b11:   mov     rcx, rbx
        lea     rdx, [a_act]
        call    arg_is
        test    eax, eax
        jz      .next
        mov     eax, [cli_nact]
        cmp     eax, 8
        jae     .skipact
        mov     rcx, rsi
        call    w_pair
        mov     ecx, [cli_nact]
        lea     r8, [cli_act_id]
        mov     [r8+rcx*4], eax
        lea     r8, [cli_act_arg]
        mov     [r8+rcx*4], edx
        inc     dword [cli_nact]
.skipact:
        inc     qword loc(2)
        jmp     .next
.out:   EPROC

; Applies the automation flags once the window and data exist.
PROC apply_cli, 2
        mov     eax, [cli_theme]
        mov     ecx, eax
        call    theme_set
        call    ui_theme_changed
        cmp     dword [cli_page], -1
        je      .p1
        mov     eax, [cli_page]
        mov     [page], eax
.p1:    cmp     dword [cli_tab], -1
        je      .p2
        mov     eax, [cli_tab]
        mov     [lib_tab], eax
.p2:    cmp     dword [cli_detail], -1
        je      .p3
        mov     ecx, SRC_PLAYLISTS
        mov     edx, [cli_detail]
        call    card_at
        test    rax, rax
        jz      .p3
        mov     rcx, rax
        mov     edx, [cli_detail]
        call    app_open_detail
.p3:    cmp     qword [cli_search], 0
        je      .p4
        mov     rcx, [edit_search]
        mov     rdx, [cli_search]
        call    SetWindowTextW
        mov     rcx, [cli_search]
        call    app_search_demo
.p4:    cmp     dword [cli_play], 0
        je      .p5
        lea     rcx, [lst_recent]
        cmp     qword [rcx+LS_COUNT], 0
        je      .p5
        xor     edx, edx
        call    player_play_list
.p5:    cmp     dword [cli_vol], -1
        je      .p6
        mov     ecx, [cli_vol]
        call    player_set_volume
.p6:    cmp     dword [cli_pos], -1
        je      .p7
        mov     eax, [cli_pos]
        imul    ecx, eax, 1000
        call    player_seek
.p7:    mov     eax, [cli_full]
        mov     [fullscreen], eax
        mov     eax, [cli_queue]
        mov     [queue_open], eax
        EPROC

; Runs the --act list: each entry activates a hit target that really exists on screen.
PROC run_acts, 4
        xor     ebx, ebx
.next:  cmp     ebx, [cli_nact]
        jae     .out
        lea     rax, [cli_act_id]
        mov     r12d, [rax+rbx*4]
        lea     rax, [cli_act_arg]
        mov     r13d, [rax+rbx*4]
        xor     esi, esi
.find:  cmp     esi, [hit_n]
        jae     .missing
        imul    rax, rsi, HIT_SIZE
        lea     rcx, [hit_tab]
        add     rax, rcx
        cmp     [rax+16], r12d
        jne     .nx
        cmp     [rax+20], r13d
        je      .go
.nx:    inc     esi
        jmp     .find
.go:    mov     ecx, r12d
        mov     edx, r13d
        call    ui_activate
        mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        mov     rcx, [hwnd]
        call    UpdateWindow
        inc     ebx
        jmp     .next
.missing:
        lea     rcx, [s_act_missing]
        call    out_z
        mov     ecx, 3
        call    ExitProcess
.out:   EPROC

; Prints the visible application state as key=value lines (used by the tests).
PROC dump_state, 4
        lea     rdi, [dump_buf]
        lea     rsi, [dump_buf]
        mov     loc(0), rdi
        ; helper macro style: write "name=" then a number then newline
%macro DUMPNUM 2
        mov     rcx, rdi
        lea     rdx, [%1]
        call    dump_str
        mov     rdi, rax
        mov     rcx, rdi
        mov     edx, %2
        call    u8_put_u64
        mov     rdi, rax
        mov     byte [rdi], 10
        inc     rdi
%endmacro
        DUMPNUM d_page, dword [page]
        DUMPNUM d_tab, dword [lib_tab]
        DUMPNUM d_theme, dword [theme_idx]
        DUMPNUM d_valid, dword [np_valid]
        DUMPNUM d_paused, dword [np_paused]
        DUMPNUM d_vol, dword [np_vol]
        DUMPNUM d_queue, dword [queue_open]
        DUMPNUM d_full, dword [fullscreen]
        DUMPNUM d_shuffle, dword [np_shuffle]
        DUMPNUM d_repeat, dword [np_repeat]
        DUMPNUM d_detail_count, dword [lst_detail+LS_COUNT]
        DUMPNUM d_queued, dword [q_up+LS_COUNT]
        DUMPNUM d_search_t, dword [lst_search_t+LS_COUNT]
        DUMPNUM d_playlists, dword [lst_playlists+LS_COUNT]
        ; strings
        mov     rcx, rdi
        lea     rdx, [d_title]
        call    dump_str
        mov     rdi, rax
        mov     loc(1), rdi
        mov     rcx, [np_title]
        test    rcx, rcx
        jz      .notitle
        mov     rdx, -1
        call    w_to_u8
        mov     loc(2), rax
        mov     rcx, rdi
        mov     rdx, rax
        call    dump_str
        mov     rdi, rax
        mov     rcx, loc(2)
        call    mem_free
.notitle:
        mov     byte [rdi], 10
        inc     rdi
        mov     rcx, rdi
        lea     rdx, [d_detail]
        call    dump_str
        mov     rdi, rax
        mov     rcx, [det_title]
        test    rcx, rcx
        jz      .nodet
        mov     rdx, -1
        call    w_to_u8
        mov     loc(2), rax
        mov     rcx, rdi
        mov     rdx, rax
        call    dump_str
        mov     rdi, rax
        mov     rcx, loc(2)
        call    mem_free
.nodet: mov     byte [rdi], 10
        inc     rdi
        mov     byte [rdi], 0
        lea     rcx, [dump_buf]
        call    out_z
        EPROC

; rcx = destination, rdx = z-string -> rax = end of the copy (no NUL written)
dump_str:
.l:     mov     al, [rdx]
        test    al, al
        jz      .d
        mov     [rcx], al
        inc     rcx
        inc     rdx
        jmp     .l
.d:     mov     rax, rcx
        ret

global start
PROC start, 8
        call    core_init
        call    parse_cli
        cmp     dword [cli_selftest], 0
        je      .gui
        call    selftest
        mov     ecx, eax
        call    ExitProcess
.gui:   call    SetProcessDPIAware
        call    gfx_init
        mov     dword [detail_sel], -1
        mov     dword [np_vol], 70
        ; scale: system DPI, or the --scale override
        call    GetDpiForSystem
        imul    eax, 65536
        xor     edx, edx
        mov     ecx, 96
        div     ecx
        mov     loc(0), rax
        cmp     dword [cli_scale], 0
        je      .sc
        mov     eax, [cli_scale]
        imul    eax, 65536
        xor     edx, edx
        mov     ecx, 100
        div     ecx
        mov     loc(0), rax
.sc:    mov     ecx, dword loc(0)
        call    ui_metrics
        mov     ecx, dword loc(0)
        call    gfx_set_scale
        mov     ecx, [cli_theme]
        call    theme_set
        call    ui_theme_changed
        mov     eax, [cli_w]
        imul    eax, dword loc(0)
        shr     eax, 16
        mov     ecx, eax
        mov     eax, [cli_h]
        imul    eax, dword loc(0)
        shr     eax, 16
        mov     edx, eax
        mov     r8d, dword loc(0)
        call    window_create
        call    ui_make_fonts
        mov     ecx, ID_EDIT_SEARCH
        call    make_edit
        mov     [edit_search], rax
        mov     ecx, ID_EDIT_CLIENT
        call    make_edit
        mov     [edit_client], rax
        mov     rcx, [edit_search]
        mov     edx, 0x1501                     ; EM_SETCUEBANNER
        mov     r8d, 1
        lea     r9, [w_cue_search]
        call    SendMessageW
        mov     rcx, [edit_client]
        mov     edx, 0x1501
        mov     r8d, 1
        lea     r9, [w_cue_client]
        call    SendMessageW
        cmp     dword [cli_demo], 0
        je      .login
        call    app_load_demo
        mov     dword [page], PAGE_HOME
        jmp     .ready
.login: mov     dword [page], PAGE_LOGIN
.ready: call    apply_cli
        mov     rcx, [hwnd]
        mov     edx, SW_SHOW
        call    ShowWindow
        mov     rcx, [hwnd]
        call    UpdateWindow
        call    run_acts
        cmp     dword [cli_hover], 0
        je      .hv
        mov     ecx, [cli_hx]
        mov     edx, [cli_hy]
        call    ui_mouse_move
.hv:    cmp     dword [cli_dump], 0
        je      .ready2
        call    dump_state
        cmp     qword [cli_shot], 0
        jne     .ready2
        xor     ecx, ecx                        ; --dump alone: print the state and exit
        call    ExitProcess
.ready2: mov    dword [cli_ready], 1
        mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
.timer: mov     rcx, [hwnd]
        mov     edx, TIMER_TICK
        mov     r8d, 250
        xor     r9d, r9d
        call    SetTimer
.loop:  lea     rcx, [msg_buf]
        xor     edx, edx
        xor     r8d, r8d
        xor     r9d, r9d
        call    GetMessageW
        test    eax, eax
        jle     .exit
        lea     rcx, [msg_buf]
        call    TranslateMessage
        lea     rcx, [msg_buf]
        call    DispatchMessageW
        jmp     .loop
.exit:  xor     ecx, ecx
        call    ExitProcess
        EPROC
