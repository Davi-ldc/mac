CFLAGS = -std=c11 -Os -flto -Wall -Wextra -Wno-unused-parameter -Werror -mmacosx-version-min=14.4

build/ttyhints: src/ttyhints.c
	@mkdir -p build
	clang $(CFLAGS) src/ttyhints.c -Wl,-dead_strip -o $@
	strip -x $@

clean:
	rm -rf build

.PHONY: clean
