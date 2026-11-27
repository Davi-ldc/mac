#!/bin/zsh
# Runs a command and pauses it while the Mac is on battery, resuming on AC power, so an
# unattended build cannot drain the laptop. Exits with the command's status.
#   powerguard.sh <command> [args...]
#   powerguard.sh --check                exits 0 if a command would be allowed to run now
#
# POWERGUARD_MIN_BATTERY=<percent> lets a run someone is watching go on off battery
# down to that charge. Unattended runs (the weekly update) leave it unset and need AC.
#
# Without a terminal zsh cannot give the command its own process group to signal, so
# pausing walks the process tree. The walk starts below a /bin/sh that is never stopped
# itself: zsh reports a stopped child's 128+SIGSTOP as its exit status, and a zsh
# subshell resumes a stopped child on its own. The "; exit $?" keeps sh from exec'ing
# the command in its own place.
powered() {
  local state=$(pmset -g batt)
  [[ $state == *"AC Power"* ]] && return 0
  [[ -n $POWERGUARD_MIN_BATTERY ]] || return 1
  local pct=$(grep -o '[0-9]*%' <<< $state | head -1 | tr -d %)
  [[ -n $pct ]] && (( pct >= POWERGUARD_MIN_BATTERY ))
}
if [[ $1 == --check ]]; then powered; exit; fi

signal_descendants() {
  local child
  # Each process is signalled before its children are listed, so a stopped parent
  # cannot spawn a child the walk would miss.
  for child in $(pgrep -P $2 2>/dev/null); do
    kill -$1 $child 2>/dev/null
    signal_descendants $1 $child
  done
}

wrapper=
cleanup() {
  trap - INT TERM HUP EXIT
  if [[ -n $wrapper ]] && kill -0 $wrapper 2>/dev/null; then
    # Resume stopped descendants first so they can handle TERM instead of
    # staying orphaned in SIGSTOP after powerguard exits.
    signal_descendants CONT $wrapper
    signal_descendants TERM $wrapper
    kill -TERM $wrapper 2>/dev/null
    sleep 1
    signal_descendants KILL $wrapper
    kill -KILL $wrapper 2>/dev/null
  fi
}
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
trap 'cleanup' EXIT

/bin/sh -c '"$@"; exit $?' sh "$@" &
wrapper=$!
paused=0
while kill -0 $wrapper 2>/dev/null; do
  if powered; then
    if (( paused )); then
      signal_descendants CONT $wrapper; paused=0
      echo "powerguard: resumed ($(date +%H:%M))"
    fi
  elif (( ! paused )); then
    signal_descendants STOP $wrapper; paused=1
    echo "powerguard: paused on battery ($(date +%H:%M))"
  fi
  sleep 10
done
wait $wrapper
exit $?
