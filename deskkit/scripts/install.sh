#!/bin/zsh
# Builds deskkit, copies it to ~/.local/bin and writes its LaunchAgent without loading it:
# while Raycast, Hammerspoon and Rectangle run, both would fight over the same shortcuts.
# Use scripts/switch.sh on to move over.
set -e
ROOT=${0:A:h:h}
BIN=$HOME/.local/bin/deskkit
SUPPORT="$HOME/Library/Application Support/deskkit"
AGENT=$HOME/Library/LaunchAgents/local.deskkit.plist

make -C $ROOT
mkdir -p ${BIN:h} "$SUPPORT/icons" ${AGENT:h}
# It holds usage counts, quicklinks and the clipboard history.
chmod 700 "$SUPPORT"
# A new file rather than one rewritten in place: the kernel caches a binary's code
# signature by file, and a rewritten binary fails the check and is killed at launch.
rm -f $BIN
cp $ROOT/build/deskkit $BIN

# Raycast's command icons, copied for personal use only; they are not part of this
# repository. Without Raycast the launcher draws SF Symbols instead.
FRONTEND=/Applications/Raycast.app/Contents/Resources/macos-app_RaycastDesktopApp.bundle/Contents/Resources/frontend
copy_icon() {  # copy_icon <glob> <name>
  local found=($FRONTEND/$~1(N))
  (( $#found )) && cp $found[1] "$SUPPORT/icons/$2" && echo "icon $2 <- ${found[1]:t}"
}
copy_icon 'extension-quicklinks_large-*.png' quicklink.png
copy_icon 'command-quicklinks-create-*.png' create-quicklink.png
copy_icon 'extension-clipboard-history_large-*.png' clipboard.png
copy_icon 'command-web-google-*.png' google.png
# Raycast's monochrome logo for the search bar lives in its asset catalog.
osascript -l JavaScript - "$SUPPORT/icons/logo.png" <<'JS' 2>/dev/null && echo "icon logo.png <- Assets.car"
ObjC.import('AppKit');
function run(argv) {
  var logo = $.NSBundle.bundleWithPath('/Applications/Raycast.app').imageForResource('icons/logo-small');
  if (logo.isNil()) throw new Error('no logo');
  var canvas = $.NSImage.alloc.initWithSize($.NSMakeSize(44, 44));
  canvas.lockFocus;
  logo.drawInRectFromRectOperationFraction($.NSMakeRect(0, 0, 44, 44), $.NSZeroRect, 2, 1);
  canvas.unlockFocus;
  var bitmap = $.NSBitmapImageRep.imageRepWithData(canvas.TIFFRepresentation);
  bitmap.representationUsingTypeProperties(4, $()).writeToFileAtomically(argv[0], true);
}
JS

cat > $AGENT <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.deskkit</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/deskkit.log</string>
</dict>
</plist>
PLIST
echo "installed; not running yet. Switch with: $ROOT/scripts/switch.sh on"
