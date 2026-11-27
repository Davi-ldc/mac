#!/bin/zsh
# Rebuilds Spotify (patched Spotifly) on top of the newest upstream Spotifly release and installs it.
#
#   update.sh              newest release tag (skips if already installed)
#   update.sh <tag>        a specific tag, even if already installed
#
# Starts only on AC power; the build takes about a minute, so it is not paused on battery as
# Zed Mini's is. The installed app is replaced only after the patched tree builds and a smoke
# launch stays up; on any failure it is left untouched and a notification names the cause.
setopt PIPE_FAIL
HERE=${0:A:h}
SRC=${HERE:h}/local/spotifly
APP="/Applications/Spotify.app"
LOCK=$HERE/.update.lock
LOG=$HERE/logs/update-$(date +%Y%m%d-%H%M).log
mkdir -p "$HERE/logs"
exec > >(tee -a "$LOG") 2>&1

notify() {
  osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Spotify"' -e 'end run' -- "$1"
}
fail() { echo "FAILED: $1"; notify "Update failed: $1. Kept the current version."; exit 1 }

TMP=
pid=
lock_held=0

stop_smoke() {
  local target=${1:-}
  [[ -n $target ]] || return 0
  kill "$target" 2>/dev/null || true
  for _ in {1..10}; do
    kill -0 "$target" 2>/dev/null || { wait "$target" 2>/dev/null || true; return 0 }
    sleep 1
  done
  if kill -0 "$target" 2>/dev/null; then
    kill -9 "$target" 2>/dev/null || true
    for _ in {1..5}; do
      kill -0 "$target" 2>/dev/null || break
      sleep 1
    done
    wait "$target" 2>/dev/null || true
  fi
}

cleanup() {
  trap - INT TERM HUP EXIT
  stop_smoke "$pid"
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
    echo "another spotifly update is already running (pid $holder), skipping"
    exit 0
  fi
  rm -rf "$LOCK"
  if mkdir "$LOCK" 2>/dev/null; then
    print -r -- $$ > "$LOCK/pid"
    lock_held=1
  else
    echo "another spotifly update acquired the lock, skipping"
    exit 0
  fi
fi

pmset -g batt | grep -q "AC Power" || { echo "on battery, skipping"; exit 0 }

cd "$SRC" || fail "missing checkout $SRC"
# Betas end in "-betaN"; only plain vX.Y.Z tags are releases.
TAG=${1:-$(git ls-remote --tags --refs origin 'v*' | awk -F/ '{print $3}' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)}
[[ -n $TAG ]] || fail "could not list upstream tags"
# PlistBuddy prints a missing file's message on stdout.
INSTALLED=$(/usr/libexec/PlistBuddy -c 'Print :SpotiflyPatchedUpstreamTag' "$APP/Contents/Info.plist" 2>/dev/null) || INSTALLED=
[[ -z $1 && $TAG == $INSTALLED ]] && { echo "already on $TAG"; exit 0 }
echo "updating ${INSTALLED:-nothing} -> $TAG"

applied=$("$HERE/apply.sh" "$SRC" "$TAG") || fail "${applied:-could not apply the patches on $TAG}"
echo "$applied"

TMP=${$(mktemp -d):A}
STAGE="$TMP/Spotify.app"
nice -n 10 "$HERE/build.sh" "$SRC" "$STAGE" "$TAG" || fail "build of $TAG"

# Smoke test: the new app must stay up for 15 s. As the host of upstream's unit tests
# (XCTestConfigurationFilePath set), it opens an empty window and leaves alone what a
# running Spotifly uses: no sign-in, no keychain, no Soloist, no Connect device. The home it
# is given keeps anything else it writes out of the user's.
XCTestConfigurationFilePath=/dev/null CFFIXED_USER_HOME="$TMP/home" "$STAGE/Contents/MacOS/Spotifly" &
pid=$!
sleep 15
kill -0 "$pid" 2>/dev/null || fail "smoke launch of $TAG exited early"
stop_smoke "$pid"
pid=

# A running Spotify keeps working from the old bundle; the new one is used from the
# next launch.
rm -rf "$APP.previous"
if [[ -d $APP ]]; then mv "$APP" "$APP.previous" || fail "moving the current app aside"; fi
mv "$STAGE" "$APP" || { [[ -d $APP.previous ]] && mv "$APP.previous" "$APP"; fail "installing $TAG" }
rm -rf "$APP.previous"
echo "installed $TAG"
# The keychain lets a self-signed app in by the hash of its code, which changes with each build.
notify "Updated to Spotifly $TAG. At its next launch, allow it into the keychain again."
