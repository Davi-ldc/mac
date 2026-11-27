#!/bin/zsh
# Battery campaign: measures where the watts go on this Mac, one lever at a time.
#
# Everything it touches is put back at the end, and also the moment the user touches the
# Mac or the battery gets low. Steps whose result already exists are skipped, so an
# interrupted campaign continues where it stopped.
#
#   campaign.sh <results-dir> [step ...]      steps: apps floor matrix modes brightness
#
# The window rectangles and display mode ids below belong to the Mac this was written on
# (1497x977 pt, Dock on the left); `bin/displayctl modes` lists yours.
setopt NO_BG_NICE
# Without this a trap waits for the foreground child, which can be minutes away.
setopt TRAPS_ASYNC
ROOT=${0:A:h}
LW=$ROOT/../build/livewall
MEDIA=$ROOT/media
OUT=${1:?results directory}
shift
STEPS=($@)
(( $#STEPS )) || STEPS=(apps floor matrix modes brightness)
mkdir -p $OUT
rm -f $OUT/.abort

MIN_BATTERY=30
HOME_MODE=$($ROOT/bin/displayctl current | sed -E 's/^id=([0-9]+).*/\1/')
HOME_BRIGHTNESS=$($ROOT/bin/displayctl brightness)
[[ -n $HOME_MODE && -n $HOME_BRIGHTNESS ]] || { echo "cannot read the display state"; exit 1 }
NATIVE_MODE=54
SIXTY_HZ_MODE=43

# The wallpaper already running on this Mac, paused for the campaign so that only the
# instance under test animates.
wallpaper=($(pgrep -x livewall))
app_pids() { pgrep -f "$1" | tr '\n' ' ' }
# Open apps, frozen during the campaign so they add no noise.
typeset -A APPS
APPS=(
  spotify  "/Applications/Spotify.app"
  safari   "Safari.app|com.apple.WebKit"
  whatsapp "WhatsApp.app"
)
all_app_pids() { for pattern in $APPS; do app_pids $pattern; done }

idle_seconds() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}' }
battery_pct() { pmset -g batt | grep -o '[0-9]*%' | tr -d '%' }
aborted() { [[ -e $OUT/.abort ]] }

# Returns failure when the display did not end up in the requested mode, so a scenario
# is never recorded under a mode it did not run in.
set_mode() {
  [[ $($ROOT/bin/displayctl current) == id=$1\ * ]] && return 0
  $ROOT/bin/displayctl set $1
  sleep 8
  [[ $($ROOT/bin/displayctl current) == id=$1\ * ]]
}

under_test=()
restore() {
  pkill -TERM -f "[p]ower_ab.py"; pkill -TERM -f "[p]ower_avg.py"; sleep 1
  kill $under_test 2>/dev/null
  pkill -x macmon
  set_mode $HOME_MODE
  $ROOT/bin/displayctl brightness $HOME_BRIGHTNESS
  kill -CONT $(all_app_pids) 2>/dev/null
  kill -USR2 $wallpaper 2>/dev/null
}
watchdog() {
  while sleep 5; do
    if (( $(idle_seconds) < 5 )); then
      echo "=== stopped: the user is back ($(date +%H:%M:%S))"
    elif (( $(battery_pct) < MIN_BATTERY )); then
      echo "=== stopped: battery below $MIN_BATTERY%"
    else
      continue
    fi
    touch $OUT/.abort
    kill -TERM $$
    exit
  done
}
watchdog &
dog=$!
trap 'touch $OUT/.abort; restore; kill $dog 2>/dev/null; exit 1' TERM INT HUP

done_already() { aborted || [[ -s $OUT/$1.json ]] }
avg() {  # avg <name> <seconds>
  done_already $1 || python3 -I $ROOT/power_avg.py --label $1 --seconds $2 --out $OUT/$1.json
}
ab() {  # ab <name> <cycles> <pause> <resume> <pid...>
  local name=$1 cycles=$2 pause=$3 resume=$4; shift 4
  done_already $name && return
  echo "=== $name ($(date +%H:%M:%S))"
  python3 -I $ROOT/power_ab.py --pid $@ --pause $pause --resume $resume --cycles $cycles --out $OUT/$name.json
}
video() {  # video <name> <clip> [ENV=value ...]: livewall playing vs paused
  local name=$1 clip=$2; shift 2
  done_already $name && return
  # Hands-off runs last longer than the idle time after which livewall freezes on its own.
  env LIVEWALL_KEEP_PLAYING=1 LIVEWALL_STATS=1 "$@" $LW $MEDIA/$clip > $OUT/$name.log 2>&1 &
  under_test=($!)
  sleep 4
  ab $name 8 USR1 USR2 $under_test
  kill $under_test 2>/dev/null; under_test=(); sleep 1
}
has_step() { (( ${STEPS[(Ie)$1]} )) }

echo "=== campaign in $OUT ($(date '+%Y-%m-%d %H:%M')) battery $(battery_pct)% mode $HOME_MODE brightness $HOME_BRIGHTNESS"

# The Mac as it was found, before anything is frozen.
avg as-found 45
kill -USR1 $wallpaper 2>/dev/null

if has_step apps; then
  # Each app alone against everything else frozen: its own cost, not its neighbours'.
  aborted || kill -STOP $(all_app_pids) 2>/dev/null
  for app in ${(k)APPS}; do
    pids=($(app_pids $APPS[$app]))
    (( $#pids )) && ab app-$app 6 STOP CONT $pids
    aborted || kill -STOP $pids 2>/dev/null
  done
fi
aborted || kill -STOP $(all_app_pids) 2>/dev/null

if has_step floor; then
  avg floor 60
fi

if has_step matrix; then
  video full120      clip120.mov
  video dot120       clip120.mov LIVEWALL_FRAME=1473,8,16,16 LIVEWALL_ABOVE=1
  video dock120      clip120.mov LIVEWALL_FRAME=0,0,60,938
  video full60       clip60.mov
  video full30       clip30.mov
  video edge120      clip120.mov LIVEWALL_FRAME=1437,0,60,938 LIVEWALL_ABOVE=1
  video full120-4k   clip120-4k10bit.mov
fi

if has_step modes; then
  # Window layout changes with the point size of a mode, so only the scenarios that float
  # above every window are comparable with the home mode.
  if ! aborted && set_mode $NATIVE_MODE; then
    avg native-floor 45
    video native-dot120  clip120.mov LIVEWALL_FRAME=1473,8,16,16 LIVEWALL_ABOVE=1
    video native-edge120 clip120.mov LIVEWALL_FRAME=1437,0,60,938 LIVEWALL_ABOVE=1
  fi
  if ! aborted && set_mode $SIXTY_HZ_MODE; then
    avg 60hz-floor 45
    video 60hz-full120   clip120.mov
  fi
  aborted || set_mode $HOME_MODE
fi

if has_step brightness; then
  for level in 0.10 0.25 0.42 0.60 0.80 1.00; do
    aborted && break
    $ROOT/bin/displayctl brightness $level
    avg brightness-$level 20
  done
fi

kill $dog 2>/dev/null
restore
echo "=== done ($(date +%H:%M:%S)) battery $(battery_pct)%"
