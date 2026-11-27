# Callbacks routinely ignore the argument they are handed.
CFLAGS = -Os -flto -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror -mmacosx-version-min=14.4
FRAMEWORKS = -framework AppKit -framework Carbon -framework ApplicationServices -framework Security \
             -framework CoreText -framework ImageIO -framework QuartzCore
# Inter, the picker's typeface, travels inside the binary (see theme.m).
FONT = resources/InterVariable.ttf
# Accessibility grants are tied to the signature. An ad-hoc signature changes with every
# build, so each rebuild would silently lose the grant; a fixed certificate keeps it. Falls back
# to ad-hoc signing (-) on machines without the certificate so a fresh clone builds anywhere.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -qF '"Davi Local Code Signing"' && echo 'Davi Local Code Signing' || echo '-')

build/deskkit: $(wildcard src/*.m) $(wildcard src/*.h) $(FONT)
	@mkdir -p build
	clang $(CFLAGS) $(wildcard src/*.m) $(FRAMEWORKS) -Wl,-dead_strip -Wl,-sectcreate,__TEXT,__inter,$(FONT) -o $@
	strip -x $@
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier local.deskkit $@

test: build/deskkit
	build/deskkit --selftest

clean:
	rm -rf build

.PHONY: test clean
