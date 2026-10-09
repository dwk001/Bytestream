; theme.asm - dark / midnight / light colour tokens.
; Values are 0xAARRGGBB as GDI+ expects.

%define T_BG            0
%define T_FG            1
%define T_MUTED_FG      2
%define T_BORDER        3
%define T_SURFACE       4               ; "muted": cards, inputs, pills
%define T_SURFACE2      5               ; "secondary": bars and panels
%define T_HOVER         6               ; table_hover
%define T_ACTIVE        7               ; secondary_active
%define T_ROW_ACTIVE    8               ; table_active
%define T_ACCENT        9               ; selection
%define T_PRIMARY       10
%define T_PRIMARY_FG    11
%define T_POPOVER       12
%define T_PROGRESS      13
%define T_SIDEBAR       14
%define T_SIDEBAR_ACC   15
%define T_SIDEBAR_BORDER 16
%define T_ROW_BORDER    17
%define T_DANGER        18
%define T_HEAD_FG       19
%define T_TRACK         20              ; unfilled part of seek / volume bars
%define NTHEME          21

%define THEME_DARK      0
%define THEME_MIDNIGHT  1
%define THEME_LIGHT     2

section .data
align 4
themes:
        ; ---- dark: background #121212, surface #181818, accent #1DB954
        ;      bg         fg          muted fg    border      control surface
        dd 0xFF121212, 0xFFFFFFFF, 0xFFB3B3B3, 0x1FFFFFFF, 0xFF282828
        ;      panels     hover       pressed     playing row accent
        dd 0xFF181818, 0x1AFFFFFF, 0x33FFFFFF, 0x261DB954, 0xFF1DB954
        ;      primary    primary fg  popover     progress    sidebar
        dd 0xFF1DB954, 0xFF000000, 0xFF282828, 0xFFFFFFFF, 0xFF000000
        ;      sidebar sel sidebar border  row border  danger      table head
        dd 0xFF282828, 0xFF1A1A1A, 0x33FFFFFF, 0xFF8B1A1A, 0xFFB3B3B3
        dd 0xFF535353
        ; ---- midnight
        dd 0xFF07111F, 0xFFE6EDF7, 0xFF8296AD, 0x66406892, 0xFF15283D
        dd 0xFF102238, 0x661C3F62, 0x662F5B8C, 0x330284C7, 0xFF0284C7
        dd 0xFF38BDF8, 0xFF07111F, 0xFF0B1A2C, 0xFF38BDF8, 0xFF091827
        dd 0x662C5486, 0xFF1E344D, 0xB31E344D, 0xFF991B1B, 0xFF8296AD
        dd 0xFF2F5B8C
        ; ---- light
        dd 0xFFFAFAFA, 0xFF171717, 0xFF606060, 0x669B9B9B, 0xFFE5E5E5
        dd 0xFFF5F5F5, 0x66E8E8E8, 0x66B7B7B7, 0x1F2563EB, 0xFF2563EB
        dd 0xFF171717, 0xFFFAFAFA, 0xFFFFFFFF, 0xFF262626, 0xFFF5F5F5
        dd 0x66CDCDCD, 0xFFD4D4D4, 0xB3D4D4D4, 0xFFB91C1C, 0xFF666666
        dd 0xFFC4C4C4

section .bss
th:             resd NTHEME
theme_idx:      resd 1

section .text

; ecx = THEME_* index
theme_set:
        cmp     ecx, 2
        jbe     .ok
        xor     ecx, ecx
.ok:    mov     [theme_idx], ecx
        push    rsi
        push    rdi
        imul    eax, ecx, NTHEME*4
        lea     rsi, [themes]
        add     rsi, rax
        lea     rdi, [th]
        mov     ecx, NTHEME
        rep     movsd
        pop     rdi
        pop     rsi
        ret

%macro SETCOL 1
        mov     ecx, [th+4*(%1)]
        call    gfx_color
%endmacro

; colour with its alpha replaced: SETCOL_A token, alpha(0..255)
%macro SETCOL_A 2
        mov     ecx, [th+4*(%1)]
        and     ecx, 0x00FFFFFF
        or      ecx, (%2) << 24
        call    gfx_color
%endmacro

%macro SETFONT 1
        mov     ecx, %1
        call    gfx_font
%endmacro

%macro SETALIGN 1
        mov     ecx, %1
        call    gfx_align
%endmacro
