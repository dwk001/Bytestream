; dialog.asm - the modal dialog used to create, edit and delete playlists.
;
; Two native EDIT controls (name, description) are placed over the panel while a create / edit dialog is open;
; everything else is drawn like the rest of the interface.  The dialog is modal: a full-window hit target
; swallows clicks outside the panel.

%define H_NEW_PL     40
%define H_DET_EDIT   41
%define H_DET_DELETE 42
%define H_DLG_BG     43
%define H_DLG_OK     44
%define H_DLG_CANCEL 45
%define H_DLG_PUBLIC 46

%define DK_CREATE    1
%define DK_EDIT      2
%define DK_DELETE    3                  ; delete a playlist of ours / remove one we only follow

section .bss
dlg_kind:       resd 1
dlg_public:     resd 1
dlg_mine:       resd 1                  ; the playlist is ours (delete) rather than followed (remove)
dlg_id:         resq 1                  ; owned UTF-8 playlist id (edit / delete)
dlg_msg:        resq 1                  ; owned UTF-16 question (delete)
                align 8
dlg_wbuf:       resw 260

section .data
WSTR w_dlg_new, "New playlist"
WSTR w_dlg_edit, "Edit details"
WSTR w_dlg_delete, "Delete playlist"
WSTR w_dlg_remove, "Remove playlist"
WSTR w_dlg_name, "Name"
WSTR w_dlg_desc, "Description (optional)"
WSTR w_dlg_public, "Public"
WSTR w_dlg_private, "Private"
WSTR w_dlg_create, "Create"
WSTR w_dlg_save, "Save"
WSTR w_dlg_cancel, "Cancel"
WSTR w_dlg_confirm_del, "Delete"
WSTR w_dlg_confirm_rm, "Remove"
WSTR w_dlg_q1, "Delete "
WSTR w_dlg_q1b, "Remove "
WSTR w_dlg_q2, "? It will disappear from your library."
WSTR w_dlg_q2b, " from your library?"
WSTR w_dlg_noname, "Give the playlist a name first."
WSTR w_quote_w, `"`
section .text

; ecx = kind, rdx = Card* of the playlist (edit / delete) or 0
PROC dlg_open, 8
        mov     loc(0), rcx
        mov     loc(1), rdx
        call    menu_close
        call    dlg_clear
        mov     eax, dword loc(0)
        mov     [dlg_kind], eax
        mov     rbx, loc(1)
        test    rbx, rbx
        jz      .fields
        mov     rcx, [rbx+CD_ID]
        call    u8_dup0
        mov     [dlg_id], rax
        mov     eax, [rbx+CD_FLAGS]
        mov     ecx, eax
        shr     ecx, 2
        and     ecx, 1
        mov     [dlg_public], ecx
        shr     eax, 1
        and     eax, 1
        mov     [dlg_mine], eax
.fields:
        cmp     dword loc(0), DK_DELETE
        je      .question
        ; name / description boxes
        mov     rcx, [edit_dn]
        lea     rdx, [empty_w]
        test    rbx, rbx
        jz      .nm
        mov     rdx, [rbx+CD_NAME]
.nm:    call    field_set_text
        mov     rcx, [edit_dd]
        lea     rdx, [empty_w]
        call    field_set_text
        mov     rdx, [cli_dlg_name]             ; tests type into the fields through these flags
        test    rdx, rdx
        jz      .nt1
        mov     rcx, [edit_dn]
        call    field_set_text
.nt1:   mov     rdx, [cli_dlg_desc]
        test    rdx, rdx
        jz      .nt2
        mov     rcx, [edit_dd]
        call    field_set_text
.nt2:   mov     dword [focus_req], 4
        jmp     .out
.question:
        BUFZERO 5
        lea     rcx, loc(5)
        lea     rdx, [w_dlg_q1]
        cmp     dword [dlg_mine], 0
        jne     .q1
        lea     rdx, [w_dlg_q1b]
.q1:    call    buf_append_w
        lea     rcx, loc(5)
        lea     rdx, [w_quote_w]
        call    buf_append_w
        lea     rcx, loc(5)
        mov     rdx, [rbx+CD_NAME]
        call    buf_append_w
        lea     rcx, loc(5)
        lea     rdx, [w_quote_w]
        call    buf_append_w
        lea     rcx, loc(5)
        lea     rdx, [w_dlg_q2]
        cmp     dword [dlg_mine], 0
        jne     .q2
        lea     rdx, [w_dlg_q2b]
.q2:    call    buf_append_w
        lea     rcx, loc(5)
        mov     edx, 2
        call    buf_reserve                     ; room for the terminator
        mov     rax, loc(5)
        mov     rcx, loc(4)
        mov     word [rax+rcx], 0
        mov     [dlg_msg], rax
.out:   EPROC

; rcx = Buf*, rdx = UTF-16 z-string: appends its characters (no terminator)
PROC buf_append_w, 2
        mov     loc(0), rcx
        mov     loc(1), rdx
        mov     rcx, rdx
        xor     eax, eax
.n:     cmp     word [rcx+rax*2], 0
        je      .go
        inc     rax
        jmp     .n
.go:    lea     r8, [rax*2]
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        call    buf_append
        EPROC

; Closes the dialog and forgets its target
PROC dlg_clear, 0
        mov     rcx, [dlg_id]
        call    mem_free
        mov     qword [dlg_id], 0
        mov     rcx, [dlg_msg]
        call    mem_free
        mov     qword [dlg_msg], 0
        mov     dword [dlg_kind], 0
        EPROC

; The OK button.   Locals: 0 name (UTF-8), 1 description (UTF-8)
PROC dlg_commit, 4
        cmp     dword [g_demo], 0
        je      .live
        lea     rcx, [w_pl_demo]                ; the demo has no account to change
        call    ui_toast
        jmp     .close
.live:  cmp     dword [dlg_kind], DK_DELETE
        jne     .fields
        mov     rcx, [dlg_id]
        test    rcx, rcx
        jz      .close
        call    pl_delete
        jmp     .close
.fields:
        mov     rcx, [edit_dn]
        lea     rdx, [dlg_wbuf]
        mov     r8d, 255
        call    field_get_text
        lea     rcx, [dlg_wbuf]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(0), rax
        mov     rsi, rax
.blank: cmp     byte [rsi], ' '                 ; an all-blank name is no name
        jne     .chk
        inc     rsi
        jmp     .blank
.chk:   cmp     byte [rsi], 0
        jne     .named
        mov     rcx, loc(0)
        call    mem_free
        lea     rcx, [w_dlg_noname]
        call    ui_toast
        jmp     .out                            ; stay open
.named: mov     rcx, [edit_dd]
        lea     rdx, [dlg_wbuf]
        mov     r8d, 255
        call    field_get_text
        lea     rcx, [dlg_wbuf]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(1), rax
        cmp     dword [dlg_kind], DK_EDIT
        je      .edit
        mov     rcx, loc(0)
        mov     rdx, loc(1)
        mov     r8d, [dlg_public]
        call    pl_create
        jmp     .free
.edit:  mov     rcx, [dlg_id]
        mov     rdx, loc(0)
        mov     r8, loc(1)
        mov     r9d, [dlg_public]
        call    pl_update
        ; the open page shows the new name at once
        mov     rcx, [dlg_id]
        call    pl_is_open
        test    eax, eax
        jz      .free
        mov     rcx, [det_title]
        call    mem_free
        mov     rcx, [edit_dn]                  ; (dlg_wbuf holds the description now: read the name again)
        lea     rdx, [dlg_wbuf]
        mov     r8d, 255
        call    field_get_text
        lea     rcx, [dlg_wbuf]
        call    w_dup
        mov     [det_title], rax
.free:  mov     rcx, loc(0)
        call    mem_free
        mov     rcx, loc(1)
        call    mem_free
.close: call    dlg_clear
.out:   EPROC

; The panel and its controls.   Locals: 0 x, 1 y, 2 w, 3 h, 4 pad, 5 cursor y
PROC paint_dialog, 2
        cmp     dword [dlg_kind], 0
        je      .out
        mov     ecx, AC_DLG
        call    anim_get
        mov     [gfx_alpha], eax
        call    paint_dialog_body
        mov     dword [gfx_alpha], 256
.out:   EPROC

PROC paint_dialog_body, 8
        mov     ecx, 0xB0000000                 ; dim everything behind
        call    gfx_color
        RECT    0, 0, dword [ui_w], dword [ui_h]
        HIT     0, 0, dword [ui_w], dword [ui_h], H_DLG_BG, 0
        S       24
        mov     loc(4), rax
        S       460
        mov     ecx, [ui_w]
        mov     edx, dword loc(4)
        add     edx, edx
        sub     ecx, edx
        cmp     eax, ecx
        cmova   eax, ecx
        mov     loc(2), rax
        S       380
        cmp     dword [dlg_kind], DK_DELETE
        jne     .h
        S       200
.h:     mov     loc(3), rax
        mov     eax, [ui_w]
        sub     eax, dword loc(2)
        shr     eax, 1
        mov     loc(0), rax
        mov     eax, [ui_h]
        sub     eax, dword loc(3)
        jns     .yc
        xor     eax, eax
.yc:    shr     eax, 1
        mov     loc(1), rax
        SETCOL  T_SURFACE2                      ; darker than the fields so they stand out
        S       14
        mov     outarg(5), rax
        mov     ecx, dword loc(0)
        mov     edx, dword loc(1)
        mov     r8d, dword loc(2)
        mov     r9d, dword loc(3)
        call    gfx_rrect_fill_border
        HIT     dword loc(0), dword loc(1), dword loc(2), dword loc(3), H_SHELL, 0
        ; content column
        mov     r12d, dword loc(0)
        add     r12d, dword loc(4)              ; x
        mov     r13d, dword loc(2)
        sub     r13d, dword loc(4)
        sub     r13d, dword loc(4)              ; width
        mov     r14d, dword loc(1)
        add     r14d, dword loc(4)              ; y
        SETFONT F_H2
        SETCOL  T_FG
        SETALIGN 0
        lea     rcx, [w_dlg_new]
        cmp     dword [dlg_kind], DK_EDIT
        jne     .t1
        lea     rcx, [w_dlg_edit]
.t1:    cmp     dword [dlg_kind], DK_DELETE
        jne     .t2
        lea     rcx, [w_dlg_remove]
        cmp     dword [dlg_mine], 0
        je      .t2
        lea     rcx, [w_dlg_delete]
.t2:    S       32
        mov     ebx, eax
        mov     edx, r12d
        mov     r8d, r14d
        mov     r9d, r13d
        mov     outarg(5), rbx
        call    gfx_text
        S       50
        add     r14d, eax
        cmp     dword [dlg_kind], DK_DELETE
        je      .delete
        ; ---- name
        SETFONT F_CAPTION
        SETCOL  T_MUTED_FG
        S       18
        mov     ebx, eax
        TXTL    w_dlg_name, r12d, r14d, r13d, ebx
        S       22
        add     r14d, eax
        S       44
        mov     esi, eax                        ; field height
        mov     ecx, r12d
        mov     edx, r14d
        mov     r8d, r13d
        mov     r9d, esi
        mov     qword outarg(5), 4
        call    draw_edit_frame
        lea     r14d, [r14+rsi]
        S       14
        add     r14d, eax
        ; ---- description
        SETFONT F_CAPTION
        SETCOL  T_MUTED_FG
        S       18
        mov     ebx, eax
        TXTL    w_dlg_desc, r12d, r14d, r13d, ebx
        S       22
        add     r14d, eax
        mov     ecx, r12d
        mov     edx, r14d
        mov     r8d, r13d
        mov     r9d, esi
        mov     qword outarg(5), 5
        call    draw_edit_frame
        lea     r14d, [r14+rsi]
        S       16
        add     r14d, eax
        ; ---- public / private
        lea     rcx, [w_dlg_private]
        cmp     dword [dlg_public], 0
        je      .pp
        lea     rcx, [w_dlg_public]
.pp:    mov     edx, r12d
        mov     r8d, r14d
        mov     r9d, [dlg_public]
        mov     qword outarg(5), H_DLG_PUBLIC
        mov     qword outarg(6), 0
        call    draw_pill
        jmp     .buttons
.delete:
        SETFONT F_BODY
        SETCOL  T_MUTED_FG
        mov     rcx, [dlg_msg]
        mov     edx, r12d
        mov     r8d, r14d
        mov     r9d, r13d
        S       26
        mov     outarg(5), rax
        call    gfx_text
.buttons:
        S       44
        mov     esi, eax                        ; button height
        mov     eax, dword loc(1)
        add     eax, dword loc(3)
        sub     eax, dword loc(4)
        sub     eax, esi
        mov     r14d, eax                       ; button y
        S       124
        mov     ebx, eax                        ; OK width
        mov     edx, r12d
        add     edx, r13d
        sub     edx, ebx                        ; OK x
        lea     rcx, [w_dlg_create]
        cmp     dword [dlg_kind], DK_EDIT
        jne     .b1
        lea     rcx, [w_dlg_save]
.b1:    xor     eax, eax                        ; style 0: primary
        cmp     dword [dlg_kind], DK_DELETE
        jne     .b2
        lea     rcx, [w_dlg_confirm_rm]
        cmp     dword [dlg_mine], 0
        je      .b2
        lea     rcx, [w_dlg_confirm_del]
        mov     eax, 2                          ; danger
.b2:    mov     outarg(8), rax
        mov     r8d, r14d
        mov     r9d, ebx
        mov     outarg(5), rsi
        mov     qword outarg(6), H_DLG_OK
        mov     qword outarg(7), 0
        call    draw_button
        S       110
        mov     edi, eax                        ; Cancel width
        S       12
        mov     edx, r12d
        add     edx, r13d
        sub     edx, ebx
        sub     edx, eax
        sub     edx, edi                        ; Cancel x
        lea     rcx, [w_dlg_cancel]
        mov     r8d, r14d
        mov     r9d, edi
        mov     outarg(5), rsi
        mov     qword outarg(6), H_DLG_CANCEL
        mov     qword outarg(7), 0
        mov     qword outarg(8), 1
        call    draw_button
.out:   EPROC
