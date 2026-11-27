# `make` builds $(BUILD)/Slack Native.app, `make test` runs the headless self-test (T="Name ..."
# runs the cases whose names contain one of the words, J=1 in one process; `make test-slow` the
# slow ones) and `make snapshot` renders the UI offscreen and compares it with design/ref. Nothing here shows
# a window, activates the app or touches the network.
#
# Every .m under src/ and tests/ is compiled, so a new file needs no change here. Parallel
# agents keep apart with BUILD=build/<name>. RELEASE=1, in a BUILD of its own, leaves tests/ out
# (no test registry, no --selftest or --snapshot) and ICON=<file.icns> bundles an app icon:
# scripts/install.sh builds so.

BUILD ?= build
# libwebrtc for calls, fetched by scripts/webrtc.sh outside the repository: without it the app
# builds without calls (src/call compiles its media part only with SN_WEBRTC).
WEBRTC ?= $(HOME)/Desktop/mac/local/webrtc
WEBRTC_FRAMEWORK := $(wildcard $(WEBRTC)/WebRTC.framework)
# Callbacks routinely ignore the argument they are handed.
CFLAGS = -Os -flto=thin -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror -mmacosx-version-min=14.4 \
         -Isrc -Itests/support -MMD -MP
FRAMEWORKS = -framework AppKit -framework QuartzCore -framework CoreText -framework ImageIO -framework Security
ifneq ($(WEBRTC_FRAMEWORK),)
# Headers at compile time only; media.m dlopens Contents/Frameworks/WebRTC.framework when a call
# starts so the 12 MB framework never slows launch or maps into idle sessions.
CALLFLAGS = -DSN_WEBRTC -F$(WEBRTC)
endif
# A fixed certificate, with the Keychain service it lets the bundle carry (below), keeps the
# Keychain's trust in the session item across rebuilds; an ad-hoc signature (SIGN_IDENTITY=-)
# changes with every build and makes the Keychain ask again.
SIGN_IDENTITY ?= Davi Local Code Signing

NAME = Slack Native
APP = $(BUILD)/$(NAME).app
BIN = $(BUILD)/slack-native
STAMP = $(BUILD)/bundle.stamp

SOURCES := $(shell find src $(if $(RELEASE),,tests) -name '*.m')
OBJECTS := $(SOURCES:%.m=$(BUILD)/obj/%.o)
# Slack's icon outlines (`make icons`) are private: a checkout without design/ draws SF Symbols.
ICONS := $(wildcard design/slack-icons.txt)
RESOURCES := resources/Info.plist $(wildcard resources/fonts/*) $(shell find src -name '*.strings') $(ICONS) $(ICON)

# The Keychain service (src/auth/keychainitems.h says why): built from its own two files with the
# base flags whatever the app's are, so its bytes, and the cdhash the Keychain knows it by, stay
# the same from one build of the app to the next. It is signed with the app's identifier, so its
# designated requirement is the app's: the one peer it answers. An ad hoc build goes without it
# (that requirement would be the service's own cdhash).
SERVICE = local.slack-native.keychain
SERVICE_SOURCES = services/keychain/main.m src/auth/keychainitems.m
SERVICE_OBJECTS := $(SERVICE_SOURCES:%.m=$(BUILD)/service/%.o)
SERVICE_BIN = $(BUILD)/service/keychain
ifneq ($(SIGN_IDENTITY),-)
RESOURCES += $(SERVICE_BIN) services/keychain/Info.plist
SERVICE_BUNDLE = $(APP)/Contents/XPCServices/$(SERVICE).xpc
endif

BUILD_FLAGS := $(CFLAGS) $(CALLFLAGS) $(if $(RELEASE),-DSN_RELEASE)
FLAGS_STAMP := $(BUILD)/obj/flags.stamp
$(shell mkdir -p "$(BUILD)/obj"; printf '%s\n' '$(BUILD_FLAGS)' > "$(FLAGS_STAMP).tmp"; cmp -s "$(FLAGS_STAMP).tmp" "$(FLAGS_STAMP)" 2>/dev/null || mv "$(FLAGS_STAMP).tmp" "$(FLAGS_STAMP)"; rm -f "$(FLAGS_STAMP).tmp")

all: $(STAMP)

$(BUILD)/obj/%.o: %.m $(FLAGS_STAMP)
	@mkdir -p $(@D)
	clang $(BUILD_FLAGS) -c $< -o $@

$(BUILD)/service/%.o: %.m
	@mkdir -p $(@D)
	clang $(CFLAGS) -c $< -o $@

$(SERVICE_BIN): $(SERVICE_OBJECTS)
	clang $(CFLAGS) $(SERVICE_OBJECTS) -framework Foundation -framework Security -Wl,-dead_strip -o $@
	strip -x $@

$(BIN): $(OBJECTS)
	clang $(CFLAGS) $(OBJECTS) $(FRAMEWORKS) -Wl,-dead_strip -o $@
	strip -x $@

# A module's strings live beside its code as <locale>.strings (src/ui/shell/pt-BR.strings) and
# land in Resources/strings/<locale>/<module>.strings, where SNLocalized merges them.
$(STAMP): $(BIN) $(RESOURCES)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources/fonts"
	cp resources/Info.plist "$(APP)/Contents/Info.plist"
	cp $(BIN) "$(APP)/Contents/MacOS/$(NAME)"
	cp resources/fonts/* "$(APP)/Contents/Resources/fonts/"
	$(if $(ICONS),cp $(ICONS) "$(APP)/Contents/Resources/")
	$(if $(WEBRTC_FRAMEWORK),mkdir -p "$(APP)/Contents/Frameworks" && ditto "$(WEBRTC_FRAMEWORK)" "$(APP)/Contents/Frameworks/WebRTC.framework" \
	  && codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)/Contents/Frameworks/WebRTC.framework")
	$(if $(ICON),cp "$(ICON)" "$(APP)/Contents/Resources/AppIcon.icns" && plutil -insert CFBundleIconFile -string AppIcon "$(APP)/Contents/Info.plist")
	for f in $$(find src -name '*.strings'); do \
	  module=$$(dirname $${f#src/} | tr / -); locale=$$(basename $$f .strings); \
	  mkdir -p "$(APP)/Contents/Resources/strings/$$locale"; \
	  cp $$f "$(APP)/Contents/Resources/strings/$$locale/$$module.strings"; \
	done
	$(if $(SERVICE_BUNDLE),mkdir -p "$(SERVICE_BUNDLE)/Contents/MacOS" \
	  && cp services/keychain/Info.plist "$(SERVICE_BUNDLE)/Contents/" \
	  && cp $(SERVICE_BIN) "$(SERVICE_BUNDLE)/Contents/MacOS/Slack Native Keychain" \
	  && codesign --force --sign "$(SIGN_IDENTITY)" --identifier local.slack-native "$(SERVICE_BUNDLE)")
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier local.slack-native "$(APP)"
	touch $@

JOBS = $(if $(J),--jobs $(J))

test: $(STAMP)
	"$(APP)/Contents/MacOS/$(NAME)" --selftest "$(CURDIR)" $(JOBS) $(T)

test-slow: $(STAMP)
	"$(APP)/Contents/MacOS/$(NAME)" --selftest "$(CURDIR)" --slow $(JOBS) $(T)

snapshot: $(STAMP)
	"$(APP)/Contents/MacOS/$(NAME)" --snapshot "$(CURDIR)" "$(BUILD)/snapshots" $(JOBS) $(T)

# A made-up workspace at scale (tests/support/scale.py says how big), generated, never committed.
SCALE_FIXTURE = $(abspath $(BUILD)/scale)
$(SCALE_FIXTURE)/auth.test.json: tests/support/scale.py
	rm -rf "$(SCALE_FIXTURE)"
	python3 tests/support/scale.py "$(SCALE_FIXTURE)"

# Memory of the whole window drawn from the private fixture (SCALE=1: the scale one), measured by
# the app itself.
memory: $(STAMP) $(if $(SCALE),$(SCALE_FIXTURE)/auth.test.json)
	"$(APP)/Contents/MacOS/$(NAME)" --memory "$(if $(SCALE),$(SCALE_FIXTURE),$(CURDIR)/design/fixtures)"

# Bursts of websocket events over the window on the scale fixture (tests/support/bench.m).
bench: $(STAMP) $(SCALE_FIXTURE)/auth.test.json
	"$(APP)/Contents/MacOS/$(NAME)" --bench "$(SCALE_FIXTURE)"

# Regenerates src/theme/tokens.{h,m} from design/tokens.json (design/ is not in the source tree).
theme:
	python3 src/theme/generate.py design/tokens.json src/theme/tokens

# Writes design/slack-icons.txt from the official client's static JS (fonts, CSS and JS saved
# from its Service Worker cache into design/_src/static).
icons:
	python3 src/render/icons.py design/_src/static design/slack-icons.txt

clean:
	rm -rf $(BUILD)

.PHONY: all test test-slow snapshot memory bench theme icons clean

-include $(OBJECTS:.o=.d) $(SERVICE_OBJECTS:.o=.d)
