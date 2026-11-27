#!/bin/zsh
# Removes Spotify Native from /Applications/Spotify.app (NEVER touches com.spotify.client or /Applications/Spotify Original.app).
# Pass `--forget` to also delete Keychain session, local SQLite cache, and preferences.
set -e

APP="${APP:-/Applications/Spotify.app}"

if [[ -e "$APP" && $(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null) != local.spotify-native ]]; then
  echo "$APP is not Spotify Native; refusing to remove" >&2
  exit 1
fi

for pid in $(pgrep -f "^$APP/Contents/MacOS/" 2>/dev/null || true); do
  osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" >/dev/null 2>&1 || true
done
for i in {1..30}; do
  pgrep -f "^$APP/Contents/MacOS/" >/dev/null 2>&1 || break
  sleep 0.1
done

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" >/dev/null 2>&1 || true
rm -rf "$APP"

if [[ "$1" == "--forget" ]]; then
  while security delete-generic-password -s local.spotify-native.session >/dev/null 2>&1; do :; done
  rm -rf "$HOME/Library/Application Support/Spotify Native" \
         "$HOME/Library/Caches/local.spotify-native" \
         "$HOME/Library/Logs/spotify-native"
  for plist in "$HOME"/Library/Preferences/local.spotify-native*.plist(N); do
    defaults delete "${plist:t:r}" 2>/dev/null || rm -f "$plist"
  done
  echo "Spotify Native removed along with Keychain session, cache, and preferences."
else
  echo "Spotify Native removed; Keychain session and local SQLite cache kept (pass --forget to remove them)."
fi
