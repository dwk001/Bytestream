; main.asm - ByteStream for Windows, x86-64 assembly.  Single translation unit: this file includes the rest.
%include "win64.inc"

; data sections start on 16 bytes; individual items are aligned where Windows or SSE care (WSTR, buffers)
section .data align=16
section .bss align=16

; All code lives in one .text; text_begin / text_end bound it for the unwind table at the end of this file.
section .text
text_begin:

%include "core.asm"
%include "json.asm"
%include "model.asm"
%include "http.asm"
%include "net.asm"
%include "settings.asm"
%include "os.asm"
%include "log.asm"
%include "fixtures.asm"
%include "theme.asm"
%include "gfx.asm"
%include "icons.asm"
%include "img.asm"
%include "player.asm"
%include "ui_core.asm"
%include "anim.asm"
%include "auth.asm"
%include "localsrv.asm"
%include "audio.asm"
%include "ui_widgets.asm"
%include "field.asm"
%include "library.asm"
%include "like.asm"
%include "playlist.asm"
%include "dialog.asm"
%include "menu.asm"
%include "ui_chrome.asm"
%include "ui_overlays.asm"
%include "ui_pages.asm"
%include "app.asm"
%include "window.asm"
%include "stubs.asm"
%include "selftest.asm"

extern GetCommandLineW, CommandLineToArgvW, lstrcmpW, GetDpiForSystem, SetWindowTextW, IsWindowVisible

section .bss
cli_selftest:   resd 1
cli_demo:       resd 1
cli_page:       resd 1                  ; -1 = default
cli_theme:      resd 1
cli_w:          resd 1
cli_size_set:   resd 1                  ; --size given: do not restore the saved window size
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
cli_http_url:   resq 1                  ; --http-test URL (developer probe)
cli_api_base:   resq 1                  ; UTF-8 overrides for the fake server
cli_auth_base:  resq 1
cli_data_dir:   resq 1                  ; UTF-16
cli_nget:       resd 1
cli_get:        resq 8                  ; --net-get paths (UTF-16)
cli_type_client: resq 1
cli_type_port:  resq 1
cli_crash:      resd 1
cli_wait_auth:  resd 1
cli_banner:     resq 1
cli_banner_btn: resq 1
cli_http_meth:  resq 1
cli_http_body:  resq 1
cli_nact:       resd 1
cli_ready:      resd 1                  ; set once scripted actions are done (screenshot may be taken)
cli_act_id:     resd 96                 ; bit 16 = --act-late (waits for the player page), bit 17 = already run
cli_act_arg:    resd 96
                align 8
dump_buf:       resb 4096
cli_run_ms:     resd 1                  ; --run-ms N: keep running N ms after the scripted actions, then dump and exit
run_t0:         resq 1
cli_dlg_name:    resq 1                  ; --dlg-name / --dlg-desc: text that appears in the dialog fields when it opens (tests)
cli_dlg_desc:    resq 1
cli_anim:       resd 1                  ; --anim
cli_click:      resd 1
cli_cx:         resd 1
cli_cy:         resd 1
cli_drag:       resd 1
cli_dx:         resd 1
cli_dy:         resd 1
cli_anim_hold:  resd 1
cli_shot_ms:    resd 1                  ; --shot-ms N
cli_hold:       resd 1                  ; --hold: with --dump, keep running until the player page posts "quit"
dump_tmp:       resd 4

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
WSTR a_http, "--http-test"
WSTR a_api, "--api-base"
WSTR a_authb, "--auth-base"
WSTR a_ddir, "--data-dir"
WSTR a_edge, "--edge-path"
WSTR a_imgb, "--img-budget"
WSTR a_nobrowser, "--no-browser"
WSTR a_hold, "--hold"
WSTR a_anim, "--anim"
WSTR a_click, "--click"
WSTR a_dragto, "--drag-to"
WSTR a_clipin, "--clip-in"
WSTR a_animhold, "--anim-hold"
WSTR a_shotms, "--shot-ms"
WSTR a_runms, "--run-ms"
WSTR a_dlgname, "--dlg-name"
WSTR a_dlgdesc, "--dlg-desc"
WSTR a_netget, "--net-get"
WSTR a_tclient, "--type-client"
WSTR a_tport, "--type-port"
WSTR a_banner, "--banner"
WSTR a_crash, "--crash-test"
WSTR a_waitauth, "--wait-auth"
WSTR a_bbtn, "--banner-button"
WSTR a_hmeth, "--http-method"
WSTR a_hbody, "--http-body"
WSTR w_get, "GET"
ZSTR s_status, "status="
s_nl_z: db 10, 0
ZSTR s_body_hdr, "body="
ZSTR s_transport, "status=0 transport-error="
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
ZSTR d_port, "port="
ZSTR d_auth, "auth_state="
ZSTR d_signed, "signed_in="
ZSTR d_demo, "demo="
ZSTR d_user, "user="
ZSTR d_net_n, "net_n="
ZSTR d_net0, "net_0="
ZSTR d_net1, "net_1="
ZSTR d_net2, "net_2="
ZSTR d_net3, "net_3="
ZSTR d_pending, "net_pending="
ZSTR d_banner, "banner="
ZSTR d_client, "client_id="
ZSTR d_artist, "artist="
ZSTR d_album, "album="
ZSTR d_uri, "track_uri="
ZSTR d_img_l, "cover_large="
ZSTR d_img_s, "cover_small="
ZSTR d_device, "device="
ZSTR d_pos, "position_ms="
ZSTR d_dur, "duration_ms="
ZSTR d_sdk, "sdk_ready="
ZSTR d_dalb, "artist_albums="
ZSTR d_dlg, "dialog="
ZSTR d_dlgpub, "dialog_public="
ZSTR d_menu, "menu_open="
ZSTR d_menun, "menu_n="
ZSTR d_q0, "queue_first="
ZSTR d_saved, "saved_count="
ZSTR d_notsaved, "not_saved_count="
ZSTR d_asked, "asked_count="
ZSTR d_ffocus, "field_focus="
ZSTR d_fcaret, "field_caret="
ZSTR d_fanch, "field_anchor="
ZSTR d_fscroll, "field_scroll="
ZSTR d_ftext, "field"
ZSTR d_afr, "anim_frames="
ZSTR d_aon, "anim_on="
ZSTR d_abusy, "anim_busy="
ZSTR d_aq, "anim_queue="
ZSTR d_af, "anim_full="
ZSTR d_ahv, "anim_hover="
ZSTR d_smain, "scroll_main="
ZSTR d_sside, "scroll_side="
ZSTR d_squeue, "scroll_queue="
ZSTR d_pcalls, "paint_msgs="
ZSTR d_scalls, "size_msgs="
ZSTR d_bbw, "backbuf_w="
ZSTR d_bbh, "backbuf_h="
ZSTR d_bbg, "backbuf_ok="
ZSTR d_vis, "window_visible="
ZSTR d_pfull, "paints_full="
ZSTR d_pbar, "paints_bar="
ZSTR d_hits, "hits="
ZSTR d_liked, "liked="
ZSTR d_albums, "albums="
ZSTR d_recent, "recent="
ZSTR d_msg, "detail_msg="
ZSTR d_imgs, "images_ready="
ZSTR d_search_a, "search_albums="
ZSTR d_search_p, "search_playlists="
ZSTR d_search_r, "search_artists="
ZSTR l_exit, "exit"
WSTR a_act, "--act"
WSTR a_actlate, "--act-late"
WSTR a_ctx, "--ctx"
WSTR a_ctxlate, "--ctx-late"
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
        mov     dword [cli_theme], -1
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
.a6:    mov     rcx, rbx
        lea     rdx, [a_waitauth]
        call    arg_is
        test    eax, eax
        jz      .a6a
        mov     dword [cli_wait_auth], 1
        jmp     .next
.a6a:   mov     rcx, rbx
        lea     rdx, [a_crash]
        call    arg_is
        test    eax, eax
        jz      .a6b
        mov     dword [cli_crash], 1
        jmp     .next
.a6b:   mov     rcx, rbx
        lea     rdx, [a_nobrowser]
        call    arg_is
        test    eax, eax
        jz      .a6c
        mov     dword [cli_no_shell], 1
        jmp     .next
.a6c:   mov     rcx, rbx
        lea     rdx, [a_hold]
        call    arg_is
        test    eax, eax
        jz      .a6d
        mov     dword [cli_hold], 1
        jmp     .next
.a6d:   mov     rcx, rbx
        lea     rdx, [a_anim]
        call    arg_is
        test    eax, eax
        jz      .a7
        mov     dword [cli_anim], 1             ; --anim: animations stay on in a --dump / --screenshot run
        jmp     .next
.a7:    test    rsi, rsi
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
        mov     dword [cli_size_set], 1
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
        lea     rdx, [a_http]
        call    arg_is
        test    eax, eax
        jz      .b12
        mov     [cli_http_url], rsi
        inc     qword loc(2)
        jmp     .next
.b12:   mov     rcx, rbx
        lea     rdx, [a_hmeth]
        call    arg_is
        test    eax, eax
        jz      .b13
        mov     [cli_http_meth], rsi
        inc     qword loc(2)
        jmp     .next
.b13:   mov     rcx, rbx
        lea     rdx, [a_hbody]
        call    arg_is
        test    eax, eax
        jz      .b14
        mov     [cli_http_body], rsi
        inc     qword loc(2)
        jmp     .next
.b14:   mov     rcx, rbx
        lea     rdx, [a_api]
        call    arg_is
        test    eax, eax
        jz      .b15
        mov     rcx, rsi
        mov     rdx, -1
        call    w_to_u8
        mov     [cli_api_base], rax
        inc     qword loc(2)
        jmp     .next
.b15:   mov     rcx, rbx
        lea     rdx, [a_authb]
        call    arg_is
        test    eax, eax
        jz      .b16
        mov     rcx, rsi
        mov     rdx, -1
        call    w_to_u8
        mov     [cli_auth_base], rax
        inc     qword loc(2)
        jmp     .next
.b16:   mov     rcx, rbx
        lea     rdx, [a_ddir]
        call    arg_is
        test    eax, eax
        jz      .b16b
        mov     [cli_data_dir], rsi
        inc     qword loc(2)
        jmp     .next
.b16b:  mov     rcx, rbx
        lea     rdx, [a_edge]
        call    arg_is
        test    eax, eax
        jz      .b16c
        mov     [edge_override], rsi
        inc     qword loc(2)
        jmp     .next
.b16c:  mov     rcx, rbx
        lea     rdx, [a_imgb]
        call    arg_is
        test    eax, eax
        jz      .b16d
        mov     rcx, rsi
        call    w_atoi
        shl     rax, 10
        mov     [img_budget], rax               ; --img-budget KB: tests squeeze the cover cache
        inc     qword loc(2)
        jmp     .next
.b16d:  mov     rcx, rbx
        lea     rdx, [a_runms]
        call    arg_is
        test    eax, eax
        jz      .b16e
        mov     rcx, rsi
        call    w_atoi
        mov     [cli_run_ms], eax
        inc     qword loc(2)
        jmp     .next
.b16e:  mov     rcx, rbx
        lea     rdx, [a_dlgname]
        call    arg_is
        test    eax, eax
        jz      .b16f
        mov     [cli_dlg_name], rsi
        inc     qword loc(2)
        jmp     .next
.b16f:  mov     rcx, rbx
        lea     rdx, [a_dlgdesc]
        call    arg_is
        test    eax, eax
        jz      .b16g
        mov     [cli_dlg_desc], rsi
        inc     qword loc(2)
        jmp     .next
.b16g:  mov     rcx, rbx
        lea     rdx, [a_shotms]
        call    arg_is
        test    eax, eax
        jz      .b16h
        mov     rcx, rsi
        call    w_atoi
        mov     [cli_shot_ms], eax              ; --shot-ms N: take the screenshot N ms after start (animations mid-way)
        inc     qword loc(2)
        jmp     .next
.b16j:  mov     rcx, rbx
        lea     rdx, [a_click]
        call    arg_is
        test    eax, eax
        jz      .b16k
        mov     rcx, rsi
        call    w_pair
        mov     [cli_cx], eax                   ; --click X,Y: press and release the left button there (real mouse path)
        mov     [cli_cy], edx
        mov     dword [cli_click], 1
        inc     qword loc(2)
        jmp     .next
.b16k:  mov     rcx, rbx
        lea     rdx, [a_dragto]
        call    arg_is
        test    eax, eax
        jz      .b17
        mov     rcx, rsi
        call    w_pair
        mov     [cli_dx], eax                   ; --drag-to X,Y: ... and release it there instead (after moving there)
        mov     [cli_dy], edx
        mov     dword [cli_drag], 1
        inc     qword loc(2)
        jmp     .next
.b16i:  mov     rcx, rbx
        lea     rdx, [a_clipin]
        call    arg_is
        test    eax, eax
        jz      .b16j
        mov     [cli_clip_in], rsi              ; --clip-in TEXT: the clipboard content seen by a field's paste in a --no-browser run
        inc     qword loc(2)
        jmp     .next
.b16h:  mov     rcx, rbx
        lea     rdx, [a_animhold]
        call    arg_is
        test    eax, eax
        jz      .b16i
        mov     rcx, rsi
        call    w_atoi
        mov     [cli_anim_hold], eax            ; --anim-hold P: sliding panels frozen P % of the way (screenshots)
        inc     qword loc(2)
        jmp     .next
.b17:   mov     rcx, rbx
        lea     rdx, [a_netget]
        call    arg_is
        test    eax, eax
        jz      .b18
        mov     eax, [cli_nget]
        cmp     eax, 8
        jae     .b17s
        lea     rcx, [cli_get]
        mov     [rcx+rax*8], rsi
        inc     dword [cli_nget]
.b17s:  inc     qword loc(2)
        jmp     .next
.b18:   mov     rcx, rbx
        lea     rdx, [a_tclient]
        call    arg_is
        test    eax, eax
        jz      .b19
        mov     [cli_type_client], rsi
        inc     qword loc(2)
        jmp     .next
.b19:   mov     rcx, rbx
        lea     rdx, [a_tport]
        call    arg_is
        test    eax, eax
        jz      .b20
        mov     [cli_type_port], rsi
        inc     qword loc(2)
        jmp     .next
.b20:   mov     rcx, rbx
        lea     rdx, [a_banner]
        call    arg_is
        test    eax, eax
        jz      .b21
        mov     [cli_banner], rsi
        inc     qword loc(2)
        jmp     .next
.b21:   mov     rcx, rbx
        lea     rdx, [a_bbtn]
        call    arg_is
        test    eax, eax
        jz      .b22
        mov     [cli_banner_btn], rsi
        inc     qword loc(2)
        jmp     .next
.b22:   mov     rcx, rbx
        lea     rdx, [a_act]
        call    arg_is
        xor     r12d, r12d
        test    eax, eax
        jnz     .isact
        mov     rcx, rbx
        lea     rdx, [a_actlate]
        call    arg_is
        mov     r12d, 0x10000
        test    eax, eax
        jnz     .isact
        mov     rcx, rbx
        lea     rdx, [a_ctx]
        call    arg_is
        mov     r12d, 0x80000                   ; --ctx: a right click on the target
        test    eax, eax
        jnz     .isact
        mov     rcx, rbx
        lea     rdx, [a_ctxlate]
        call    arg_is
        mov     r12d, 0x90000                   ; --ctx-late: the same, once the player page says "go"
        test    eax, eax
        jz      .next
.isact: mov     eax, [cli_nact]
        cmp     eax, 96
        jae     .skipact
        mov     rcx, rsi
        call    w_pair
        or      eax, r12d
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
        cmp     dword [cli_demo], 0
        je      .p4                             ; a live search waits until the session is restored
        mov     rcx, [edit_search]
        mov     rdx, [cli_search]
        call    field_set_text
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

; --type-client / --type-port put text into the inputs as if typed (EN_CHANGE fires, settings are saved),
; and --net-get paths are requested through the job queue.
PROC run_scripted_input, 4
        mov     rdx, [cli_type_client]
        test    rdx, rdx
        jz      .p
        mov     rcx, [edit_client]
        call    field_set_text
.p:     mov     rdx, [cli_type_port]
        test    rdx, rdx
        jz      .g
        mov     rcx, [edit_port]
        call    field_set_text
.g:     xor     ebx, ebx
        mov     qword loc(1), 0                 ; Buf based at &loc(3)
        mov     qword loc(2), 0
        mov     qword loc(3), 0
.gl:    cmp     ebx, [cli_nget]
        jae     .gd
        lea     rax, [cli_get]
        mov     rcx, [rax+rbx*8]
        mov     rdx, -1
        call    w_to_u8
        mov     rsi, rax
        lea     rcx, loc(3)
        mov     rdx, rsi
        call    api_url
        mov     rcx, rsi
        call    mem_free
        xor     ecx, ecx
        mov     edx, TAG_DEBUG
        mov     r8, rbx
        lea     r9, [w_get]
        mov     rax, loc(3)
        mov     outarg(5), rax
        mov     qword outarg(6), 0
        mov     qword outarg(7), 0
        mov     qword outarg(8), 0
        call    net_submit
        inc     ebx
        jmp     .gl
.gd:    lea     rcx, loc(3)
        call    buf_free
        EPROC

; --wait-auth: pump messages until a running sign-in (browser step, token exchange, profile) has finished.
PROC wait_auth, 4
        call    GetTickCount64
        mov     loc(0), rax
.l:     lea     rcx, [msg_buf]
        xor     edx, edx
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword outarg(5), 1              ; PM_REMOVE
        call    PeekMessageW
        test    eax, eax
        jz      .idle
        lea     rcx, [msg_buf]
        call    TranslateMessage
        lea     rcx, [msg_buf]
        call    DispatchMessageW
        jmp     .l
.idle:  cmp     dword [auth_state], AUTH_WAITING
        je      .more
        cmp     dword [auth_state], AUTH_EXCHANGE
        je      .more
        cmp     dword [net_pending], 0
        je      .out
.more:  call    GetTickCount64
        sub     rax, loc(0)
        cmp     rax, 30000
        jae     .out
        mov     ecx, 4
        call    Sleep
        jmp     .l
.out:   EPROC

; Runs the --act list: each entry activates a hit target that really exists on screen.
PROC run_acts, 2
        xor     ebx, ebx
.next:  cmp     ebx, [cli_nact]
        jae     .out
        lea     rax, [cli_act_id]
        test    dword [rax+rbx*4], 0x30000      ; --act-late entries wait for the player page
        jnz     .skip
        mov     ecx, ebx
        call    run_act_at
.skip:  inc     ebx
        jmp     .next
.out:   EPROC

; Runs the next --act-late entry (tests: the fake player page posts {"type":"go"} when it is ready for it).
PROC run_late_act, 2
        xor     ebx, ebx
.next:  cmp     ebx, [cli_nact]
        jae     .out
        lea     rax, [cli_act_id]
        mov     ecx, [rax+rbx*4]
        test    ecx, 0x10000
        jz      .skip
        test    ecx, 0x20000
        jnz     .skip
        or      dword [rax+rbx*4], 0x20000
        mov     ecx, ebx
        call    run_act_at
        jmp     .out
.skip:  inc     ebx
        jmp     .next
.out:   EPROC

section .data
wheel_x:        dd 20, 0, 0
section .text

; ecx = index into the --act table: activates its hit target, or ends the process when it is not on screen
PROC run_act_at, 2
        lea     rax, [cli_act_id]
        mov     r12d, [rax+rcx*4]
        mov     r14d, r12d
        and     r14d, 0x80000                   ; right click instead of a click
        and     r12d, 0xFFFF
        lea     rax, [cli_act_arg]
        mov     r13d, [rax+rcx*4]
        mov     ecx, 4000
        call    net_wait_idle                   ; let requests started by earlier actions finish (a page's tracks, say)
        mov     rcx, [hwnd]
        call    UpdateWindow                    ; paint what arrived since the last frame, so the hit list is current
        cmp     r12d, 0xF000                    ; pseudo targets: keyboard / text / mouse input to a field (see run_tests.py)
        jb      .real
        cmp     r12d, 0xF040
        jae     .real
        mov     eax, r12d
        and     eax, 0x0F                       ; field index
        mov     r10d, r12d
        and     r10d, 0xFFF0
        cmp     r10d, 0xF010
        je      .fkey
        cmp     r10d, 0xF020
        je      .fchr
        cmp     r10d, 0xF030
        je      .fmouse
        mov     ecx, eax                        ; 0xF000 + n: focus field n, caret at the end
        xor     edx, edx
        call    field_focus_set
        jmp     .painted
.fkey:  mov     ecx, eax                        ; key: low 16 bits = virtual key, bit 16 shift, bit 17 control
        mov     edx, r13d
        and     edx, 0xFFFF
        mov     r8d, r13d
        shr     r8d, 16
        and     r8d, 3
        call    field_key
        jmp     .painted
.fchr:  mov     ecx, eax
        mov     edx, r13d
        call    field_char
        jmp     .painted
.fmouse: mov    esi, eax                        ; click at x = field left + argument (bit 16: extend the selection)
        lea     eax, [rsi+1]
        cmp     eax, [fld_focus]
        je      .fm1
        mov     ecx, esi
        xor     edx, edx
        call    field_focus_set
.fm1:   lea     r8, [fld_tab]
        imul    r9d, esi, FL_SIZE
        mov     edx, [r8+r9+FL_X]
        mov     eax, r13d
        and     eax, 0xFFFF
        add     edx, eax
        mov     r8d, r13d
        shr     r8d, 16
        and     r8d, 1
        mov     ecx, esi
        call    field_mouse
        jmp     .painted
.real:
        mov     eax, r12d
        sub     eax, 0xF100                     ; pseudo targets 0xF100 / 1 / 2: mouse wheel over the page / sidebar / queue,
        cmp     eax, 2                          ; argument n = n notches down, 256 + n = n notches up
        ja      .find0
        mov     ecx, -120
        imul    ecx, r13d
        cmp     r13d, 256
        jb      .wh
        mov     ecx, 120
        mov     edx, r13d
        sub     edx, 256
        imul    ecx, edx
.wh:    lea     rdx, [wheel_x]
        mov     edx, [rdx+rax*4]
        add     edx, [lay_main_x]
        cmp     eax, 1
        jne     .wh2
        xor     edx, edx                        ; sidebar: x = 0
.wh2:   cmp     eax, 2
        jne     .wh3
        mov     edx, [lay_q_x]
        inc     edx
.wh3:   call    ui_wheel
        jmp     .painted
.find0:
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
.go:    test    r14d, r14d
        jz      .click
        mov     ecx, [rax+8]
        shr     ecx, 1
        add     ecx, [rax]                      ; centre of the target
        mov     edx, [rax+12]
        shr     edx, 1
        add     edx, [rax+4]
        call    ui_context
        jmp     .painted
.click: mov     ecx, r12d
        mov     edx, r13d
        call    ui_activate
.painted:
        mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        mov     rcx, [hwnd]
        call    UpdateWindow
        jmp     .out
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
        DUMPNUM d_port, dword [set_port]
        DUMPNUM d_auth, dword [auth_state]
        DUMPNUM d_signed, dword [signed_in]
        DUMPNUM d_demo, dword [g_demo]
        DUMPNUM d_net_n, dword [dbg_count]
        DUMPNUM d_net0, dword [dbg_results]
        DUMPNUM d_net1, dword [dbg_results+8]
        DUMPNUM d_net2, dword [dbg_results+16]
        DUMPNUM d_net3, dword [dbg_results+24]
        DUMPNUM d_pending, dword [net_pending]
        xor     eax, eax
        cmp     qword [banner_text], 0
        setne   al
        mov     [dump_tmp], eax                 ; DUMPNUM clobbers eax before it reads its operand
        DUMPNUM d_banner, dword [dump_tmp]
        mov     rcx, rdi
        lea     rdx, [d_user]
        call    dump_str
        mov     rdi, rax
        mov     rcx, [user_name]
        test    rcx, rcx
        jz      .nouser
        mov     rdx, -1
        call    w_to_u8
        mov     loc(2), rax
        mov     rcx, rdi
        mov     rdx, rax
        call    dump_str
        mov     rdi, rax
        mov     rcx, loc(2)
        call    mem_free
.nouser:
        mov     byte [rdi], 10
        inc     rdi
        mov     rcx, rdi
        lea     rdx, [d_client]
        call    dump_str
        mov     rdi, rax
        mov     rcx, rdi
        lea     rdx, [set_client_id]
        call    dump_str
        mov     rdi, rax
        mov     byte [rdi], 10
        inc     rdi
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
        mov     rcx, rdi
        lea     rdx, [d_artist]
        mov     r8, [np_artist]
        call    dump_wfield
        mov     rdi, rax
        mov     rcx, rdi
        lea     rdx, [d_album]
        mov     r8, [np_album]
        call    dump_wfield
        mov     rdi, rax
        mov     rcx, rdi
        lea     rdx, [d_uri]
        mov     r8, [np_uri]
        call    dump_u8field
        mov     rdi, rax
        mov     rcx, rdi
        lea     rdx, [d_img_l]
        mov     r8, [np_img_l]
        call    dump_u8field
        mov     rdi, rax
        mov     rcx, rdi
        lea     rdx, [d_img_s]
        mov     r8, [np_img_s]
        call    dump_u8field
        mov     rdi, rax
        mov     rcx, rdi
        lea     rdx, [d_device]
        lea     r8, [sdk_device]
        call    dump_u8field
        mov     rdi, rax
        DUMPNUM d_pos, dword [np_pos]
        DUMPNUM d_dur, dword [np_dur]
        DUMPNUM d_sdk, dword [sdk_ready]
        DUMPNUM d_dalb, dword [lst_dalbums+LS_COUNT]
        DUMPNUM d_dlg, dword [dlg_kind]
        DUMPNUM d_dlgpub, dword [dlg_public]
        DUMPNUM d_menu, dword [menu_open]
        DUMPNUM d_menun, dword [menu_n]
        mov     eax, [fld_focus]
        mov     [dump_tmp], eax
        DUMPNUM d_ffocus, dword [dump_tmp]
        mov     eax, [fld_focus]
        test    eax, eax
        jz      .nofld
        dec     eax
        imul    eax, FL_SIZE
        lea     rcx, [fld_tab]
        add     rcx, rax
        mov     eax, [rcx+FL_CARET]
        mov     [dump_tmp], eax
        mov     eax, [rcx+FL_ANCH]
        mov     [dump_tmp+4], eax
        mov     eax, [rcx+FL_SCROLL]
        mov     [dump_tmp+8], eax
        DUMPNUM d_fcaret, dword [dump_tmp]
        DUMPNUM d_fanch, dword [dump_tmp+4]
        DUMPNUM d_fscroll, dword [dump_tmp+8]
.nofld: xor     r12d, r12d                      ; field0=... field4=... (UTF-8)
.fl:    mov     rcx, rdi
        lea     rdx, [d_ftext]
        call    dump_str
        mov     rdi, rax
        lea     eax, [r12+'0']
        mov     [rdi], al
        mov     byte [rdi+1], '='
        add     rdi, 2
        imul    ecx, r12d, FL_SIZE
        lea     rax, [fld_tab]
        add     rcx, rax
        lea     rdx, [dlg_wbuf]
        mov     r8d, 259
        call    field_get_text
        lea     rcx, [dlg_wbuf]
        mov     rdx, -1
        call    w_to_u8
        mov     r13, rax
        mov     rcx, rdi
        mov     rdx, rax
        call    dump_str
        mov     rdi, rax
        mov     rcx, r13
        call    mem_free
        mov     byte [rdi], 10
        inc     rdi
        inc     r12d
        cmp     r12d, FLD_N
        jb      .fl
        DUMPNUM d_afr, dword [anim_frames]
        DUMPNUM d_aon, dword [anim_on]
        DUMPNUM d_abusy, dword [anim_busy]
        mov     ecx, AC_QUEUE
        call    anim_get
        mov     [dump_tmp], eax
        DUMPNUM d_aq, dword [dump_tmp]
        mov     ecx, AC_FULL
        call    anim_get
        mov     [dump_tmp], eax
        DUMPNUM d_af, dword [dump_tmp]
        mov     ecx, [anim_hk_id]
        mov     edx, [anim_hk_arg]
        call    anim_hv
        mov     [dump_tmp], eax
        DUMPNUM d_ahv, dword [dump_tmp]
        DUMPNUM d_smain, dword [scroll_main]
        DUMPNUM d_sside, dword [scroll_side]
        DUMPNUM d_squeue, dword [scroll_queue]
        DUMPNUM d_pcalls, dword [paint_calls]
        DUMPNUM d_scalls, dword [size_calls]
        DUMPNUM d_bbw, dword [bb_w]
        DUMPNUM d_bbh, dword [bb_h]
        xor     eax, eax
        cmp     qword [bb_g], 0
        setne   al
        mov     [dump_tmp], eax
        DUMPNUM d_bbg, dword [dump_tmp]
        mov     rcx, [hwnd]
        call    IsWindowVisible
        mov     [dump_tmp], eax
        DUMPNUM d_vis, dword [dump_tmp]
        DUMPNUM d_pfull, dword [paints_full]
        DUMPNUM d_pbar, dword [paints_bar]
        DUMPNUM d_hits, dword [hit_n]
        mov     edx, LKS_SAVED
        call    lk_count_state
        mov     [dump_tmp], eax
        DUMPNUM d_saved, dword [dump_tmp]
        mov     edx, LKS_NOT
        call    lk_count_state
        mov     [dump_tmp], eax
        DUMPNUM d_notsaved, dword [dump_tmp]
        mov     edx, LKS_ASKED
        call    lk_count_state
        mov     [dump_tmp], eax
        DUMPNUM d_asked, dword [dump_tmp]
        DUMPNUM d_liked, dword [lst_liked+LS_COUNT]
        DUMPNUM d_albums, dword [lst_albums+LS_COUNT]
        DUMPNUM d_recent, dword [lst_recent+LS_COUNT]
        DUMPNUM d_search_a, dword [lst_search_a+LS_COUNT]
        DUMPNUM d_search_p, dword [lst_search_p+LS_COUNT]
        DUMPNUM d_search_r, dword [lst_search_r+LS_COUNT]
        xor     eax, eax
        cmp     qword [det_msg], 0
        setne   al
        mov     [dump_tmp], eax
        DUMPNUM d_msg, dword [dump_tmp]
        call    img_ready_count
        mov     [dump_tmp], eax
        DUMPNUM d_imgs, dword [dump_tmp]
        xor     r8d, r8d
        cmp     qword [q_up+LS_COUNT], 0
        je      .noq0
        mov     rax, [q_up+LS_PTR]
        mov     r8, [rax+TR_TITLE]
.noq0:  mov     rcx, rdi
        lea     rdx, [d_q0]
        call    dump_wfield
        mov     rdi, rax
        mov     byte [rdi], 0
        lea     rcx, [dump_buf]
        call    out_z
        EPROC

; -> eax = number of covers in the cache that finished loading (downloaded ones included)
img_ready_count:
        xor     eax, eax
        xor     edx, edx
        lea     rcx, [img_tab]
.l:     cmp     edx, [img_cnt]
        jae     .r
        cmp     dword [rcx+16], IMG_READY
        jne     .n
        inc     eax
.n:     add     rcx, IMG_ENT
        inc     edx
        jmp     .l
.r:     ret

; rcx = dest, rdx = label, r8 = UTF-16 string or 0 -> rax = end of "label value\n"
PROC dump_wfield, 4
        mov     loc(1), r8
        call    dump_str
        mov     loc(0), rax
        mov     rcx, loc(1)
        test    rcx, rcx
        jz      .nl
        mov     rdx, -1
        call    w_to_u8
        mov     loc(2), rax
        mov     rcx, loc(0)
        mov     rdx, rax
        call    dump_str
        mov     loc(0), rax
        mov     rcx, loc(2)
        call    mem_free
.nl:    mov     rax, loc(0)
        mov     byte [rax], 10
        inc     rax
        EPROC

; rcx = dest, rdx = label, r8 = UTF-8 string or 0 -> rax = end of "label value\n"
PROC dump_u8field, 2
        mov     loc(1), r8
        call    dump_str
        mov     rdx, loc(1)
        test    rdx, rdx
        jz      .nl
        mov     rcx, rax
        call    dump_str
.nl:    mov     byte [rax], 10
        inc     rax
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

; --http-test URL [--http-method M] [--http-body S]: one request through the real HTTP layer, result on stdout.
PROC http_probe, 12
        mov     rcx, [cli_http_url]
        mov     rdx, -1
        sub     rsp, 0
        mov     rax, rcx
        call    w_to_u8                         ; URL is UTF-16 on the command line; the client wants UTF-8
        mov     loc(0), rax                     ; url (utf8)
        lea     rax, [w_get]
        mov     loc(1), rax                     ; method (wide)
        xor     eax, eax
        mov     loc(2), rax                     ; owned method (utf16) to free, if any
        mov     rcx, [cli_http_meth]
        test    rcx, rcx
        jz      .nm
        mov     loc(1), rcx
.nm:    mov     qword loc(3), 0                 ; body (utf8)
        mov     qword loc(4), 0
        mov     rcx, [cli_http_body]
        test    rcx, rcx
        jz      .nb
        mov     rdx, -1
        call    w_to_u8
        mov     loc(3), rax
        mov     loc(4), rdx
.nb:    mov     qword loc(7), 0                 ; response Buf at &loc(7): ptr=loc(7) len=loc(6) cap=loc(5)
        mov     qword loc(6), 0
        mov     qword loc(5), 0
        lea     rax, [hdr_probe]
        mov     rcx, loc(1)
        mov     rdx, loc(0)
        mov     r8, rax
        mov     r9, loc(3)
        mov     rax, loc(4)
        mov     outarg(5), rax
        lea     rax, loc(7)
        mov     outarg(6), rax
        mov     qword outarg(7), 0
        call    http_request
        mov     loc(8), rax
        lea     rcx, [s_status]
        call    out_z
        lea     rcx, loc(9)                     ; "<n>\n" built in a scratch qword pair
        mov     rdx, loc(8)
        call    u8_put_u64
        mov     byte [rax], 10
        mov     byte [rax+1], 0
        lea     rcx, loc(9)
        call    out_z
        lea     rcx, [s_body_hdr]
        call    out_z
        mov     rcx, loc(7)
        test    rcx, rcx
        jz      .nobody
        call    out_z
.nobody:
        lea     rcx, [s_nl_z]
        call    out_z
        xor     ecx, ecx
        cmp     qword loc(8), 0
        setz    cl
        mov     eax, ecx                        ; exit code 1 on transport failure
        EPROC

section .data
WSTR hdr_probe, `Authorization: Bearer probe-token\r\nContent-Type: application/json\r\nX-ByteStream: probe\r\n`
section .text

global start
PROC start, 8
        call    core_init
        call    parse_cli
        cmp     dword [cli_selftest], 0
        je      .nst
        call    selftest
        mov     ecx, eax
        call    ExitProcess
.nst:   cmp     qword [cli_http_url], 0
        je      .gui
        call    http_init
        call    http_probe
        mov     ecx, eax
        call    ExitProcess
        ; (windowed mode)
.gui:   call    SetProcessDPIAware
        mov     rcx, [cli_data_dir]
        call    settings_init
        cmp     dword [cli_size_set], 0
        jne     .nosize
        cmp     dword [set_win_w], 0
        je      .nosize
        mov     eax, [set_win_w]                ; the size the window had last time
        mov     [cli_w], eax
        mov     eax, [set_win_h]
        mov     [cli_h], eax
.nosize: call   single_instance_check
        lea     rcx, [data_dir]
        call    log_init
        call    version_string_init
        call    crash_install
        call    http_init
        mov     rcx, [cli_api_base]
        mov     rdx, [cli_auth_base]
        call    net_init
        mov     eax, [set_volume]
        mov     [np_vol], eax
        cmp     dword [cli_theme], -1
        jne     .thm
        mov     eax, [set_theme]
        mov     [cli_theme], eax
.thm:   cmp     dword [cli_scale], 0
        jne     .scl
        mov     eax, [set_scale]
        mov     [cli_scale], eax
.scl:   call    gfx_init
        call    anim_init
        cmp     dword [cli_anim], 0
        jne     .animok
        cmp     dword [cli_dump], 0             ; tests (--dump / --screenshot) see every animation finished at once
        jne     .animoff
        cmp     qword [cli_shot], 0
        je      .animok
.animoff: mov   dword [anim_on], 0
.animok:
        mov     dword [detail_sel], -1
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
        call    field_init
        call    edit_fill_from_settings
        call    auth_init
        cmp     dword [cli_demo], 0
        je      .login
        call    app_load_demo
        mov     dword [page], PAGE_HOME
        jmp     .ready
.login: mov     dword [page], PAGE_LOGIN
        call    auth_restore                    ; a stored session signs in without any click
.ready: call    apply_cli
        mov     rcx, [hwnd]
        mov     edx, SW_SHOW
        call    ShowWindow
        mov     rcx, [hwnd]
        call    UpdateWindow
        cmp     dword [cli_crash], 0
        je      .nocrash
        call    crash_test_fn
.nocrash:
        call    run_scripted_input
        cmp     dword [cli_wait_auth], 0
        je      .nowait1
        call    wait_auth                       ; let a stored session finish restoring before any scripted click
.nowait1:
        mov     rcx, [cli_banner]
        test    rcx, rcx
        jz      .nobanner
        mov     rdx, [cli_banner_btn]
        mov     r8d, BA_SETTINGS
        call    ui_banner
.nobanner:
        cmp     qword [cli_search], 0
        je      .nosearch
        cmp     dword [cli_demo], 0
        jne     .nosearch
        mov     rcx, [edit_search]
        mov     rdx, [cli_search]
        call    field_set_text
        call    ui_run_search
.nosearch:
        call    run_acts
        cmp     dword [cli_click], 0
        je      .noclick
        mov     ecx, 4000
        call    net_wait_idle
        mov     rcx, [hwnd]
        call    UpdateWindow
        mov     ecx, [cli_cx]
        mov     edx, [cli_cy]
        call    ui_mouse_down
        mov     r12d, [cli_cx]
        mov     r13d, [cli_cy]
        cmp     dword [cli_drag], 0
        je      .mup
        mov     r12d, [cli_dx]
        mov     r13d, [cli_dy]
        mov     ecx, r12d
        mov     edx, r13d
        call    ui_mouse_move
.mup:   mov     ecx, r12d
        mov     edx, r13d
        call    ui_mouse_up
        mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
        mov     rcx, [hwnd]
        call    UpdateWindow
.noclick:
        mov     ecx, 15000
        call    net_wait_idle
        cmp     dword [cli_wait_auth], 0
        je      .noauthwait
        call    wait_auth
.noauthwait:
        cmp     dword [cli_hover], 0
        je      .hv
        mov     ecx, [cli_hx]
        mov     edx, [cli_hy]
        call    ui_mouse_move
.hv:    cmp     dword [cli_dump], 0
        je      .ready2
        cmp     dword [cli_hold], 0
        jne     .ready2                         ; --hold: the dump happens when the player page says "quit"
        cmp     dword [cli_run_ms], 0
        jne     .ready2                         ; --run-ms: the timer dumps later
        call    dump_state
        cmp     qword [cli_shot], 0
        jne     .ready2
        xor     ecx, ecx                        ; --dump alone: print the state and exit
        call    ExitProcess
.ready2: mov    dword [cli_ready], 1
        call    GetTickCount64
        mov     [run_t0], rax
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
.exit:  lea     rcx, [l_exit]
        call    log_msg
        call    settings_save
        xor     ecx, ecx
        call    ExitProcess
        EPROC

; ---------------------------------------------------------------- exception unwind tables
; 64-bit Windows can only unwind (and therefore reach the crash filter, SEH and the debugger) through code that
; has unwind data.  Every PROC starts with `push rbp / mov rbp, rsp`, so one entry describing exactly that frame
; covers the whole image: restore rsp from rbp, pop the saved rbp, return address is next.  Frameless leaf
; helpers are unwound as if they were part of their caller, which still reaches the caller's caller.
section .text
text_end:

section .xdata rdata align=4
unwind_frame:
        db 1                            ; version 1, no flags
        db 4                            ; size of prolog: push rbp (1) + mov rbp, rsp (3)
        db 2                            ; two unwind codes
        db 5                            ; frame register = rbp, offset 0
        db 4, 0x03                      ; at +4: UWOP_SET_FPREG
        db 1, 0x50                      ; at +1: UWOP_PUSH_NONVOL rbp

section .pdata rdata align=4
        dd text_begin wrt ..imagebase
        dd text_end wrt ..imagebase
        dd unwind_frame wrt ..imagebase
