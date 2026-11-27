#!/bin/zsh
# Samples a Zed Mini launch twice a second, to show what the launch peak is made of and
# how many window-sized GPU surfaces are alive at each moment. Prints one line per sample:
# seconds, footprint, IOSurface, malloc and other graphics MB, then the surface regions.
#   timeline.sh <app bundle> [seconds]
#   BENCH_ENV="NAME=value ..." timeline.sh ...     extra environment for the launched app
HERE=${0:A:h}
APP=${1:?app bundle}; SECS=${2:-30}
source $HERE/lib.sh
prepare_data
start=$EPOCHREALTIME
launch_zed "$APP" || exit 1
while (( EPOCHREALTIME - start < SECS )); do
  line=$(footprint $pid 2>/dev/null | awk '
    function mb(v, u) { return u == "KB" ? v / 1024 : u == "GB" ? v * 1024 : u == "B" ? v / 1048576 : v }
    /Footprint:/ { total = mb($5, $6) }
    $2 ~ /^(B|KB|MB|GB)$/ && $8 == "IOSurface" { ios = mb($1, $2) }
    $2 ~ /^(B|KB|MB|GB)$/ && $8 ~ /^Malloc/ { mal += mb($1, $2) }
    $2 ~ /^(B|KB|MB|GB)$/ && ($8 ~ /^IOAccelerator/ || $0 ~ /graphics/) { gpu += mb($1, $2) }
    END { printf "total %3.0f  iosurface %3.0f  malloc %3.0f  gpu %3.0f", total, ios, mal, gpu }')
  surfaces=$(vmmap $pid 2>/dev/null | awk '/^IOSurface/ { for (i = 1; i <= NF; i++) if ($i == "[") { if ($(i+1) ~ /M$/) n[$(i+1) "/" $(i+2)]++ } } END { for (k in n) printf "%dx%s ", n[k], k }')
  printf "%5.1fs  %s  surfaces(virtual/resident) %s front=%s win=%s\n" $((EPOCHREALTIME - start)) "$line" "$surfaces" "$(front_name)" "$($HERE/bin/winsize $pid | head -1)"
  sleep 0.5
done
kill $pid
