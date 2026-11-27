# Callbacks routinely ignore the argument they are handed.
CFLAGS = -Os -flto -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror -mmacosx-version-min=14.4
FRAMEWORKS = -framework AppKit -framework AVFoundation -framework CoreMedia -framework QuartzCore

build/livewall: $(wildcard src/*.m) src/livewall.h
	@mkdir -p build
	clang $(CFLAGS) $(wildcard src/*.m) $(FRAMEWORKS) -Wl,-dead_strip -o $@
	strip -x $@

clean:
	rm -rf build

.PHONY: clean
