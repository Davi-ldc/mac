#!/bin/zsh
# Builds Spotifly from a checkout with the Command Line Tools alone, without Xcode, into an app
# bundle beside (not replacing) the official Spotifly.
#   build.sh <spotifly checkout> <output .app> <upstream tag>
#
# What Xcode would do is done by hand: swiftc with the project's Swift settings, a hand-made
# Info.plist, and the resources copied in. The two that need Xcode's actool, the asset catalog
# (the accent color) and the app icon, are taken from the official app instead.
set -e
SRC=${1:?checkout}; OUT=${2:?output app}; TAG=${3:?tag}
HERE=${0:A:h}
TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT
fail() { echo "$1" >&2; exit 1 }

# The flags below mirror these settings. A change upstream would build silently into a different
# app (default isolation, for one, changes what runs where), so it stops the build instead.
expected='ENABLE_APP_SANDBOX = NO;
ENABLE_HARDENED_RUNTIME = YES;
MACOSX_DEPLOYMENT_TARGET = 27.0;
SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
SWIFT_APPROACHABLE_CONCURRENCY = YES;
SWIFT_COMPILATION_MODE = wholemodule;
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
SWIFT_EMIT_LOC_STRINGS = NO;
SWIFT_EMIT_LOC_STRINGS = YES;
SWIFT_OPTIMIZATION_LEVEL = "-Onone";
SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES;
SWIFT_VERSION = 5.0;
SWIFT_VERSION = 6.0;'
PBXPROJ=$SRC/Spotifly.xcodeproj/project.pbxproj
actual=$(grep -oE '^[[:space:]]*"?(SWIFT_[A-Z_]+|OTHER_SWIFT_FLAGS|OTHER_LDFLAGS|MACOSX_DEPLOYMENT_TARGET|ENABLE_HARDENED_RUNTIME|ENABLE_APP_SANDBOX)[^=]*= [^;]*;' \
  $PBXPROJ | sed 's/^[[:space:]]*//' | sort -u)
[[ $actual == $expected ]] || fail "upstream changed its build settings; update build.sh to match:
$(diff <(echo $expected) <(echo $actual))"
! grep -qE 'XC(Remote|Local)SwiftPackageReference|XCSwiftPackageProductDependency|PBXShellScriptBuildPhase' $PBXPROJ \
  || fail "upstream added a Swift package or a script build phase, which this build does not run"

# From the macOS 27 SDK on, SwiftUI's @State is a macro whose plugin ships only with Xcode, so the
# app is compiled against the newest SDK of the Command Line Tools from before that. It runs on the
# system's SwiftUI all the same, which keeps the property wrapper the macro replaced.
SDK=
for sdk in $(/bin/ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.[0-9]*.sdk | sort -V -r); do
  ui=$sdk/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface
  if [[ -f $ui ]] && ! grep -q 'type: "StateMacro"' $ui; then SDK=$sdk; break; fi
done
[[ -n $SDK ]] || fail "no Command Line Tools SDK without SwiftUI's macros is left; building now needs Xcode"
echo "compiling $TAG against ${SDK:t}"

# #Preview is a macro of Xcode's too, and only for the canvas; previews are cut from copies.
sources=()
for f in $SRC/Spotifly/**/*.swift; do
  if grep -q '^#Preview' $f; then
    copy=$TMP/src/${f#$SRC/}
    mkdir -p ${copy:h}
    sed '/^#Preview/,/^}/d' $f > $copy
    sources+=$copy
  else
    sources+=$f
  fi
done

# The project's Release settings: Swift 6 with MainActor as the default isolation and Xcode's
# "approachable concurrency" features, of which Swift 6 lacks only these two.
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
swiftc -sdk $SDK -target arm64-apple-macos27.0 -module-name Spotifly \
  -swift-version 6 -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature MemberImportVisibility \
  -O -wmo -Xlinker -dead_strip \
  -o "$OUT/Contents/MacOS/Spotifly" $sources
strip -x "$OUT/Contents/MacOS/Spotifly"

# Resources, flattened as Xcode's synchronized group does. Anything else would need Xcode's tools
# (string catalogs, storyboards, new assets), so it stops the build rather than going missing.
RES="$OUT/Contents/Resources"
for f in ${(f)"$(cd $SRC/Spotifly && find . -type f ! -name '*.swift' ! -name Info.plist ! -name '*.entitlements' \
    ! -path './Spotifly.icon/*' ! -path './Assets.xcassets/*' | sed 's|^\./||')"}; do
  case $f in
    *.lproj/*.strings|*.lproj/*.stringsdict) mkdir -p $RES/${f:h:t}; cp $SRC/Spotifly/$f $RES/${f:h:t}/ ;;
    *.html) cp $SRC/Spotifly/$f $RES/ ;;
    *) fail "resource $f needs Xcode to build" ;;
  esac
done
[[ -z $(find $SRC/Spotifly/Assets.xcassets -mindepth 1 -maxdepth 1 ! -name Contents.json ! -name AccentColor.colorset) ]] \
  || fail "the asset catalog has new assets, which need Xcode's actool"

# The official app's compiled catalog holds the accent color, and the icon the user gave it in
# Finder is Spotify's, which is trademarked and so never part of these patches. Both are kept in
# CACHE for when the official app is gone; without them, the system accent and Spotifly's own icon.
OFFICIAL=/Applications/Spotifly.app
CACHE="$HOME/Library/Application Support/Spotifly Patched"
mkdir -p $CACHE
[[ -f $OFFICIAL/Contents/Resources/Assets.car ]] && cp $OFFICIAL/Contents/Resources/Assets.car $CACHE/
[[ -f $CACHE/Assets.car ]] && cp $CACHE/Assets.car $RES/
# Finder keeps a custom icon as the one resource, an icns, in the resource fork of the bundle's
# "Icon\r" file: a big-endian offset to the data, where a length precedes the resource. It is
# read from there rather than through NSWorkspace, whose icon can come back as the generic
# placeholder while Icon Services has not loaded it yet.
fork=$OFFICIAL/Icon$'\r'/..namedfork/rsrc
if [[ -s $fork ]]; then
  start=$((16#$(xxd -p -l 4 $fork)))
  tail -c +$((start + 5)) $fork | head -c $((16#$(xxd -p -s $start -l 4 $fork))) > $TMP/AppIcon.icns
  [[ $(head -c 4 $TMP/AppIcon.icns) == icns ]] && cp $TMP/AppIcon.icns $CACHE/AppIcon.icns
fi
if [[ -f $CACHE/AppIcon.icns ]]; then
  cp $CACHE/AppIcon.icns $RES/AppIcon.icns
elif [[ -f $OFFICIAL/Contents/Resources/Spotifly.icns ]]; then
  cp $OFFICIAL/Contents/Resources/Spotifly.icns $RES/AppIcon.icns
fi

# Upstream's Info.plist, with the values Xcode fills in. The bundle id stays upstream's: the
# keychain items, ~/Library/Application Support/Spotifly and Soloist's login are shared with the
# official app whatever the id, and its preferences hold the device ids that go with that login.
setting() { grep -oE "$1 = [^;]+;" $PBXPROJ | sort -u | sed -E 's/.* = "?([^";]*)"?;/\1/' }
version=$(setting MARKETING_VERSION); build=$(setting CURRENT_PROJECT_VERSION)
[[ $version != *$'\n'* && $build != *$'\n'* ]] || fail "the project has more than one version"
PLIST="$OUT/Contents/Info.plist"
sed -e "s/\$(MARKETING_VERSION)/$version/" -e "s/\$(CURRENT_PROJECT_VERSION)/$build/" $SRC/Spotifly/Info.plist > $PLIST
pb() { /usr/libexec/PlistBuddy -c "$1" $PLIST >/dev/null }
pb "Set :CFBundleName Spotify"
pb "Add :CFBundleDisplayName string Spotify"
pb "Add :SpotiflyPatchedUpstreamTag string $TAG"
pb "Add :CFBundleSupportedPlatforms array"; pb "Add :CFBundleSupportedPlatforms:0 string MacOSX"
[[ -f $RES/AppIcon.icns ]] && pb "Add :CFBundleIconFile string AppIcon"
[[ -f $RES/Assets.car ]] && pb "Add :NSAccentColorName string AccentColor"
plutil -lint -s $PLIST
printf 'APPL????' > "$OUT/Contents/PkgInfo"

# Hardened runtime, as upstream. Without upstream's keychain access group, which only a
# provisioning profile can grant; the shared items are in the login keychain, where the group
# does not apply. A fixed identity keeps across updates what macOS grants by signature, such
# as privacy permissions; without it, ad-hoc, so an update still runs. The keychain is the
# exception: it lets a self-signed app in by the hash of its code, so each new build is asked
# about again.
IDENTITY="${SPOTIFLY_SIGNING_IDENTITY:-Davi Local Code Signing}"
adhoc() {
  [[ -n $1 ]] && echo "$1, signing ad-hoc" >&2
  codesign --force --options runtime --sign - "$OUT"
}
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --options runtime --sign "$IDENTITY" "$OUT" &
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
codesign --verify --strict "$OUT"
