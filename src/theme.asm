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
        ; ---- midnight: deep navy with a sky-blue accent
        dd 0xFF0B1220, 0xFFE8EEF8, 0xFF8A99B0, 0x33FFFFFF, 0xFF1A2438
        dd 0xFF101A2C, 0x1AFFFFFF, 0x33FFFFFF, 0x2638BDF8, 0xFF38BDF8
        dd 0xFF38BDF8, 0xFF06101F, 0xFF1A2438, 0xFFE8EEF8, 0xFF080E1A
        dd 0xFF1A2438, 0xFF0F1828, 0x33FFFFFF, 0xFF9B1C1C, 0xFF8A99B0
        dd 0xFF3A4A66
        ; ---- light: white with the Spotify green
        dd 0xFFFFFFFF, 0xFF121212, 0xFF6A6A6A, 0x33000000, 0xFFEDEDED
        dd 0xFFF6F6F6, 0x14000000, 0x24000000, 0x261DB954, 0xFF168F40
        dd 0xFF1DB954, 0xFF000000, 0xFFFFFFFF, 0xFF121212, 0xFFF0F0F0
        dd 0xFFE2E2E2, 0xFFDCDCDC, 0x1F000000, 0xFFB91C1C, 0xFF6A6A6A
        dd 0xFFC8C8C8

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
