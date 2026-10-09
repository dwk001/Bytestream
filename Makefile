# ByteStream (x86-64 assembly, Windows).  Cross-assembles on Linux with nasm + lld-link,
# or natively on Windows with the same tools.
NASM    ?= nasm
LLDLINK ?= lld-link
SRC      = $(wildcard src/*.asm src/*.inc) web/player.html
LIBS     = kernel32 user32 gdi32 gdiplus shell32 shlwapi winhttp ws2_32 bcrypt crypt32 ole32
LIBFILES = $(addprefix build/,$(addsuffix .lib,$(LIBS)))

all: build/bytestream.exe

build/.libs: tools/implibs.py
	python3 tools/implibs.py build > /dev/null
	touch $@

build/main.obj: $(SRC)
	@mkdir -p build
	$(NASM) -fwin64 -Isrc/ src/main.asm -o $@
	@# Lint: [symbol+register] addressing assembles to a 32-bit absolute address, which faults at a
	@# 64-bit image base.  Use `lea r, [sym]` first and index from the register.
	@if llvm-readobj --relocations $@ | grep -q 'IMAGE_REL_AMD64_ADDR32 '; then \
	  echo "error: absolute 32-bit relocation in $@ (use RIP-relative addressing)"; \
	  llvm-readobj --relocations $@ | grep -B2 'IMAGE_REL_AMD64_ADDR32 ' | head -20; exit 1; fi

build/bytestream.exe: build/main.obj build/.libs src/bytestream.manifest
	$(LLDLINK) /nologo /subsystem:windows /entry:start /manifest:embed /manifestinput:src/bytestream.manifest /out:$@ build/main.obj $(LIBFILES)

test: build/bytestream.exe
	python3 tests/run_tests.py

clean:
	rm -rf build

.PHONY: all test clean
