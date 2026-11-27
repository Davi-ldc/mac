#!/bin/zsh
# switch.sh on   quits Raycast, Hammerspoon and Rectangle, takes them out of login items
#                and starts deskkit at every login.
# switch.sh off  stops deskkit and brings the three apps back.
AGENT=$HOME/Library/LaunchAgents/local.deskkit.plist
APPS=(Raycast Hammerspoon Rectangle)
case $1 in
  on)
    for app in $APPS; do
      osascript -e "tell application \"$app\" to quit" 2>/dev/null
      osascript -e "tell application \"System Events\" to delete (every login item whose name is \"$app\")" 2>/dev/null
    done
    sleep 2
    launchctl bootstrap gui/$UID $AGENT && echo "deskkit on" ;;
  off)
    launchctl bootout gui/$UID/local.deskkit 2>/dev/null
    for app in $APPS; do
      osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"/Applications/$app.app\", hidden:true}" >/dev/null 2>&1
      open -a $app
    done
    echo "deskkit off; Raycast, Hammerspoon and Rectangle back" ;;
  *) echo "usage: switch.sh on|off"; exit 2 ;;
esac
