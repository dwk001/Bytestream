; like.asm - which tracks, albums and playlists the user has saved, and the heart buttons.
;
; The Web API answers "is this saved?" in batches of 40 (GET /me/library/contains) and saves / removes with
; PUT / DELETE /me/library.  Answers are cached by a 62-bit FNV-1a hash of the URI in an open-addressing table:
;
;   entry = (hash & ~3) | state          0 = free slot
;   state   0 unknown (asked and failed)   1 saved   2 not saved   3 asked, answer pending
;
; Rows ask for their own state while they are painted (like_state queues the URI; the batch goes out at the end of
; the frame), saved-track / album / playlist lists mark their items as saved up front, and toggling is optimistic:
; the heart flips at once and is flipped back with a message if the API refuses.

%define LK_SLOTS    16384
%define LK_MASK     (LK_SLOTS-1)
%define LK_MAXFILL  12000
%define LK_MAXPEND  40
%define LKS_UNKNOWN 0
%define LKS_SAVED   1
%define LKS_NOT     2
%define LKS_ASKED   3

section .bss
lk_tab:         resq LK_SLOTS
lk_count:       resd 1
lk_pend_n:      resd 1
lk_pend:        resq LK_MAXPEND         ; owned URI strings waiting for the next contains request

section .data
ZSTR lp_contains, "/v1/me/library/contains?uris="
ZSTR lp_library, "/v1/me/library?uris="
ZSTR s_comma, ","
WSTR w_delete, "DELETE"
WSTR w_err_save, "Could not update your library. Check your connection and try again."
section .text

; ---------------------------------------------------------------- the cache
; rcx = URI (UTF-8) -> rax = hash with the state bits clear (never 0)
lk_hash:
        mov     rax, 0xcbf29ce484222325
        mov     r8, 0x100000001b3
.l:     movzx   edx, byte [rcx]
        test    edx, edx
        jz      .d
        xor     rax, rdx
        imul    rax, r8
        inc     rcx
        jmp     .l
.d:     and     rax, -4
        or      rax, 4
        ret

; rax = hash -> rdx = the slot holding it, or the free slot where it belongs
lk_slot:
        lea     rcx, [lk_tab]
        mov     rdx, rax
        shr     rdx, 3
        and     edx, LK_MASK
.p:     mov     r8, [rcx+rdx*8]
        test    r8, r8
        jz      .found
        mov     r9, r8
        and     r9, -4
        cmp     r9, rax
        je      .found
        inc     edx
        and     edx, LK_MASK
        jmp     .p
.found: lea     rdx, [rcx+rdx*8]
        ret

; rax = hash, edx = state: stores it (adding the key when new)
PROC lk_put_hash, 2
        mov     loc(0), rax
        mov     loc(1), rdx
        cmp     dword [lk_count], LK_MAXFILL
        jb      .ok
        call    lk_reset                        ; a pathologically long session: start over rather than fill up
.ok:    mov     rax, loc(0)
        call    lk_slot
        cmp     qword [rdx], 0
        jne     .have
        inc     dword [lk_count]
.have:  mov     rax, loc(0)
        mov     rcx, loc(1)
        or      rax, rcx
        mov     [rdx], rax
        EPROC

; Forgets every cached answer (sign-in, sign-out)
PROC lk_reset, 2
        lea     rdi, [lk_tab]
        mov     ecx, LK_SLOTS
        xor     eax, eax
        rep     stosq
        mov     dword [lk_count], 0
        xor     ebx, ebx
.f:     cmp     ebx, [lk_pend_n]
        jae     .done
        lea     rax, [lk_pend]
        mov     rcx, [rax+rbx*8]
        call    mem_free
        inc     ebx
        jmp     .f
.done:  mov     dword [lk_pend_n], 0
        EPROC

; edx = state -> eax = how many cache entries are in that state (tests)
lk_count_state:
        lea     rcx, [lk_tab]
        xor     eax, eax
        xor     r8d, r8d
.l:     mov     r9, [rcx+r8*8]
        and     r9d, 3
        test    r9, r9
        jz      .n
        cmp     r9d, edx
        jne     .n
        inc     eax
.n:     inc     r8d
        cmp     r8d, LK_SLOTS
        jb      .l
        ret

; rcx = URI (UTF-8), edx = state
PROC lk_put, 2
        mov     loc(0), rdx
        call    lk_hash
        mov     rdx, loc(0)
        call    lk_put_hash
        EPROC

; rcx = List* of Track  /  rcx = List* of Card: every item is saved
PROC lk_mark_tracks, 3
        mov     loc(0), rcx
        xor     ebx, ebx
.l:     mov     rax, loc(0)
        cmp     rbx, [rax+LS_COUNT]
        jae     .out
        imul    rdx, rbx, TR_SIZE
        add     rdx, [rax+LS_PTR]
        mov     rcx, [rdx+TR_URI]
        test    rcx, rcx
        jz      .n
        mov     edx, LKS_SAVED
        call    lk_put
.n:     inc     ebx
        jmp     .l
.out:   EPROC

PROC lk_mark_cards, 3
        mov     loc(0), rcx
        xor     ebx, ebx
.l:     mov     rax, loc(0)
        cmp     rbx, [rax+LS_COUNT]
        jae     .out
        imul    rdx, rbx, CD_SIZE
        add     rdx, [rax+LS_PTR]
        mov     rcx, [rdx+CD_URI]
        test    rcx, rcx
        jz      .n
        mov     edx, LKS_SAVED
        call    lk_put
.n:     inc     ebx
        jmp     .l
.out:   EPROC

; ---------------------------------------------------------------- asking
; rcx = URI (UTF-8) -> eax = LKS_SAVED / LKS_NOT, or 0 while the answer is on its way.
; An unknown URI is queued for the next batch (sent by like_flush, or at once when 40 are waiting).
PROC like_state, 4
        mov     loc(0), rcx
        call    lk_hash
        mov     loc(1), rax
        call    lk_slot
        mov     rax, [rdx]
        test    rax, rax
        jz      .new
        and     eax, 3
        jz      .ask                            ; unknown: ask
        cmp     eax, LKS_ASKED
        jne     .out                            ; saved / not saved
        xor     eax, eax                        ; an answer is on its way
        jmp     .out
.new:   cmp     dword [g_demo], 0
        je      .ask
        mov     rax, loc(1)                     ; demo mode has no server: unknown means not saved
        mov     edx, LKS_NOT
        call    lk_put_hash
        mov     eax, LKS_NOT
        jmp     .out
.ask:   mov     rax, loc(1)
        mov     edx, LKS_ASKED
        call    lk_put_hash
        mov     rcx, loc(0)
        call    u8_dup
        mov     ecx, [lk_pend_n]
        lea     rdx, [lk_pend]
        mov     [rdx+rcx*8], rax
        inc     dword [lk_pend_n]
        cmp     dword [lk_pend_n], LK_MAXPEND
        jb      .none
        call    like_flush
.none:  xor     eax, eax
.out:   EPROC

; Sends the queued URIs as one contains request.   Bufs: URL top 5.   Locals: 0 block, 1 n
PROC like_flush, 8
        mov     eax, [lk_pend_n]
        test    eax, eax
        jz      .out
        mov     loc(1), rax
        lea     ecx, [rax*8+8+8]
        call    mem_alloc
        mov     loc(0), rax
        mov     ecx, [lib_gen]
        mov     [rax], ecx
        mov     ecx, dword loc(1)
        mov     [rax+4], ecx
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [lp_contains]
        call    buf_append_z
        xor     ebx, ebx
.l:     cmp     rbx, loc(1)
        jae     .send
        test    rbx, rbx
        jz      .first
        lea     rcx, loc(5)
        lea     rdx, [s_comma]
        call    buf_append_z
.first: lea     rax, [lk_pend]
        mov     rsi, [rax+rbx*8]
        mov     rcx, rsi
        call    lk_hash
        mov     rdx, loc(0)
        mov     [rdx+8+rbx*8], rax
        mov     rcx, rsi
        call    u8_len
        mov     r8, rax
        lea     rcx, loc(5)
        mov     rdx, rsi
        call    buf_append_urlenc
        mov     rcx, rsi
        call    mem_free
        inc     rbx
        jmp     .l
.send:  mov     dword [lk_pend_n], 0
        mov     rcx, loc(5)
        mov     edx, TAG_CONTAINS
        mov     r8, loc(0)
        call    api_get
        lea     rcx, loc(5)
        call    buf_free
.out:   EPROC

; TAG_CONTAINS: [true,false,...] in the order of the request.   Locals: 0 job, 1 block, 2 root, 3 i
PROC h_contains, 4
        mov     rsi, rcx
        mov     loc(0), rcx
        mov     rax, [rsi+JB_ARG]
        mov     loc(1), rax
        mov     ecx, [rax]
        cmp     ecx, [lib_gen]
        jne     .free                           ; from before a sign-out / reload
        xor     ebx, ebx
        cmp     dword [rsi+JB_STATUS], 200
        jne     .fail
        mov     rax, [rsi+JB_RESP]
.ws:    cmp     byte [rax], 0
        je      .fail
        cmp     byte [rax], ' '
        ja      .root
        inc     rax
        jmp     .ws
.root:  mov     loc(2), rax
.l:     mov     rdx, loc(1)
        mov     ecx, [rdx+4]
        cmp     ebx, ecx
        jae     .paint
        mov     rcx, loc(2)
        mov     edx, ebx
        call    json_at
        mov     rcx, rax
        call    json_bool
        mov     edx, LKS_NOT
        test    eax, eax
        jz      .set
        mov     edx, LKS_SAVED
.set:   mov     rcx, loc(1)
        mov     rax, [rcx+8+rbx*8]
        call    lk_put_hash
        inc     ebx
        jmp     .l
.fail:  mov     rdx, loc(1)                     ; no answer: stop asking (hidden hearts, still clickable)
        mov     ecx, [rdx+4]
        cmp     ebx, ecx
        jae     .paint
        mov     rax, [rdx+8+rbx*8]
        mov     edx, LKS_NOT
        call    lk_put_hash
        inc     ebx
        jmp     .fail
.paint: mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
.free:  mov     rcx, loc(1)
        call    mem_free
        EPROC

; ---------------------------------------------------------------- toggling
; rcx = URI (UTF-8): flips its saved state now and tells Spotify.   Bufs: URL top 5.   Locals: 0 uri, 1 hash, 2 new state, 6 block
PROC like_toggle, 8
        mov     loc(0), rcx
        test    rcx, rcx
        jz      .out
        cmp     byte [rcx], 0
        je      .out
        call    lk_hash
        mov     loc(1), rax
        call    lk_slot
        mov     rax, [rdx]
        and     eax, 3
        mov     ecx, LKS_SAVED
        cmp     eax, LKS_SAVED
        jne     .set
        mov     ecx, LKS_NOT
.set:   mov     loc(2), rcx
        mov     rax, loc(1)
        mov     edx, ecx
        call    lk_put_hash
        cmp     dword [g_demo], 0
        jne     .paint
        mov     ecx, 24
        call    mem_alloc
        mov     loc(6), rax
        mov     ecx, [lib_gen]
        mov     [rax], ecx
        mov     rcx, loc(2)
        mov     [rax+4], ecx
        mov     rcx, loc(1)
        mov     [rax+8], rcx
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [lp_library]
        call    buf_append_z
        mov     rcx, loc(0)
        call    u8_len
        mov     r8, rax
        lea     rcx, loc(5)
        mov     rdx, loc(0)
        call    buf_append_urlenc
        lea     r9, [w_put]
        cmp     dword loc(2), LKS_SAVED
        je      .m
        lea     r9, [w_delete]
.m:     mov     rcx, loc(5)
        mov     edx, TAG_SAVE
        mov     r8, loc(6)
        call    api_call
        lea     rcx, loc(5)
        call    buf_free
.paint: mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
.out:   EPROC

; TAG_SAVE: Spotify answered a save / remove.  Anything but success flips the heart back.
PROC h_save, 4
        mov     rsi, rcx
        mov     rax, [rsi+JB_ARG]
        mov     loc(0), rax
        mov     ecx, [rax]
        cmp     ecx, [lib_gen]
        jne     .free
        mov     eax, [rsi+JB_STATUS]
        cmp     eax, 200
        je      .free
        cmp     eax, 204
        je      .free
        mov     rcx, loc(0)
        mov     rax, [rcx+8]
        mov     edx, LKS_SAVED                  ; we had removed it: it is still saved
        cmp     dword [rcx+4], LKS_SAVED
        jne     .rb
        mov     edx, LKS_NOT                    ; we had saved it: it is not saved after all
.rb:    call    lk_put_hash
        lea     rcx, [w_err_save]
        call    ui_toast
        mov     rcx, [hwnd]
        xor     edx, edx
        xor     r8d, r8d
        call    InvalidateRect
.free:  mov     rcx, loc(0)
        call    mem_free
        EPROC

; ---------------------------------------------------------------- the button
; ecx = x, edx = y, r8d = box (square), r9d = hit argument, [rbp+48] = URI (UTF-8) or 0, [rbp+56] = 1 to show the
; outline even when the item is not saved (otherwise only a saved item shows its heart).  Registers the hit target.
PROC draw_heart, 8
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     loc(2), r8
        mov     loc(3), r9
        mov     eax, stk6
        mov     loc(5), rax
        mov     rcx, stk5
        test    rcx, rcx
        jz      .hit
        cmp     byte [rcx], 0
        je      .hit
        call    like_state
        mov     loc(4), rax
        mov     eax, dword loc(2)
        imul    eax, 3
        shr     eax, 2
        mov     r12d, eax                       ; icon size = 75 % of the box
        mov     eax, dword loc(2)
        sub     eax, r12d
        shr     eax, 1
        mov     r13d, eax                       ; inset
        cmp     dword loc(4), LKS_SAVED
        je      .filled
        cmp     dword loc(5), 0
        je      .hit                            ; not saved and not asked to show: nothing drawn
        SETCOL  T_MUTED_FG
        cmp     dword [hover_id], H_LIKE
        jne     .ol
        mov     eax, dword loc(3)
        cmp     [hover_arg], eax
        jne     .ol
        SETCOL  T_FG
.ol:    lea     r9, [ic_heart]
        jmp     .draw
.filled: SETCOL T_ACCENT
        lea     r9, [ic_heart_f]
.draw:  mov     ecx, dword loc(0)
        add     ecx, r13d
        mov     edx, dword loc(1)
        add     edx, r13d
        mov     r8d, r12d
        call    icon_draw
.hit:   mov     eax, H_LIKE
        mov     outarg(5), rax
        mov     eax, dword loc(3)
        mov     outarg(6), rax
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, r8d
        call    hit_add
        EPROC

; arg of an H_LIKE target -> rax = the URI it stands for (UTF-8, not owned) or 0
;   (0xFFFF << 16) = the playing track, (0xFFFE << 16) = the open playlist / album page, else (list source << 16 | row)
like_uri_for:
        mov     edx, ecx
        shr     edx, 16
        cmp     edx, 0xFFFF
        je      .np
        cmp     edx, 0xFFFE
        je      .det
        sub     rsp, 40
        call    track_for_arg
        add     rsp, 40
        test    rax, rax
        jz      .r
        mov     rax, [rax+TR_URI]
.r:     ret
.np:    cmp     dword [np_valid], 0
        je      .none
        mov     rax, [np_uri]
        ret
.det:   mov     rax, [det_uri]
        ret
.none:  xor     eax, eax
        ret
