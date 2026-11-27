#!/bin/zsh
# Makes Slack Native the daily app: a release build (no tests; no trace unless SN_TRACE=1 is in
# its environment) at ~/Applications/Slack.app, opened at every login by a LaunchAgent.
# The agent is written but not loaded: a copy already running holds the session's lock, so
# switching to the installed one is left to the user (quit the running copy, then load the agent).
# Running it again updates the app in place; a running copy keeps the old build until reopened.
set -e
ROOT=${0:A:h:h}
BUILD=$ROOT/build/release
NAME="Slack Native"
# Installed in ~/Applications/Slack.app so MDM/updaters managing /Applications/Slack.app cannot
# overwrite it while keeping the app named Slack.
APP="${APP:-$HOME/Applications/Slack.app}"
STAGED="$BUILD/$NAME.app"
AGENT=$HOME/Library/LaunchAgents/local.slack-native.plist
IDENTITY="Davi Local Code Signing"
# Slack's icon, copied for personal use only: Slack's artwork is trademarked and never enters this
# repository. Without the official app the bundle keeps the generic icon.
ICON=""
for candidate in "/Applications/Slack.app/Contents/Resources/electron.icns" "/Applications/Slack Original.app/Contents/Resources/electron.icns"; do
  if [[ -f "$candidate" ]]; then
    mkdir -p "$BUILD" && cp "$candidate" "$BUILD/slack.icns" && ICON="$BUILD/slack.icns"
    break
  fi
done
mkdir -p "${APP:h}"
# Never replace the official app: only a previous install of this one may be moved aside.
if [[ -e "$APP" && $(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null) != local.slack-native ]]; then
  echo "$APP is not Slack Native (the official app?): refusing to replace it" >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
  IDENTITY=-
  echo "no \"Davi Local Code Signing\" certificate: signing ad hoc, so the Keychain asks again after every update"
fi

# The release leaves the tests out, so they run first on a build of their own; a failure installs
# nothing.
mkdir -p "$ROOT/build"
if ! make -C "$ROOT" -j$(sysctl -n hw.ncpu) "BUILD=$ROOT/build/test" "SIGN_IDENTITY=$IDENTITY" test >"$ROOT/build/test.log" 2>&1; then
  grep -E '^(FAIL|.*error:)' "$ROOT/build/test.log" >&2
  echo "make test failed (build/test.log): not installing" >&2
  exit 1
fi
tail -1 "$ROOT/build/test.log"

# Bundled anew every time, with today's icon.
rm -f "$BUILD/bundle.stamp"
make -C "$ROOT" -j$(sysctl -n hw.ncpu) "BUILD=$BUILD" RELEASE=1 "SIGN_IDENTITY=$IDENTITY" "ICON=$ICON"
codesign --verify --strict "$STAGED"
# One headless run (the whole window drawn off screen from the public fixture, no network) proves
# the build starts before it replaces the installed one, and lets the system's first look at new
# code happen here: mv below keeps the very files that ran.
"$STAGED/Contents/MacOS/$NAME" --memory "$ROOT/tests/fixtures" >/dev/null

# mv, not cp: a file rewritten in place keeps the kernel's cached signature of the old one and is
# killed at launch. Restore the previous bundle if moving the new one in place fails.
replaced=0
rm -rf "$BUILD/replaced.app"
if [[ -e "$APP" ]]; then
  mv "$APP" "$BUILD/replaced.app"
  replaced=1
fi
if ! mv "$STAGED" "$APP"; then
  if (( replaced )); then mv "$BUILD/replaced.app" "$APP" || true; fi
  exit 1
fi
rm -rf "$BUILD/replaced.app"
# The Dock and Finder show this build's name and icon at once.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
# Remove legacy /Applications/Slack Native.app if it is our own bundle so it never duplicates.
LEGACY="/Applications/Slack Native.app"
if [[ "$APP" != "$LEGACY" && -e "$LEGACY" && $(defaults read "$LEGACY/Contents/Info" CFBundleIdentifier 2>/dev/null) == local.slack-native ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$LEGACY" 2>/dev/null || true
  rm -rf "$LEGACY"
fi
# When shadowing /Applications/Slack.app from ~/Applications/Slack.app, keep a tiny launcher at
# ~/Applications/Slack Original.app so launchers that deduplicate by display name still expose the
# official app without modifying /Applications/Slack.app (which MDM may manage).
ORIG_LAUNCHER="$HOME/Applications/Slack Original.app"
if [[ "$APP" == "$HOME/Applications/Slack.app" && -d "/Applications/Slack.app" &&
      $(defaults read "/Applications/Slack.app/Contents/Info" CFBundleIdentifier 2>/dev/null) == com.tinyspeck.slackmacgap ]]; then
  if [[ ! -e "$ORIG_LAUNCHER" || $(defaults read "$ORIG_LAUNCHER/Contents/Info" CFBundleIdentifier 2>/dev/null) == local.slack-original-launcher ]]; then
    STAGED_ORIG="$BUILD/Slack Original.app"
    rm -rf "$STAGED_ORIG"
    mkdir -p "$STAGED_ORIG/Contents/MacOS" "$STAGED_ORIG/Contents/Resources"
    clang -Os -mmacosx-version-min=14.4 -x c - -o "$STAGED_ORIG/Contents/MacOS/Slack Original" <<'EOF'
#include <unistd.h>
int main(void) { execl("/usr/bin/open", "open", "/Applications/Slack.app", (char *)0); return 1; }
EOF
    [[ -n "$ICON" ]] && cp "$ICON" "$STAGED_ORIG/Contents/Resources/AppIcon.icns"
    cat > "$STAGED_ORIG/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.slack-original-launcher</string>
  <key>CFBundleName</key><string>Slack Original</string>
  <key>CFBundleDisplayName</key><string>Slack Original</string>
  <key>CFBundleExecutable</key><string>Slack Original</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
    codesign --force --sign "$IDENTITY" --identifier local.slack-original-launcher "$STAGED_ORIG"
    rm -rf "$ORIG_LAUNCHER"
    mv "$STAGED_ORIG" "$ORIG_LAUNCHER"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$ORIG_LAUNCHER"
  fi
fi

mkdir -p "${AGENT:h}" "$HOME/Library/Logs/slack-native"
# Restarted after a crash, not after Quit (which exits with 0).
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.slack-native</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/$NAME</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/slack-native/app.log</string>
</dict>
</plist>
PLIST

echo "installed at $APP; opens at login"
if pgrep -f "^$APP/Contents/MacOS/" >/dev/null; then
  echo "the installed copy is running the previous build: quit it and open it again"
elif ! launchctl print gui/$UID/local.slack-native >/dev/null 2>&1; then
  echo "to start it now: quit any other copy, then launchctl bootstrap gui/$UID $AGENT"
fi
