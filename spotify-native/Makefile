# spotify-native build: pure Objective-C + C (ARC), zero Swift/SwiftUI.
# `make` builds $(BUILD)/Spotify Native.app (signed; RELEASE=1 strips tests & accepts ICON=<path>).
# `make test` runs DAG verification + headless M1+M2 --selftest (`T="Name ..."` filters by substring).
# `make memory` runs synthetic 5,000-track SQLite startup + open/closed RAM benchmark (--memory).
# `make bench` runs search/favorite/scroll/coalesce latency benchmarks (--bench).
# `make probe` builds tools/fairplay_probe for offline/live FairPlay verification.

BUILD ?= build
NAME = Spotify Native
APP = $(BUILD)/$(NAME).app
BIN = $(BUILD)/spotify-native
STAMP = $(BUILD)/bundle.stamp
PROBE_BIN = tools/fairplay_probe

SIGN_IDENTITY ?= Davi Local Code Signing
RESOLVED_SIGN_IDENTITY := $(shell if [ "$(SIGN_IDENTITY)" = "-" ]; then echo "-"; elif security find-identity -v -p codesigning 2>/dev/null | grep -qF '"$(SIGN_IDENTITY)"'; then echo "$(SIGN_IDENTITY)"; else echo "-"; fi)

CFLAGS = -Os -flto=thin -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror -mmacosx-version-min=14.4 \
         -Isrc -Itests/support -MMD -MP
BUILD_FLAGS := $(CFLAGS) $(if $(RELEASE),-DSP_RELEASE)
FRAMEWORKS = -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework QuartzCore \
             -framework ImageIO -framework UniformTypeIdentifiers -framework Security \
             -framework SystemConfiguration -framework Network -framework AVFoundation \
             -framework CoreMedia -framework MediaPlayer -framework AppKit \
             -lsqlite3 -lz

SRC_SOURCES := $(shell find src -name '*.m' | sort)
TEST_SOURCES := $(if $(RELEASE),,$(shell find tests -name '*.m' | sort))
APP_SOURCES := $(SRC_SOURCES) $(TEST_SOURCES)
APP_OBJECTS := $(APP_SOURCES:%.m=$(BUILD)/obj/%.o)

# tools/fairplay_probe links only M1 non-UI/non-main core sources.
PROBE_CORE_SOURCES := $(shell find src/theme src/model src/store src/auth src/net src/connect src/audio -name '*.m' | sort)
PROBE_SOURCES := $(PROBE_CORE_SOURCES) tools/fairplay_probe.m
PROBE_OBJECTS := $(PROBE_SOURCES:%.m=$(BUILD)/obj/%.o)

RESOURCES := resources/Info.plist $(ICON)

FLAGS_STAMP := $(BUILD)/obj/flags.stamp
$(shell mkdir -p "$(BUILD)/obj"; printf '%s\n' '$(BUILD_FLAGS)' > "$(FLAGS_STAMP).tmp"; cmp -s "$(FLAGS_STAMP).tmp" "$(FLAGS_STAMP)" 2>/dev/null || mv "$(FLAGS_STAMP).tmp" "$(FLAGS_STAMP)"; rm -f "$(FLAGS_STAMP).tmp")

all: $(STAMP)

$(BUILD)/obj/%.o: %.m $(FLAGS_STAMP)
	@mkdir -p $(@D)
	clang $(BUILD_FLAGS) -c $< -o $@

$(BIN): $(APP_OBJECTS)
	@mkdir -p $(@D)
	clang $(BUILD_FLAGS) $(APP_OBJECTS) $(FRAMEWORKS) -Wl,-dead_strip -o $@
	strip -x $@

$(STAMP): $(BIN) $(RESOURCES)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp resources/Info.plist "$(APP)/Contents/Info.plist"
	cp "$(BIN)" "$(APP)/Contents/MacOS/$(NAME)"
	$(if $(ICON),cp "$(ICON)" "$(APP)/Contents/Resources/AppIcon.icns" && plutil -replace CFBundleIconFile -string AppIcon "$(APP)/Contents/Info.plist")
	codesign --force --deep --sign "$(RESOLVED_SIGN_IDENTITY)" --identifier local.spotify-native "$(APP)"
	touch $@

$(PROBE_BIN): $(PROBE_OBJECTS)
	@mkdir -p $(@D)
	clang $(BUILD_FLAGS) $(PROBE_OBJECTS) $(FRAMEWORKS) -Wl,-dead_strip -o $@

probe: $(PROBE_BIN)

check-dag:
	python3 scripts/check-dag.py src

test: check-dag $(STAMP)
	"$(APP)/Contents/MacOS/$(NAME)" --selftest "$(CURDIR)" $(T)

memory: $(STAMP)
	"$(APP)/Contents/MacOS/$(NAME)" --memory

bench: $(STAMP)
	"$(APP)/Contents/MacOS/$(NAME)" --bench

clean:
	rm -rf $(BUILD) $(PROBE_BIN)

.PHONY: all probe check-dag test memory bench clean

-include $(APP_OBJECTS:.o=.d) $(PROBE_OBJECTS:.o=.d)
