#!/bin/zsh
# Makes livewall the animated wallpaper: installs the binary, starts it at every login
# and replaces the system wallpaper with a still frame of the same video.
#
#   install.sh <video file>
set -e
ROOT=${0:A:h:h}
VIDEO=${1:?video file}
VIDEO=${VIDEO:A}
BIN=$HOME/.local/bin/livewall
SUPPORT="$HOME/Library/Application Support/livewall"
AGENT=$HOME/Library/LaunchAgents/local.livewall.plist
STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"

make -C $ROOT
mkdir -p ${BIN:h} $SUPPORT ${AGENT:h}
# Outside ~/Desktop on purpose: a login item reading from there needs a privacy prompt.
# A new file rather than one rewritten in place: the kernel caches a binary's code signature by
# inode, and rewriting a signed binary in place makes macOS kill it at launch.
rm -f $BIN.new
cp $ROOT/build/livewall $BIN.new
mv -f $BIN.new $BIN

# What the lock screen and Mission Control show, and what is on screen before livewall starts.
ffmpeg -hide_banner -loglevel error -y -i $VIDEO -frames:v 1 $SUPPORT/still.png

cat > $AGENT <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.livewall</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>$VIDEO</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/livewall.log</string>
</dict>
</plist>
EOF
launchctl bootout gui/$UID/local.livewall 2>/dev/null || true
# bootout returns before the old job is gone, and bootstrapping over it fails.
while launchctl print gui/$UID/local.livewall >/dev/null 2>&1; do sleep 0.2; done
launchctl bootstrap gui/$UID $AGENT

# Kept so the previous wallpaper choice can be looked up; uninstall does not restore it.
[[ -e $SUPPORT/wallpaper-before.plist ]] || cp $STORE $SUPPORT/wallpaper-before.plist
osascript -e "tell application \"System Events\" to set picture of every desktop to \"$SUPPORT/still.png\""
echo "livewall installed and running; log at ~/Library/Logs/livewall.log"
