all: sonora

sonora: sonora.o
	ld -o $@ $<

sonora.o: sonora.asm
	nasm -felf64 $< -o $@

test: sonora
	python3 tests/test_sonora.py

clean:
	rm -f sonora sonora.o

.PHONY: all test clean
