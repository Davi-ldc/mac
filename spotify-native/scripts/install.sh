#!/bin/zsh
# Installs a verified release build of Spotify Native to /Applications/Spotify.app
# (NEVER touches /Applications/Spotify Original.app or com.spotify.client).
# Copies the Spotify icon at install time only; never stores trademarked .icns in the repo.
set -e

ROOT=${0:A:h:h}
BUILD="$ROOT/build/release"
NAME="Spotify Native"
APP="${APP:-/Applications/Spotify.app}"
LEGACY_APP="/Applications/Spotify Native.app"
STAGED="$BUILD/$NAME.app"
IDENTITY="Davi Local Code Signing"

# Copy official icon locally from Spotify Original.app (fallback Spotify.app) for personal use only.
ICON=""
for candidate in \
  "/Applications/Spotify Original.app/Contents/Resources/AppIcon.icns" \
  "/Applications/Spotify.app/Contents/Resources/AppIcon.icns"; do
  if [[ -f "$candidate" ]]; then
    mkdir -p "$BUILD"
    cp "$candidate" "$BUILD/spotify.icns"
    ICON="$BUILD/spotify.icns"
    break
  fi
done

# Safety guard: allow replacing local.spotify-native or rvdh.Spotifly; STRICTLY refuse com.spotify.client or anything else.
if [[ -e "$APP" ]]; then
  EXISTING_ID=$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
  if [[ "$EXISTING_ID" != "local.spotify-native" && "$EXISTING_ID" != "rvdh.Spotifly" ]]; then
    echo "$APP has bundle identifier '$EXISTING_ID' (refusing to overwrite official Spotify or unrelated app)" >&2
    exit 1
  fi
fi

if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then
  IDENTITY="-"
  echo "Certificate \"Davi Local Code Signing\" not found; falling back to ad-hoc signing (-)"
fi

# Run full DAG check + self-tests before building release.
mkdir -p "$ROOT/build"
if ! make -C "$ROOT" -j"$(sysctl -n hw.ncpu)" "BUILD=$ROOT/build/test" "SIGN_IDENTITY=$IDENTITY" test >"$ROOT/build/test.log" 2>&1; then
  grep -E '(FAIL|DAG VIOLATION|error:)' "$ROOT/build/test.log" >&2 || true
  echo "make test failed (see build/test.log): aborting install" >&2
  exit 1
fi
tail -n 2 "$ROOT/build/test.log"

# Build stripped release bundle.
rm -f "$BUILD/bundle.stamp"
make -C "$ROOT" -j"$(sysctl -n hw.ncpu)" "BUILD=$BUILD" RELEASE=1 "SIGN_IDENTITY=$IDENTITY" "ICON=$ICON"
codesign --verify --deep --strict "$STAGED"

# Atomic replace (mv, never cp in-place, so kernel code-signature cache stays valid).
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

# Clean up any leftover /Applications/Spotify Native.app (ONLY if it is local.spotify-native).
if [[ "$APP" != "$LEGACY_APP" && -e "$LEGACY_APP" ]]; then
  LEGACY_ID=$(defaults read "$LEGACY_APP/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
  if [[ "$LEGACY_ID" == "local.spotify-native" ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$LEGACY_APP" >/dev/null 2>&1 || true
    rm -rf "$LEGACY_APP"
  fi
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "Installed verified release at $APP"
