# Shared by the bench scripts (sourced, not run).
BENCH=${0:A:h}
zmodload zsh/datetime

# The bench opens a clone of the user's project (git clone ~/Desktop/mac/wallpaper project/livewall):
# same content and git state, but outside the folders macOS guards with a permission prompt,
# and nothing typed into a bench window by accident can reach the real files.
BENCH_FILE=$BENCH/project/livewall/src/feed.m
BENCH_WORK_FILES=($BENCH/project/livewall/src/{window,player,control}.m)
# Zed's own override for the window bounds, in points: the default window on this display.
BENCH_WINDOW=1437,938
BENCH_POSITION=60,39

# Every launch starts from the same state: the user's current settings and keymap, and a
# database holding only feed.m with a selection (db-template, or $BENCH_TEMPLATE to compare
# against db-template-plain, the same without the selection), so nothing a previous run
# opened leaks into the next. The clone is a folder Zed has never seen, so the bench copy
# of the settings trusts it; otherwise Zed would not start clangd for it.
prepare_data() {
  mkdir -p $BENCH/data/config $BENCH/runs
  cp ~/.config/zed/keymap.json $BENCH/data/config/
  python3 - "$HOME/.config/zed/settings.json" "$BENCH/data/config/settings.json" <<'PY'
import json, re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
# Strip JSONC comments and trailing commas while preserving strings.
pattern = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/')
clean = pattern.sub(lambda m: m.group(0) if m.group(0).startswith('"') else "", text)
clean = re.sub(r',(\s*[}\]])', r'\1', clean)
data = json.loads(clean) if clean.strip() else {}
session = data.get("session")
if not isinstance(session, dict):
    session = {}
    data["session"] = session
session["trust_all_worktrees"] = True
with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  rm -rf $BENCH/data/db; cp -R $BENCH/${BENCH_TEMPLATE:-db-template} $BENCH/data/db
}

idle_seconds() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }' }
# A Zed window that takes focus swallows whatever the user is typing, so anything that
# activates Zed waits until keyboard and mouse have been quiet for <seconds>. Fails if
# that has not happened after <max wait> seconds (default: waits forever).
wait_for_idle() {
  local deadline=$((EPOCHSECONDS + ${2:-999999999}))
  while (( $(idle_seconds) < $1 )); do
    (( EPOCHSECONDS < deadline )) || return 1
    sleep 2
  done
}

front_bundle() { lsappinfo info -only bundleid $(lsappinfo front) | sed -n 's/.*bundleID="\([^"]*\)".*/\1/p' }
front_name() { lsappinfo info -only name $(lsappinfo front) | sed -n 's/^"\([^"]*\)".*/\1/p' }
front_pid() { lsappinfo info -only pid $(lsappinfo front) | sed -n 's/.*pid = \([0-9]*\).*/\1/p' }

# Zed activates itself several times while it starts. macOS lets that through only when
# the user is not busy in another app, so a background launch usually stays in the
# background; when it does not, focus goes back to <bundle id> once Zed has finished
# starting (handing it back at every activation makes the two apps flicker).
guard_focus() {
  local pid=$1 bundle=$2
  [[ -n $bundle ]] || return
  ( for wait in 5 4; do
      sleep $wait
      [[ $(front_pid) == $pid ]] && { open -b $bundle; echo "focus taken by Zed, handed back to $bundle" >&2 }
    done ) &
}

# Opens <app bundle> on the bench data dir and file, in the background, with the fixed
# window bounds and any NAME=value pairs in $BENCH_ENV; sets $pid.
launch_zed() {
  local app=$1 pair env_args=(--env ZED_WINDOW_SIZE=$BENCH_WINDOW --env ZED_WINDOW_POSITION=$BENCH_POSITION)
  for pair in ${=BENCH_ENV}; do env_args+=(--env $pair); done
  local prev=$(front_bundle)
  open -g -n -a "$app" $env_args --args --user-data-dir $BENCH/data $BENCH_FILE
  sleep 1; pid=$(pgrep -n -f "$app/Contents/MacOS/zed")
  [[ -n $pid ]] || { echo "launch of $app failed (is an app with the same single-instance port open?)" >&2; return 1 }
  guard_focus $pid "$prev"
}
