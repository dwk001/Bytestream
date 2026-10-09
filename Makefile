# ByteStream (x86-64 assembly, Windows).  The real build logic lives in tools/build.py so that
# Linux (cross-assembling) and Windows CI (no make) run exactly the same steps.
SRC = $(wildcard src/*.asm src/*.inc src/*.manifest) tools/implibs.py tools/build.py web/player.html \
      $(wildcard tests/fixtures/*.json)

all: build/bytestream.exe

build/bytestream.exe: $(SRC)
	python3 tools/build.py

test: build/bytestream.exe
	python3 tests/run_tests.py

clean:
	rm -rf build

.PHONY: all test clean
