#!/bin/zsh
# Fetches the prebuilt libwebrtc that calls link against (stasel/WebRTC, BSD-3) into
# ~/Desktop/mac/local/webrtc, outside the repository: the build links it when it is there and
# builds without calls when it is not. The archive must match the checksum the release publishes.
set -e
VERSION=158.0.0
ARCHIVE=WebRTC-M158.xcframework.zip
SHA256=dd26ba28fb9c8dbc82f4be3085e8d112a4e2a4e654e1786a9977a748c24c4912
DEST=${WEBRTC_DIR:-$HOME/Desktop/mac/local/webrtc}

WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
curl -fL --retry 2 -o $WORK/$ARCHIVE https://github.com/stasel/WebRTC/releases/download/$VERSION/$ARCHIVE
echo "$SHA256  $WORK/$ARCHIVE" | shasum -a 256 -c -
ditto -x -k $WORK/$ARCHIVE $WORK/x
SLICE=$(print -l $WORK/x/WebRTC.xcframework/macos-*(N/) | head -1)
[[ -n $SLICE ]] || { echo "no macOS slice in $ARCHIVE" >&2; exit 1; }

# Only the arm64 slice: this Mac's, and half the size of the universal binary.
rm -rf $WORK/WebRTC.framework
ditto $SLICE/WebRTC.framework $WORK/WebRTC.framework
BINARY=$(readlink -f $WORK/WebRTC.framework/WebRTC)
lipo $BINARY -thin arm64 -output $BINARY.arm64 2>/dev/null && mv $BINARY.arm64 $BINARY
mkdir -p $DEST
rm -rf $DEST/WebRTC.framework
mv $WORK/WebRTC.framework $DEST/
print $VERSION > $DEST/VERSION
echo "WebRTC $VERSION in $DEST/WebRTC.framework ($(du -sh $DEST/WebRTC.framework | cut -f1))"
