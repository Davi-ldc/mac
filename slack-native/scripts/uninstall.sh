#!/bin/zsh
# Removes what install.sh put in place: the app and its LaunchAgent. The session (the Keychain's
# local.slack-native.session) and the workspace's cache stay, so installing again needs no sign-in;
# `uninstall.sh --forget` removes them and the rest of the app's data too (a dev build shares them).
APP="${APP:-$HOME/Applications/Slack.app}"
# Only this app is removed, never the official one.
if [[ -e $APP && $(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null) != local.slack-native ]]; then
  echo "$APP is not Slack Native; nothing removed" >&2
  exit 1
fi

# The installed copy quits as with Cmd+Q, saving the session's last cookies; it is found by its
# path because a dev build shares its bundle identifier.
for pid in $(pgrep -f "^$APP/Contents/MacOS/"); do
  osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" >/dev/null
done
for i in {1..50}; do pgrep -f "^$APP/Contents/MacOS/" >/dev/null || break; sleep 0.2; done
launchctl bootout gui/$UID/local.slack-native 2>/dev/null
rm -f $HOME/Library/LaunchAgents/local.slack-native.plist
rm -rf "$APP"
ORIG_LAUNCHER="$HOME/Applications/Slack Original.app"
if [[ -e "$ORIG_LAUNCHER" && $(defaults read "$ORIG_LAUNCHER/Contents/Info" CFBundleIdentifier 2>/dev/null) == local.slack-original-launcher ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$ORIG_LAUNCHER" 2>/dev/null || true
  rm -rf "$ORIG_LAUNCHER"
fi

if [[ $1 == --forget ]]; then
  while security delete-generic-password -s local.slack-native.session >/dev/null 2>&1; do :; done
  rm -rf "$HOME/Library/Application Support/Slack Native" $HOME/Library/HTTPStorages/local.slack-native \
    $HOME/Library/WebKit/local.slack-native $HOME/Library/Logs/slack-native
  for plist in $HOME/Library/Preferences/local.slack-native*.plist(N); do defaults delete ${plist:t:r}; done
  echo "Slack Native removed with its session and data"
else
  echo "Slack Native removed; the session and cache stay (uninstall.sh --forget removes them)"
fi
