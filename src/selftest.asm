; selftest.asm - `bytestream.exe --selftest` exercises the pure-logic routines and prints one line per check.

section .bss
g_fail:         resq 1
g_pass:         resq 1

section .data
st_ok:          db "ok   ", 0
st_bad:         db "FAIL ", 0
st_nl:          db 10, 0
st_sum:         db "selftest done", 10, 0

section .text

; ecx = condition (non-zero = pass), rdx = name
PROC t_check, 1
        mov     loc(0), rdx
        test    ecx, ecx
        jz      .bad
        inc     qword [g_pass]
        lea     rcx, [st_ok]
        call    out_z
        jmp     .nm
.bad:   inc     qword [g_fail]
        lea     rcx, [st_bad]
        call    out_z
.nm:    mov     rcx, loc(0)
        call    out_z
        lea     rcx, [st_nl]
        call    out_z
        EPROC

; rcx = actual z-string (not freed), rdx = expected z-string, r8 = name
PROC t_str, 1
        mov     loc(0), r8
        call    u8_eq
        mov     ecx, eax
        mov     rdx, loc(0)
        call    t_check
        EPROC

; rcx = actual integer, rdx = expected, r8 = name
PROC t_int, 1
        mov     loc(0), r8
        xor     eax, eax
        cmp     rcx, rdx
        sete    al
        mov     ecx, eax
        mov     rdx, loc(0)
        call    t_check
        EPROC


; rcx = actual UTF-16 string, rdx = expected UTF-8 z-string, r8 = name
PROC t_wstr, 2
        mov     loc(0), r8
        mov     loc(1), rdx
        mov     rdx, -1
        call    w_to_u8
        mov     rbx, rax
        mov     rcx, rax
        mov     rdx, loc(1)
        mov     r8, loc(0)
        call    t_str
        mov     rcx, rbx
        call    mem_free
        EPROC

; rcx = List*, edx = element index, esize = r8d -> rax = element pointer
list_at:
        mov     rax, rdx
        imul    rax, r8
        add     rax, [rcx+LS_PTR]
        ret

%macro TNAME 2
%1:     db %2, 0
%endmacro

section .data
j_doc:  db '{"a":1,"b":{"c":[10,20,{"d":"hi\nthere é 🎵 \"q\" \\ \/"}]},"s":"x","t":true,"f":false,"n":null,"neg":-42,"e":{},"ea":[]}', 0
j_exp:  db 'hi', 10, 'there ', 0xC3, 0xA9, ' ', 0xF0, 0x9F, 0x8E, 0xB5, ' "q" \ /', 0
j_ws:   db 10, 9, ' { "k" : [ 1 , 2 ] }  ', 0
p_a:    db "a", 0
p_b_c_1: db "b.c.1", 0
p_b_c_2_d: db "b.c.2.d", 0
p_b_c:  db "b.c", 0
p_s:    db "s", 0
p_t:    db "t", 0
p_f:    db "f", 0
p_neg:  db "neg", 0
p_zz:   db "zz", 0
p_b_c_9: db "b.c.9", 0
p_n:    db "n", 0
p_ea:   db "ea", 0
p_k_1:  db "k.1", 0
p_k:    db "k", 0
x_x:    db "x", 0
t_a:    db "json: member a", 0
t_arr:  db "json: array index", 0
t_deep: db "json: nested string with escapes, \u, surrogates", 0
t_cnt:  db "json: count", 0
t_miss: db "json: missing key -> 0", 0
t_oor:  db "json: out of range -> 0", 0
t_str1: db "json: simple string", 0
t_true: db "json: true", 0
t_false: db "json: false", 0
t_neg:  db "json: negative int", 0
t_null: db "json: null decodes as empty string", 0
t_empty: db "json: empty array count", 0
t_wsp:  db "json: whitespace tolerance", 0
t_b64a: db "b64url: abc", 0
t_b64b: db "b64url: no padding / url alphabet", 0
t_b64c: db "b64url: 1 and 2 byte tails", 0
t_time: db "fmt_time: 1:05", 0
t_time2: db "fmt_time: 0:00", 0
t_time3: db "fmt_time: 61:01", 0
t_enc:  db "urlenc: reserved characters", 0
t_rt:   db "utf8<->utf16 round trip", 0
t_buf:  db "buf: append across growth", 0
t_u64:  db "u64 formatting", 0
b_abc:  db "abc", 0
b_exp1: db "YWJj", 0
b_exp2: db "-_8", 0
b_exp3: db "YQ", 0
b_exp4: db "YWI", 0
u_in:   db "a b&c/d=é~", 0
u_exp:  db "a%20b%26c%2Fd%3D%C3%A9~", 0
u_rt:   db "Zażółć gęślą jaźń ", 0xE2, 0x99, 0xAA, 0


section .data
ZSTR m_items, "items"
ZSTR m_albums_items, "albums.items"
ZSTR m_tracks_items, "tracks.items"
ZSTR m_artists_items, "artists.items"
ZSTR m_playlists_items, "playlists.items"
ZSTR m_queue, "queue"
ZSTR m_wrap_album, "album"
ZSTR m_e1, "Daily Mix 1"
ZSTR m_e2, "By Demo Listener"
ZSTR m_e3, "Midnight Lanterns"
ZSTR m_e4, "Neon Harbor, Saffron Static"
ZSTR m_e5, "Paper Honey"
ZSTR m_e6, "Glass Orchard"
ZSTR m_e7, "City of Lanterns"
ZSTR m_e8, "demo:2"
ZSTR m_e9, "Artist"
ZSTR m_e10, "Neon Harbor"
ZSTR m_e11, "spotify:track:tr0001"
ZSTR m_e12, "spotify:playlist:pl000"
ZSTR m_e13, "demo:20"
ZSTR m_e14, "demo:1"
ZSTR tm_pl_count, "model: playlists parsed (10)"
ZSTR tm_pl_name, "model: playlist name"
ZSTR tm_pl_sub, "model: playlist owner line"
ZSTR tm_pl_total, "model: playlist item total (items.total)"
ZSTR tm_pl_uri, "model: playlist uri"
ZSTR tm_pl_img, "model: playlist medium image"
ZSTR tm_it_count, "model: playlist items parsed via item wrapper (24)"
ZSTR tm_it_title, "model: track title"
ZSTR tm_it_artists, "model: two artists joined"
ZSTR tm_it_title2, "model: second track title"
ZSTR tm_it_artist2, "model: single artist"
ZSTR tm_it_album, "model: album name"
ZSTR tm_it_dur, "model: duration"
ZSTR tm_it_uri, "model: track uri"
ZSTR tm_it_img, "model: smallest cover is last image"
ZSTR tm_it_imgl, "model: largest cover is first image"
ZSTR tm_sv_count, "model: saved tracks via track wrapper (20)"
ZSTR tm_al_count, "model: saved albums (8)"
ZSTR tm_al_sub, "model: album artists line"
ZSTR tm_al_total, "model: album total_tracks"
ZSTR tm_s_tracks, "model: search tracks (10)"
ZSTR tm_s_albums, "model: search albums (4)"
ZSTR tm_s_artists, "model: search artists (4)"
ZSTR tm_s_artist_sub, "model: artist card sub line"
ZSTR tm_s_pl, "model: search playlists skip null (3)"
ZSTR tm_q_count, "model: queue (12)"
ZSTR tm_free, "model: free lists"

section .bss
l_a:            resq 3
l_b:            resq 3
l_c:            resq 3

section .bss
                align 8
st_tmp:         resb 256
st_buf:         resq 3

section .text
PROC selftest, 8
        ; ---- json
        lea     rcx, [j_doc]
        lea     rdx, [p_a]
        call    json_path
        mov     rcx, rax
        call    json_int
        mov     rcx, rax
        mov     edx, 1
        lea     r8, [t_a]
        call    t_int

        lea     rcx, [j_doc]
        lea     rdx, [p_b_c_1]
        call    json_path
        mov     rcx, rax
        call    json_int
        mov     rcx, rax
        mov     edx, 20
        lea     r8, [t_arr]
        call    t_int

        lea     rcx, [j_doc]
        lea     rdx, [p_b_c_2_d]
        call    json_path
        mov     rcx, rax
        call    json_str_u8
        mov     loc(0), rax
        mov     rcx, rax
        lea     rdx, [j_exp]
        lea     r8, [t_deep]
        call    t_str
        mov     rcx, loc(0)
        call    mem_free

        lea     rcx, [j_doc]
        lea     rdx, [p_b_c]
        call    json_path
        mov     rcx, rax
        call    json_count
        mov     rcx, rax
        mov     edx, 3
        lea     r8, [t_cnt]
        call    t_int

        lea     rcx, [j_doc]
        lea     rdx, [p_zz]
        call    json_path
        mov     rcx, rax
        xor     edx, edx
        lea     r8, [t_miss]
        call    t_int

        lea     rcx, [j_doc]
        lea     rdx, [p_b_c_9]
        call    json_path
        mov     rcx, rax
        xor     edx, edx
        lea     r8, [t_oor]
        call    t_int

        lea     rcx, [j_doc]
        lea     rdx, [p_s]
        call    json_path
        mov     rcx, rax
        call    json_str_u8
        mov     loc(0), rax
        mov     rcx, rax
        lea     rdx, [x_x]
        lea     r8, [t_str1]
        call    t_str
        mov     rcx, loc(0)
        call    mem_free

        lea     rcx, [j_doc]
        lea     rdx, [p_t]
        call    json_path
        mov     rcx, rax
        call    json_bool
        mov     ecx, eax
        lea     rdx, [t_true]
        call    t_check

        lea     rcx, [j_doc]
        lea     rdx, [p_f]
        call    json_path
        mov     rcx, rax
        call    json_bool
        xor     ecx, ecx
        test    eax, eax
        sete    cl
        lea     rdx, [t_false]
        call    t_check

        lea     rcx, [j_doc]
        lea     rdx, [p_neg]
        call    json_path
        mov     rcx, rax
        call    json_int
        mov     rcx, rax
        mov     rdx, -42
        lea     r8, [t_neg]
        call    t_int

        lea     rcx, [j_doc]
        lea     rdx, [p_n]
        call    json_path
        mov     rcx, rax
        call    json_str_u8
        mov     loc(0), rax
        mov     rcx, rax
        lea     rdx, [st_nl+1]          ; empty string
        lea     r8, [t_null]
        call    t_str
        mov     rcx, loc(0)
        call    mem_free

        lea     rcx, [j_doc]
        lea     rdx, [p_ea]
        call    json_path
        mov     rcx, rax
        call    json_count
        mov     rcx, rax
        xor     edx, edx
        lea     r8, [t_empty]
        call    t_int

        lea     rcx, [j_ws]
        lea     rdx, [p_k_1]
        call    json_path
        mov     rcx, rax
        call    json_int
        mov     rcx, rax
        mov     edx, 2
        lea     r8, [t_wsp]
        call    t_int

        ; ---- base64url
        lea     rcx, [b_abc]
        mov     edx, 3
        lea     r8, [st_tmp]
        call    b64url_enc
        lea     r11, [st_tmp]
        mov     byte [r11+rax], 0
        lea     rcx, [st_tmp]
        lea     rdx, [b_exp1]
        lea     r8, [t_b64a]
        call    t_str

        mov     byte [st_tmp+100], 0xFB
        mov     byte [st_tmp+101], 0xFF
        lea     rcx, [st_tmp+100]
        mov     edx, 2
        lea     r8, [st_tmp]
        call    b64url_enc
        lea     r11, [st_tmp]
        mov     byte [r11+rax], 0
        lea     rcx, [st_tmp]
        lea     rdx, [b_exp2]
        lea     r8, [t_b64b]
        call    t_str

        lea     rcx, [b_abc]
        mov     edx, 1
        lea     r8, [st_tmp]
        call    b64url_enc
        lea     r11, [st_tmp]
        mov     byte [r11+rax], 0
        lea     rcx, [st_tmp]
        lea     rdx, [b_exp3]
        lea     r8, [t_b64c]
        call    t_str
        lea     rcx, [b_abc]
        mov     edx, 2
        lea     r8, [st_tmp]
        call    b64url_enc
        lea     r11, [st_tmp]
        mov     byte [r11+rax], 0
        lea     rcx, [st_tmp]
        lea     rdx, [b_exp4]
        lea     r8, [t_b64c]
        call    t_str

        ; ---- time formatting (wide -> utf8 for the comparison)
        lea     rcx, [st_tmp+128]
        mov     edx, 65000
        call    w_fmt_time
        lea     rcx, [st_tmp+128]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(0), rax
        mov     rcx, rax
        lea     rdx, [s_105]
        lea     r8, [t_time]
        call    t_str
        mov     rcx, loc(0)
        call    mem_free

        lea     rcx, [st_tmp+128]
        xor     edx, edx
        call    w_fmt_time
        lea     rcx, [st_tmp+128]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(0), rax
        mov     rcx, rax
        lea     rdx, [s_000]
        lea     r8, [t_time2]
        call    t_str
        mov     rcx, loc(0)
        call    mem_free

        lea     rcx, [st_tmp+128]
        mov     edx, 3661000
        call    w_fmt_time
        lea     rcx, [st_tmp+128]
        mov     rdx, -1
        call    w_to_u8
        mov     loc(0), rax
        mov     rcx, rax
        lea     rdx, [s_6101]
        lea     r8, [t_time3]
        call    t_str
        mov     rcx, loc(0)
        call    mem_free

        ; ---- url encoding via Buf
        lea     rcx, [st_buf]
        call    buf_free
        lea     rcx, [u_in]
        call    u8_len
        mov     r8, rax
        lea     rcx, [st_buf]
        lea     rdx, [u_in]
        call    buf_append_urlenc
        mov     rcx, [st_buf]
        lea     rdx, [u_exp]
        lea     r8, [t_enc]
        call    t_str

        ; ---- utf8 <-> utf16 round trip
        lea     rcx, [u_rt]
        mov     rdx, -1
        call    u8_to_w
        mov     loc(1), rax
        mov     rcx, rax
        mov     rdx, -1
        call    w_to_u8
        mov     loc(2), rax
        mov     rcx, rax
        lea     rdx, [u_rt]
        lea     r8, [t_rt]
        call    t_str
        mov     rcx, loc(1)
        call    mem_free
        mov     rcx, loc(2)
        call    mem_free

        ; ---- buffer growth: append 1000 numbers
        lea     rcx, [st_buf]
        call    buf_free
        xor     ebx, ebx
.bl:    lea     rcx, [st_buf]
        mov     rdx, rbx
        call    buf_append_u64
        lea     rcx, [st_buf]
        mov     edx, ','
        call    buf_append_char
        inc     ebx
        cmp     ebx, 1000
        jb      .bl
        mov     rax, [st_buf+BUF_LEN]
        xor     ecx, ecx
        cmp     rax, 3890               ; 10*1 + 90*2 + 900*3 digits + 1000 commas
        sete    cl
        lea     rdx, [t_buf]
        call    t_check

        lea     rcx, [st_tmp]
        mov     rdx, 18446744073709551615
        call    u8_put_u64
        mov     byte [rax], 0
        lea     rcx, [st_tmp]
        lea     rdx, [s_u64max]
        lea     r8, [t_u64]
        call    t_str


        ; ---- model parsers over the embedded fixtures
        lea     rcx, [fx_playlists]
        lea     rdx, [m_items]
        lea     r8, [l_a]
        mov     r9d, KIND_PLAYLIST
        mov     qword outarg(5), 0
        call    parse_cards
        mov     rcx, [l_a+LS_COUNT]
        mov     edx, 10
        lea     r8, [tm_pl_count]
        call    t_int
        lea     rcx, [l_a]
        xor     edx, edx
        mov     r8d, CD_SIZE
        call    list_at
        mov     rbx, rax
        mov     rcx, [rbx+CD_NAME]
        lea     rdx, [m_e1]
        lea     r8, [tm_pl_name]
        call    t_wstr
        mov     rcx, [rbx+CD_SUB]
        lea     rdx, [m_e2]
        lea     r8, [tm_pl_sub]
        call    t_wstr
        mov     ecx, [rbx+CD_COUNT]
        mov     edx, 12
        lea     r8, [tm_pl_total]
        call    t_int
        mov     rcx, [rbx+CD_URI]
        lea     rdx, [m_e12]
        lea     r8, [tm_pl_uri]
        call    t_str
        mov     rcx, [rbx+CD_IMG_M]
        lea     rdx, [m_e13]
        lea     r8, [tm_pl_img]
        call    t_str
        lea     rcx, [l_a]
        call    cards_free

        lea     rcx, [fx_playlist_items]
        lea     rdx, [m_items]
        lea     r8, [l_b]
        mov     r9d, 1
        call    parse_tracks
        mov     rcx, [l_b+LS_COUNT]
        mov     edx, 24
        lea     r8, [tm_it_count]
        call    t_int
        lea     rcx, [l_b]
        xor     edx, edx
        mov     r8d, TR_SIZE
        call    list_at
        mov     rbx, rax
        mov     rcx, [rbx+TR_TITLE]
        lea     rdx, [m_e3]
        lea     r8, [tm_it_title]
        call    t_wstr
        mov     rcx, [rbx+TR_ARTIST]
        lea     rdx, [m_e4]
        lea     r8, [tm_it_artists]
        call    t_wstr
        lea     rcx, [l_b]
        mov     edx, 1
        mov     r8d, TR_SIZE
        call    list_at
        mov     rbx, rax
        mov     rcx, [rbx+TR_TITLE]
        lea     rdx, [m_e5]
        lea     r8, [tm_it_title2]
        call    t_wstr
        mov     rcx, [rbx+TR_ARTIST]
        lea     rdx, [m_e6]
        lea     r8, [tm_it_artist2]
        call    t_wstr
        mov     rcx, [rbx+TR_ALBUM]
        lea     rdx, [m_e7]
        lea     r8, [tm_it_album]
        call    t_wstr
        mov     ecx, [rbx+TR_DUR]
        mov     edx, 157919
        lea     r8, [tm_it_dur]
        call    t_int
        mov     rcx, [rbx+TR_URI]
        lea     rdx, [m_e11]
        lea     r8, [tm_it_uri]
        call    t_str
        mov     rcx, [rbx+TR_IMG_S]
        lea     rdx, [m_e8]
        lea     r8, [tm_it_img]
        call    t_str
        mov     rcx, [rbx+TR_IMG_L]
        lea     rdx, [m_e8]
        lea     r8, [tm_it_imgl]
        call    t_str
        lea     rcx, [l_b]
        call    tracks_free

        lea     rcx, [fx_saved_tracks]
        lea     rdx, [m_items]
        lea     r8, [l_b]
        mov     r9d, 1
        call    parse_tracks
        mov     rcx, [l_b+LS_COUNT]
        mov     edx, 20
        lea     r8, [tm_sv_count]
        call    t_int
        lea     rcx, [l_b]
        call    tracks_free

        lea     rcx, [fx_saved_albums]
        lea     rdx, [m_items]
        lea     r8, [l_a]
        mov     r9d, KIND_ALBUM
        lea     rax, [m_wrap_album]
        mov     outarg(5), rax
        call    parse_cards
        mov     rcx, [l_a+LS_COUNT]
        mov     edx, 8
        lea     r8, [tm_al_count]
        call    t_int
        lea     rcx, [l_a]
        xor     edx, edx
        mov     r8d, CD_SIZE
        call    list_at
        mov     rbx, rax
        mov     rcx, [rbx+CD_SUB]
        lea     rdx, [m_e10]
        lea     r8, [tm_al_sub]
        call    t_wstr
        mov     ecx, [rbx+CD_COUNT]
        mov     edx, 8
        lea     r8, [tm_al_total]
        call    t_int
        lea     rcx, [l_a]
        call    cards_free

        lea     rcx, [fx_search]
        lea     rdx, [m_tracks_items]
        lea     r8, [l_b]
        xor     r9d, r9d
        call    parse_tracks
        mov     rcx, [l_b+LS_COUNT]
        mov     edx, 10
        lea     r8, [tm_s_tracks]
        call    t_int
        lea     rcx, [l_b]
        call    tracks_free
        lea     rcx, [fx_search]
        lea     rdx, [m_albums_items]
        lea     r8, [l_a]
        mov     r9d, KIND_ALBUM
        mov     qword outarg(5), 0
        call    parse_cards
        mov     rcx, [l_a+LS_COUNT]
        mov     edx, 4
        lea     r8, [tm_s_albums]
        call    t_int
        lea     rcx, [l_a]
        call    cards_free
        lea     rcx, [fx_search]
        lea     rdx, [m_artists_items]
        lea     r8, [l_a]
        mov     r9d, KIND_ARTIST
        mov     qword outarg(5), 0
        call    parse_cards
        mov     rcx, [l_a+LS_COUNT]
        mov     edx, 4
        lea     r8, [tm_s_artists]
        call    t_int
        lea     rcx, [l_a]
        xor     edx, edx
        mov     r8d, CD_SIZE
        call    list_at
        mov     rcx, [rax+CD_SUB]
        lea     rdx, [m_e9]
        lea     r8, [tm_s_artist_sub]
        call    t_wstr
        lea     rcx, [l_a]
        call    cards_free
        lea     rcx, [fx_search]
        lea     rdx, [m_playlists_items]
        lea     r8, [l_a]
        mov     r9d, KIND_PLAYLIST
        mov     qword outarg(5), 0
        call    parse_cards
        mov     rcx, [l_a+LS_COUNT]
        mov     edx, 3
        lea     r8, [tm_s_pl]
        call    t_int
        lea     rcx, [l_a]
        call    cards_free

        lea     rcx, [fx_queue]
        lea     rdx, [m_queue]
        lea     r8, [l_b]
        xor     r9d, r9d
        call    parse_tracks
        mov     rcx, [l_b+LS_COUNT]
        mov     edx, 12
        lea     r8, [tm_q_count]
        call    t_int
        lea     rcx, [l_b]
        call    tracks_free
        xor     ecx, ecx
        cmp     qword [l_b+LS_COUNT], 0
        sete    cl
        lea     rdx, [tm_free]
        call    t_check

        call    selftest_auth
        call    selftest_img
        lea     rcx, [st_sum]
        call    out_z
        mov     rax, [g_fail]
        EPROC

section .data
s_105:  db "1:05", 0
s_000:  db "0:00", 0
s_6101: db "61:01", 0
s_u64max: db "18446744073709551615", 0

; ---------------------------------------------------------------- sign-in / server helpers
section .data
ZSTR sa_abc, "abc"
ZSTR sa_abc_hex, "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
ZSTR sa_rfc_verifier, "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
ZSTR sa_rfc_challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
ZSTR sa_target, "/callback?code=a%2Fb+c%41&state=XYZ&empty=&last=1"
ZSTR sa_n_code, "code"
ZSTR sa_n_state, "state"
ZSTR sa_n_empty, "empty"
ZSTR sa_n_last, "last"
ZSTR sa_n_none, "nope"
ZSTR sa_v_code, "a/b cA"
ZSTR sa_v_state, "XYZ"
ZSTR sa_v_last, "1"
ZSTR sa_path_cb, "/callback"
ZSTR sa_path_q, "/callback?x=1"
ZSTR sa_path_z, "/callbackz"
ZSTR sa_path_sub, "/callback/x"
ZSTR sa_hdrs, `Host: 127.0.0.1:8989\r\ncontent-LENGTH:   12\r\nX-Other: yes\r\n\r\n`
ZSTR sa_h_host, "Host"
ZSTR sa_h_len, "Content-Length"
ZSTR sa_h_none, "Accept"
ZSTR sa_v_host, "127.0.0.1:8989"
ZSTR sa_v_len, "12"
ZSTR sa_hay, "invalid_grant: Invalid redirect URI"
ZSTR sa_needle, "redirect"
ZSTR sa_needle2, "refresh"
ZSTR sa_same1, "0123456789abcdefghijkl"
ZSTR sa_same2, "0123456789abcdefghijkl"
ZSTR sa_diff,  "0123456789abcdefghijkm"
ZSTR ta_sha, "auth: SHA-256 of 'abc' matches the FIPS vector"
ZSTR ta_pkce, "auth: PKCE S256 challenge matches the RFC 7636 example"
ZSTR ta_len, "auth: generated verifier is 64 chars, challenge 43, state 22"
ZSTR ta_alpha, "auth: verifier uses only URL-safe characters"
ZSTR ta_rand, "auth: two generated verifiers differ"
ZSTR ta_q1, "query: percent- and plus-decoding"
ZSTR ta_q2, "query: second parameter"
ZSTR ta_q3, "query: empty value has length 0"
ZSTR ta_q4, "query: absent parameter is -1"
ZSTR ta_q5, "query: last parameter without trailing &"
ZSTR ta_q6, "query: key must match fully (cod != code)"
ZSTR ta_p1, "path: exact match"
ZSTR ta_p2, "path: query string allowed"
ZSTR ta_p3, "path: longer name rejected"
ZSTR ta_p4, "path: sub-path rejected"
ZSTR ta_h1, "header: value found regardless of case, spaces trimmed"
ZSTR ta_h2, "header: Content-Length parsed"
ZSTR ta_h3, "header: absent header is -1"
ZSTR ta_c1, "ct_equal: identical strings"
ZSTR ta_c2, "ct_equal: one differing byte"
ZSTR ta_s1, "contains: needle present"
ZSTR ta_s2, "contains: needle absent"
ZSTR sa_cod, "cod"

section .bss
                align 8
sa_verif1:      resb 72
                align 8
sa_hex:         resb 80
                align 8
sa_out:         resb 80
                align 8
sa_chal:        resb 64

section .text
PROC selftest_auth, 6
        ; SHA-256("abc")
        lea     rcx, [sa_abc]
        mov     edx, 3
        lea     r8, [auth_hash]
        call    sha256
        lea     rsi, [auth_hash]
        lea     rdi, [sa_hex]
        xor     ebx, ebx
.hx:    movzx   eax, byte [rsi+rbx]
        shr     eax, 4
        call    hexdigit
        mov     [rdi+rbx*2], al
        movzx   eax, byte [rsi+rbx]
        and     eax, 15
        call    hexdigit
        mov     [rdi+rbx*2+1], al
        inc     ebx
        cmp     ebx, 32
        jb      .hx
        mov     byte [rdi+64], 0
        lea     rcx, [sa_hex]
        lea     rdx, [sa_abc_hex]
        lea     r8, [ta_sha]
        call    t_str

        ; PKCE example from RFC 7636 appendix B
        lea     rcx, [sa_rfc_verifier]
        mov     edx, 43
        lea     r8, [sa_chal]
        call    pkce_challenge_of
        lea     rcx, [sa_chal]
        lea     rdx, [sa_rfc_challenge]
        lea     r8, [ta_pkce]
        call    t_str

        ; generated values have the right shape and are random
        call    pkce_make
        lea     rcx, [auth_verifier]
        call    u8_len
        mov     loc(0), rax
        lea     rcx, [auth_challenge]
        call    u8_len
        mov     loc(1), rax
        lea     rcx, [auth_expect]
        call    u8_len
        xor     ecx, ecx
        cmp     qword loc(0), 64
        jne     .l1
        cmp     qword loc(1), 43
        jne     .l1
        cmp     rax, 22
        jne     .l1
        mov     ecx, 1
.l1:    lea     rdx, [ta_len]
        call    t_check
        xor     ebx, ebx                        ; every verifier character is in the URL-safe alphabet
        mov     r12d, 1
        lea     rsi, [auth_verifier]
.al:    movzx   eax, byte [rsi+rbx]
        lea     rcx, [a_alphabet]
        mov     edx, 64
.fa:    cmp     al, [rcx]
        je      .found
        inc     rcx
        dec     edx
        jnz     .fa
        xor     r12d, r12d
.found: inc     ebx
        cmp     ebx, 64
        jb      .al
        mov     ecx, r12d
        lea     rdx, [ta_alpha]
        call    t_check
        lea     rcx, [auth_verifier]
        lea     rdx, [sa_verif1]
        mov     r8d, 65
        call    mem_copy
        call    pkce_make
        lea     rcx, [auth_verifier]
        lea     rdx, [sa_verif1]
        call    u8_eq
        xor     ecx, ecx
        test    eax, eax
        sete    cl
        lea     rdx, [ta_rand]
        call    t_check

        ; query-string parsing
        lea     rcx, [sa_target]
        lea     rdx, [sa_n_code]
        lea     r8, [sa_out]
        mov     r9d, 64
        call    qget
        lea     rcx, [sa_out]
        lea     rdx, [sa_v_code]
        lea     r8, [ta_q1]
        call    t_str
        lea     rcx, [sa_target]
        lea     rdx, [sa_n_state]
        lea     r8, [sa_out]
        mov     r9d, 64
        call    qget
        lea     rcx, [sa_out]
        lea     rdx, [sa_v_state]
        lea     r8, [ta_q2]
        call    t_str
        lea     rcx, [sa_target]
        lea     rdx, [sa_n_empty]
        lea     r8, [sa_out]
        mov     r9d, 64
        call    qget
        movsxd  rcx, eax
        xor     edx, edx
        lea     r8, [ta_q3]
        call    t_int
        lea     rcx, [sa_target]
        lea     rdx, [sa_n_none]
        lea     r8, [sa_out]
        mov     r9d, 64
        call    qget
        movsxd  rcx, eax
        mov     rdx, -1
        lea     r8, [ta_q4]
        call    t_int
        lea     rcx, [sa_target]
        lea     rdx, [sa_n_last]
        lea     r8, [sa_out]
        mov     r9d, 64
        call    qget
        lea     rcx, [sa_out]
        lea     rdx, [sa_v_last]
        lea     r8, [ta_q5]
        call    t_str
        lea     rcx, [sa_target]
        lea     rdx, [sa_cod]
        lea     r8, [sa_out]
        mov     r9d, 64
        call    qget
        movsxd  rcx, eax
        mov     rdx, -1
        lea     r8, [ta_q6]
        call    t_int

        ; routing helpers
        lea     rcx, [sa_path_cb]
        lea     rdx, [sa_path_cb]
        call    path_is
        mov     ecx, eax
        lea     rdx, [ta_p1]
        call    t_check
        lea     rcx, [sa_path_q]
        lea     rdx, [sa_path_cb]
        call    path_is
        mov     ecx, eax
        lea     rdx, [ta_p2]
        call    t_check
        lea     rcx, [sa_path_z]
        lea     rdx, [sa_path_cb]
        call    path_is
        xor     ecx, ecx
        test    eax, eax
        sete    cl
        lea     rdx, [ta_p3]
        call    t_check
        lea     rcx, [sa_path_sub]
        lea     rdx, [sa_path_cb]
        call    path_is
        xor     ecx, ecx
        test    eax, eax
        sete    cl
        lea     rdx, [ta_p4]
        call    t_check

        ; header lookup
        lea     rcx, [sa_hdrs]
        lea     rdx, [sa_h_host]
        lea     r8, [sa_out]
        mov     r9d, 64
        call    req_header
        lea     rcx, [sa_out]
        lea     rdx, [sa_v_host]
        lea     r8, [ta_h1]
        call    t_str
        lea     rcx, [sa_hdrs]
        lea     rdx, [sa_h_len]
        lea     r8, [sa_out]
        mov     r9d, 64
        call    req_header
        lea     rcx, [sa_out]
        lea     rdx, [sa_v_len]
        lea     r8, [ta_h2]
        call    t_str
        lea     rcx, [sa_hdrs]
        lea     rdx, [sa_h_none]
        lea     r8, [sa_out]
        mov     r9d, 64
        call    req_header
        movsxd  rcx, eax
        mov     rdx, -1
        lea     r8, [ta_h3]
        call    t_int

        ; constant-time compare, substring search
        lea     rcx, [sa_same1]
        lea     rdx, [sa_same2]
        mov     r8d, 22
        call    ct_equal
        mov     ecx, eax
        lea     rdx, [ta_c1]
        call    t_check
        lea     rcx, [sa_same1]
        lea     rdx, [sa_diff]
        mov     r8d, 22
        call    ct_equal
        xor     ecx, ecx
        test    eax, eax
        sete    cl
        lea     rdx, [ta_c2]
        call    t_check
        lea     rcx, [sa_hay]
        lea     rdx, [sa_needle]
        call    u8_contains
        mov     ecx, eax
        lea     rdx, [ta_s1]
        call    t_check
        lea     rcx, [sa_hay]
        lea     rdx, [sa_needle2]
        call    u8_contains
        xor     ecx, ecx
        test    eax, eax
        sete    cl
        lea     rdx, [ta_s2]
        call    t_check
        EPROC

; ---------------------------------------------------------------- cover cache (procedural covers, tiny budget)
section .data
si_d1:  db "demo:1", 0
si_d2:  db "demo:2", 0
si_d3:  db "demo:3", 0
si_d4:  db "demo:4", 0
ti_ev1: db "img: the least recently drawn cover is evicted when over budget", 0
ti_keep2: db "img: newer covers stay", 0
ti_keep3: db "img: the newest cover stays", 0
ti_prot: db "img: a cover drawn in the current frame is never evicted", 0
ti_ev2: db "img: the next oldest goes instead", 0
ti_bytes: db "img: the byte count follows the cache (two 256x256 covers)", 0
section .text

PROC selftest_img, 4
        call    gfx_init
        mov     qword [img_budget], 600*1024    ; room for two 256 KB covers
        add     dword [img_frame], 10
        lea     rcx, [si_d1]
        call    img_get
        add     dword [img_frame], 3
        lea     rcx, [si_d2]
        call    img_get
        add     dword [img_frame], 3
        lea     rcx, [si_d3]
        call    img_get                         ; three covers exceed the budget: demo:1 (oldest, off screen) goes
        lea     rcx, [si_d1]
        call    img_find
        xor     ecx, ecx
        test    rax, rax
        sete    cl
        lea     rdx, [ti_ev1]
        call    t_check
        lea     rcx, [si_d2]
        call    img_find
        xor     ecx, ecx
        test    rax, rax
        setne   cl
        lea     rdx, [ti_keep2]
        call    t_check
        lea     rcx, [si_d3]
        call    img_find
        xor     ecx, ecx
        test    rax, rax
        setne   cl
        lea     rdx, [ti_keep3]
        call    t_check
        lea     rcx, [si_d4]                    ; same frame as demo:3, so demo:3 is protected and demo:2 pays
        call    img_get
        lea     rcx, [si_d3]
        call    img_find
        xor     ecx, ecx
        test    rax, rax
        setne   cl
        lea     rdx, [ti_prot]
        call    t_check
        lea     rcx, [si_d2]
        call    img_find
        xor     ecx, ecx
        test    rax, rax
        sete    cl
        lea     rdx, [ti_ev2]
        call    t_check
        mov     rcx, [img_bytes]
        mov     edx, 2*256*256*4
        lea     r8, [ti_bytes]
        call    t_int
        mov     qword [img_budget], IMG_BUDGET
        EPROC
