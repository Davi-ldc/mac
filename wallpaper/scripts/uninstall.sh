#!/bin/zsh
# Stops livewall and removes what install.sh put in place. The system wallpaper stays on
# the still frame; pick another one in System Settings > Wallpaper.
launchctl bootout gui/$UID/local.livewall 2>/dev/null
rm -f $HOME/Library/LaunchAgents/local.livewall.plist $HOME/.local/bin/livewall
rm -rf "$HOME/Library/Application Support/livewall"
echo "livewall removed"
