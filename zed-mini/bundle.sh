#!/bin/zsh
# Wraps a built zed binary into an app bundle next to (not replacing) the official Zed.
# The app is named after the bundle: "Zed Mini.app" is "Zed Mini" with the identifier
# local.zed-mini, so a differently named bundle is a separate app to macOS.
#   bundle.sh [--with-cli|--no-cli] <zed binary> <output .app> <upstream tag> [signing identity, "-" for ad hoc]
set -e
cli_mode=auto
case "${1:-}" in
  --with-cli) cli_mode=yes; shift ;;
  --no-cli)   cli_mode=no;  shift ;;
esac
BIN=${1:?binary}; OUT=${2:?output app}; TAG=${3:?tag}; IDENTITY=${4:-${ZED_MINI_SIGNING_IDENTITY:-Davi Local Code Signing}}
HERE=${0:A:h}
NAME=${OUT:t:r}
IDENTIFIER=local.${${NAME:l}// /-}
icon_tmp=
trap '[[ -n $icon_tmp ]] && rm -rf "$icon_tmp"' EXIT
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/zed"
# Symbols are only useful to a debugger; they more than double the binary.
strip -x "$OUT/Contents/MacOS/zed"
# Zed's command-line launcher, when it was built next to the binary: run from inside the
# bundle (or through a symlink to it), `cli <file>` opens the file in this app.
# Avoid silently packaging a stale `cli` from an older build unless `--with-cli` is passed.
CLI_BIN="${BIN:h}/cli"
if [[ $cli_mode == yes ]]; then
  [[ -x $CLI_BIN ]] || { echo "error: --with-cli requested but $CLI_BIN is missing" >&2; exit 1 }
  cp "$CLI_BIN" "$OUT/Contents/MacOS/cli"
  strip -x "$OUT/Contents/MacOS/cli"
elif [[ $cli_mode == auto && -x $CLI_BIN ]]; then
  if [[ ! $CLI_BIN -ot $BIN ]]; then
    cp "$CLI_BIN" "$OUT/Contents/MacOS/cli"
    strip -x "$OUT/Contents/MacOS/cli"
  else
    echo "note: skipping stale $CLI_BIN (older than $BIN; pass --with-cli to include)" >&2
  fi
fi
generate_icns() {
  local png=$1 out_icns=$2
  icon_tmp=$(mktemp -d)
  local iconset="$icon_tmp/Zed.iconset"
  mkdir -p "$iconset"
  sips -z 16 16     "$png" --out "$iconset/icon_16x16.png" >/dev/null &&
  sips -z 32 32     "$png" --out "$iconset/icon_16x16@2x.png" >/dev/null &&
  sips -z 32 32     "$png" --out "$iconset/icon_32x32.png" >/dev/null &&
  sips -z 64 64     "$png" --out "$iconset/icon_32x32@2x.png" >/dev/null &&
  sips -z 128 128   "$png" --out "$iconset/icon_128x128.png" >/dev/null &&
  sips -z 256 256   "$png" --out "$iconset/icon_128x128@2x.png" >/dev/null &&
  sips -z 256 256   "$png" --out "$iconset/icon_256x256.png" >/dev/null &&
  sips -z 512 512   "$png" --out "$iconset/icon_256x256@2x.png" >/dev/null &&
  sips -z 512 512   "$png" --out "$iconset/icon_512x512.png" >/dev/null &&
  sips -z 1024 1024 "$png" --out "$iconset/icon_512x512@2x.png" >/dev/null &&
  iconutil -c icns "$iconset" -o "$out_icns"
}
icon_png=
for candidate in \
  "${BIN:A:h:h:h}/crates/zed/resources/app-icon@2x.png" \
  "${HERE:h}/local/zed/crates/zed/resources/app-icon@2x.png"
do
  if [[ -f $candidate ]]; then
    icon_png=$candidate
    break
  fi
done
if [[ -n $icon_png ]] && generate_icns "$icon_png" "$OUT/Contents/Resources/Zed.icns"; then
  :
elif [[ -f /Applications/Zed.app/Contents/Resources/Zed.icns ]]; then
  cp /Applications/Zed.app/Contents/Resources/Zed.icns "$OUT/Contents/Resources/Zed.icns"
elif [[ -f $HERE/resources/Zed.icns ]]; then
  cp "$HERE/resources/Zed.icns" "$OUT/Contents/Resources/Zed.icns"
else
  echo "warning: no Zed icon source found; bundling without Zed.icns" >&2
fi
cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$IDENTIFIER</string>
  <key>CFBundleExecutable</key><string>zed</string>
  <key>CFBundleIconFile</key><string>Zed.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${TAG#v}</string>
  <key>CFBundleVersion</key><string>${TAG#v}</string>
  <key>ZedMiniUpstreamTag</key><string>$TAG</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Source Code and Text</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.text</string>
        <string>public.source-code</string>
        <string>public.data</string>
        <string>public.folder</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
EOF
# macOS ties privacy grants (Desktop, Documents, ...) to the signing identity, so an
# ad-hoc signature, which changes every build, would lose them at each weekly update.
# A fixed self-signed identity in the login keychain keeps them. Without it, or when the
# keychain wants the user to confirm the key's use and nobody answers within a minute
# (an unattended update must not hang on that dialog), the app is signed ad hoc so the
# update still produces a runnable app; the grants are then asked for again.
adhoc() {
  [[ -n $1 ]] && echo "$1, signing ad hoc: macOS will ask for the privacy grants again" >&2
  codesign --force --deep --sign - "$OUT"
}
if [[ $IDENTITY == - ]]; then
  adhoc
elif security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" "$OUT" &
  signer=$!
  for second in {1..60}; do kill -0 $signer 2>/dev/null || break; sleep 1; done
  if kill -0 $signer 2>/dev/null; then
    kill $signer; wait $signer 2>/dev/null || true
    adhoc "the keychain did not release '$IDENTITY' within 60 s (answer its dialog with Always Allow)"
  elif ! wait $signer; then
    adhoc "signing with '$IDENTITY' failed"
  fi
else
  adhoc "signing identity '$IDENTITY' not found"
fi
# macOS assesses each new binary (Gatekeeper, then an XProtect scan of all 325 MB) on its
# first run, holding the process for about 2 s. Running it once here makes that part of
# bundling instead of the next launch. The assessment stays with the bundle when it is
# moved, not when it is copied, so install it with mv.
"$OUT/Contents/MacOS/zed" --printenv >/dev/null 2>&1 || true
