#!/bin/zsh
# Rebuilds Zed Mini on top of the newest upstream stable Zed and installs it.
#
#   update.sh              newest stable tag (skips if already installed)
#   update.sh <tag>        a specific tag, even if already installed
#
# Starts only on AC power and pauses the build while on battery. The installed app is
# replaced only after the patched tree builds and a smoke launch stays up; on any failure
# it is left untouched and a notification names the cause.
setopt PIPE_FAIL
export PATH="$HOME/.cargo/bin:$PATH"
HERE=${0:A:h}
SRC=${HERE:h}/local/zed
APP="/Applications/Zed Mini.app"
LOCK=$HERE/.update.lock
LOG=$HERE/logs/update-$(date +%Y%m%d-%H%M).log
mkdir -p "$HERE/logs"
exec > >(tee -a "$LOG") 2>&1

notify() {
  osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Zed Mini"' -e 'end run' -- "$1"
}
fail() { echo "FAILED: $1"; notify "Update failed: $1. Kept the current version."; exit 1 }

TMP=
STAGE=
smoke_pid=
lock_held=0

stop_smoke() {
  local target=${1:-}
  if [[ -z $target && -n $STAGE ]]; then
    target=$(pgrep -n -f "$STAGE/Contents/MacOS/zed" 2>/dev/null || true)
  fi
  [[ -n $target ]] || return 0
  kill "$target" 2>/dev/null || true
  for _ in {1..10}; do
    kill -0 "$target" 2>/dev/null || return 0
    sleep 1
  done
  if kill -0 "$target" 2>/dev/null; then
    kill -9 "$target" 2>/dev/null || true
    for _ in {1..5}; do
      kill -0 "$target" 2>/dev/null || return 0
      sleep 1
    done
  fi
}

cleanup() {
  trap - INT TERM HUP EXIT
  stop_smoke "$smoke_pid"
  [[ -n $TMP ]] && rm -rf "$TMP"
  if (( lock_held )) && [[ $(<"$LOCK/pid" 2>/dev/null) == $$ ]]; then
    rm -rf "$LOCK"
  fi
}
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
trap 'cleanup' EXIT

if mkdir "$LOCK" 2>/dev/null; then
  print -r -- $$ > "$LOCK/pid"
  lock_held=1
else
  holder=$(<"$LOCK/pid" 2>/dev/null || true)
  if [[ -n $holder ]] && kill -0 "$holder" 2>/dev/null; then
    echo "another zed-mini update is already running (pid $holder), skipping"
    exit 0
  fi
  rm -rf "$LOCK"
  if mkdir "$LOCK" 2>/dev/null; then
    print -r -- $$ > "$LOCK/pid"
    lock_held=1
  else
    echo "another zed-mini update acquired the lock, skipping"
    exit 0
  fi
fi

# A weekly rebuild is too heavy to start off battery; launchd tries again next week.
"$HERE/powerguard.sh" --check || { echo "on battery, skipping"; exit 0 }

cd "$SRC" || fail "missing checkout $SRC"
# Pre-releases end in "-pre"; only plain vX.Y.Z tags are stable.
TAG=${1:-$(git ls-remote --tags --refs origin 'v*' | awk -F/ '{print $3}' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)}
[[ -n $TAG ]] || fail "could not list upstream tags"
# PlistBuddy answers a missing file on stdout, so only an installed app is asked.
[[ -f $APP/Contents/Info.plist ]] \
  && INSTALLED=$(/usr/libexec/PlistBuddy -c 'Print :ZedMiniUpstreamTag' "$APP/Contents/Info.plist" 2>/dev/null)
[[ -z $1 && $TAG == $INSTALLED ]] && { echo "already on $TAG"; exit 0 }
echo "updating ${INSTALLED:-nothing} -> $TAG"

applied=$("$HERE/apply.sh" "$SRC" "$TAG") || fail "${applied:-could not apply the patches on $TAG}"
echo "$applied"

# Upstream Cargo.toml already sets codegen-units = 16 for the final `zed` crate while
# keeping dependency crates at 1 for smaller, faster codegen. A compile-time
# ZED_UPDATE_EXPLANATION switches off Zed's own updater: being a stable-channel build,
# "Check for Updates" (or auto_update in the shared settings) would otherwise replace
# this app with the official Zed.
CARGO_PROFILE_RELEASE_DEBUG=false \
  ZED_UPDATE_EXPLANATION="Zed Mini is updated by $HERE/update.sh" \
  "$HERE/powerguard.sh" nice -n 10 cargo build --release -p zed --features gpui_platform/runtime_shaders \
  || fail "build of $TAG"
# The command-line launcher bundle.sh puts next to the app's binary (`zed <file>`).
CARGO_PROFILE_RELEASE_DEBUG=false \
  "$HERE/powerguard.sh" nice -n 10 cargo build --release -p cli || fail "build of the $TAG cli"

TMP=${$(mktemp -d):A}
STAGE="$TMP/Zed Mini.app"
"$HERE/bundle.sh" --with-cli "$SRC/target/release/zed" "$STAGE" "$TAG" || fail "bundling $TAG"

# Smoke test: the new app must stay up for 20 s on a throwaway data dir, so a broken
# build never replaces a working one. A Zed Mini the user has open holds Zed Mini's
# single-instance port, so without ZED_STATELESS (which skips that check) the launch
# would exit at once and fail the update. It is opened in the background, so an update
# does not take the keyboard from whoever is at the Mac.
open -g -n -a "$STAGE" --env ZED_STATELESS=1 --args --user-data-dir "$TMP/data"
sleep 20
smoke_pid=$(pgrep -n -f "$STAGE/Contents/MacOS/zed" 2>/dev/null || true)
[[ -n $smoke_pid ]] || fail "smoke launch of $TAG exited early"
stop_smoke "$smoke_pid"
smoke_pid=

# A running Zed Mini keeps working from the old bundle; the new one is used from the
# next launch.
rm -rf "$APP.previous"
if [[ -d $APP ]]; then mv "$APP" "$APP.previous" || fail "moving the current app aside"; fi
mv "$STAGE" "$APP" || { [[ -d $APP.previous ]] && mv "$APP.previous" "$APP"; fail "installing $TAG" }
rm -rf "$APP.previous"
echo "installed $TAG"
notify "Updated to Zed $TAG"
