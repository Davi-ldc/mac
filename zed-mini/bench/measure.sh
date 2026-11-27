#!/bin/zsh
# Measures the memory footprint of a Zed Mini bundle over repeated launches of the same
# file, so two builds can be compared on the same footing. Prints one line per sample
# and a median/min/max summary; the raw samples go to runs/<label>.csv.
#   measure.sh <label> [app bundle] [runs]
#   BENCH_ENV="NAME=value ..." measure.sh ...     extra environment for the launched app
#   SETTLED=40 measure.sh ...                      take the settled sample sooner
#   BENCH_TEMPLATE=db-template-plain measure.sh ... start without the restored selection
#
# Each run samples four states:
#   early    25 s after a background launch, window never focused
#   settled  3 min after launch ($SETTLED seconds), still in the background
#   active   Zed in front for a few seconds with three more files open: a focused window
#            blinks its cursor, so every drawable of the window gets drawn and counted.
#            This is the state the user edits in.
#   after    30 s after focus went back to the previous app
# The launch is in the background and hands focus back at once if Zed takes it. Zed has
# to take focus for 3 s while "active" is sampled, so that step waits until the user has
# been idle for 10 s (and is skipped after 5 min of waiting); the previous app gets its
# focus back right after.
setopt PIPE_FAIL
HERE=${0:A:h}
source $HERE/lib.sh
LABEL=${1:?label}
APP=${2:-/Applications/Zed Mini.app}
RUNS=${3:-5}
BIN="$APP/Contents/MacOS/zed"
CSV=$HERE/runs/$LABEL.csv
EARLY=25; SETTLED=${SETTLED:-180}

[[ -x $BIN ]] || { echo "no binary at $BIN"; exit 1 }

# footprint prints "<dirty> <unit> <clean> <unit> <reclaimable> <unit> <regions> <category>";
# this folds the categories into fixed columns, in MB. "surfaces" is the IOSurface memory
# in units of one window-sized BGRA surface at 2x scale: how many drawables and other
# full-window buffers are resident, which is what moves the footprint between launches.
sample() {
  local tag=$1
  footprint $pid 2>/dev/null | awk -v tag=$tag -v run=$run -v label=$LABEL \
    -v win="$($HERE/bin/winsize $pid | head -1)" \
    -v expected="${BENCH_WINDOW/,/x} at $BENCH_POSITION " \
    -v focused=$([[ $(front_pid) == $pid ]] && echo 1 || echo 0) \
    -v clangd=$(pgrep -P $pid -x clangd >/dev/null && echo y || echo n) '
    function mb(v, u) { return u == "KB" ? v / 1024 : u == "GB" ? v * 1024 : u == "B" ? v / 1048576 : v }
    /Footprint:/ { total = mb($5, $6) }
    /phys_footprint_peak:/ { peak = mb($2, $3) }
    NR > 6 && $2 ~ /^(B|KB|MB|GB)$/ && $8 != "TOTAL" {
      cat = $8; for (i = 9; i <= NF; i++) cat = cat " " $i
      v = mb($1, $2)
      if (cat == "IOSurface") ios = v
      else if (cat ~ /^Malloc/) malloc += v
      else if (cat ~ /^IOAccelerator/ || cat ~ /graphics/) gpu += v
      else if (cat ~ /^__/) image += v
      else other += v
    }
    END {
      split(win, size, /[x ]/); surface = size[1] * size[2] * 16 / 1048576
      # Not comparable: something else on this Mac moved, resized or closed the window,
      # or Zed had focus when the state is defined without it (or the reverse).
      ok = index(win, expected) == 1 && focused == (tag == "active")
      printf "%s,%d,%s,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.1f,%s,%s,%d\n", label, run, tag, total, ios, malloc, gpu, image, other, peak, surface ? ios / surface : 0, win, clangd, ok
    }' | tee -a $CSV
}

# Only ever stops the instance this script launched: the same bundle may be the user's editor.
stop_zed() {
  [[ -n $pid ]] || return
  kill $pid 2>/dev/null
  while kill -0 $pid 2>/dev/null; do sleep 1; done
  pid=
}
# Hands focus back (to the Finder when the previous app cannot be named) only if the
# bench window still has it, so a user who moved on to another app is not pulled away.
restore_focus() { [[ $(front_pid) == $pid ]] && open -b ${1:-com.apple.finder} 2>/dev/null }

# A second instance of the same app exits at once (single-instance port): the bench needs
# this app closed, and Zed Mini itself closed when measuring a build that shares its port.
pgrep -f "$BIN" >/dev/null && { echo "$APP is already running; close it first"; exit 1 }

echo "label,run,tag,total_mb,iosurface_mb,malloc_mb,gpu_mb,image_mb,other_mb,peak_mb,surfaces,window,clangd,undisturbed" > $CSV
for run in $(seq 1 $RUNS); do
  prepare_data
  launch_zed "$APP" || exit 1
  sleep $((EARLY - 1)); sample early
  sleep $((SETTLED - EARLY)); sample settled
  if wait_for_idle 10 300; then
    prev=$(front_bundle)
    open -a "$APP" $BENCH_WORK_FILES
    sleep 3; sample active
    restore_focus $prev
    sleep 30; sample after
  else
    echo "run $run: user busy for 5 min, skipped the active and after samples"
  fi
  stop_zed
done

echo "--- $LABEL: median [min-max] MB over the undisturbed samples (mean iosurface / malloc / gpu / surfaces)"
for tag in early settled active after; do
  awk -F, -v tag=$tag '$3 == tag && $NF == 1 { print $4, $5, $6, $7, $11 }' $CSV | sort -n | awk -v tag=$tag '
    { v[NR] = $1; ios += $2; mal += $3; gpu += $4; surf += $5 }
    END { if (!NR) exit; m = NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
      printf "%-8s %4.0f [%.0f-%.0f] n=%d  iosurface %.0f  malloc %.0f  gpu %.0f  surfaces %.1f\n", tag, m, v[1], v[NR], NR, ios / NR, mal / NR, gpu / NR, surf / NR }'
done
awk -F, 'NR > 1 { if ($10 > peak) peak = $10; if ($NF == 0) bad++ } END { printf "peak since launch %d MB; %d disturbed samples left out\n", peak, bad }' $CSV
