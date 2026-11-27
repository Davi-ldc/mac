#!/bin/zsh
# Measures the installed Spotify (patched Spotifly), to compare one build with the next.
#   measure.sh launch   how the running app's launch went, from the unified log, as times since the
#                       process was spawned: dyld, the keychain reads and the thread they held, the
#                       window and its first frame, the first requests, the home's artwork, Soloist
#   measure.sh play <uri>
#                       memory and CPU while it plays: 30 s with the window showing Favorites,
#                       30 s hidden, and the memory with the window closed. Takes the Spotify URI
#                       to play as an argument or via PLAY_URI (e.g. a playlist or track URI).
#
# `play` drives the app: it shows Favorites, plays the given URI on this Mac's Soloist at volume 0,
# so the playing row is on screen and nothing is heard, then pauses and gives Soloist its volume
# back. Playback elsewhere on the account would move here, so it refuses to start while Soloist
# plays and is meant for while nothing plays.
APP=/Applications/Spotify.app
SOLOIST_DATA="$HOME/Library/Application Support/Spotifly/Soloist/data"
die() { echo "$1" >&2; exit 1 }

pid=$(pgrep -f "^$APP/Contents/MacOS/Spotifly") || die "Spotify is not running"

launch() {
  local soloist=$(pgrep -P $pid -x soloist)
  # The kernel's start of the process, to the microsecond, as the time of day the log uses.
  local spawned=$(python3 -I -c 'import ctypes, struct, sys, time
info = ctypes.create_string_buffer(136)
ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidinfo(int(sys.argv[1]), 3, ctypes.c_uint64(0), info, 136)
sec, usec = struct.unpack_from("QQ", info.raw, 120)
print(time.strftime("%F %T", time.localtime(sec)) + ".%06d" % usec)' $pid)
  # Soloist logs neither when it listens nor when its stored login is back; its files say both.
  local listening=$(mtime "$SOLOIST_DATA/ws.port") loggedin=$(mtime "$SOLOIST_DATA"/cache/Users/*/primary.ldb/LOG(N[1]))
  # The keychain asks about a build signed anew by the hash of its code (build.sh).
  local cdhash=$(codesign -dvvv $APP 2>&1 | sed -n 's/^CDHash=//p')
  /usr/bin/log show --style compact --info --signpost --start "${spawned%.*}" \
      --end "$(date -j -v+60S -f '%F %T' "${spawned%.*}" '+%F %T')" \
      --predicate "processID == $pid${soloist:+ OR processID == $soloist} OR subsystem == \"com.apple.app_launch_measurement\" OR (process == \"securityd\" AND eventMessage CONTAINS \"XARA\")" |
    awk -v pid=$pid -v spawned="${spawned#* }" -v listening=$listening -v loggedin=$loggedin -v cdhash=$cdhash '
    function secs(time, p) { split(time, p, ":"); return p[1] * 3600 + p[2] * 60 + p[3] }
    function event(t, label) { if (t) { e++; at[e] = t - start; what[e] = label } }
    BEGIN { start = secs(spawned) }
    match($4, /^[^\[]+\[[0-9]+:[0-9a-f]+\]$/) {
      split($4, id, /[\[:\]]/); t = secs($2); msg = $0; sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", msg)
      # The system measures every launch to its first frame, which it presents.
      if (msg ~ /app_launch_measurement/) {
        if (id[2] == pid && msg ~ /end\] ApplicationFirstFramePresentation:/ && !frame) frame = t
        next
      }
      if (id[1] == "securityd") {
        if (index(msg, cdhash) && msg ~ /asking user/) asked[++prompts] = t
        if (index(msg, cdhash) && msg ~ /user approved XARA/ && answered < prompts) answer[++answered] = t
        next
      }
      if (id[2] != pid) { if (!soloist) soloist = t; next }
      n++; time[n] = t; tid[n] = id[3]; text[n] = msg
    }
    END {
      if (!n) { print "no log lines for pid " pid " in its first minute"; exit 1 }
      for (i = 1; i <= n; i++) if (text[i] ~ /_NSDisableAutomaticTermination/) { main = tid[i]; break }
      for (i = 1; i <= n && tid[i] != main; i++);
      event(time[i], "main thread runs the app (dyld and static initializers done)")
      for (i = 1; i <= n; i++) {
        if (text[i] ~ /\(Security\) SecItemCopyMatching$/) {
          # Until the thread logs something other than the read itself.
          for (j = i + 1; j <= n && (tid[j] != tid[i] || text[j] ~ /Security|securityd|Preferences|cfprefsd/); j++);
          event(time[i], tid[i] == main ? sprintf("keychain read on the main thread, which it held %.2f s", time[j] - time[i]) : "keychain read on a background thread")
        }
        if (text[i] ~ /_NSEnableAutomaticTerminationAndLog.*Restoring windows/ && !window) window = time[i]
        if (match(text[i], /Task <[^>]+>\.<[0-9]+> resuming/)) { task = substr(text[i], RSTART + 6, 36); m++; rid[m] = task; began[task] = time[i] }
        if (match(text[i], /Task <[^>]+>\.<[0-9]+> summary/)) { task = substr(text[i], RSTART + 6, 36); ended[task] = time[i] }
      }
      for (k = 1; k <= prompts; k++)
        event(asked[k], k <= answered ? sprintf("keychain prompt, answered after %.2f s", answer[k] - asked[k]) : "keychain prompt, not answered")
      event(window, "window made")
      event(frame, "first frame")
      event(soloist, "Soloist spawned")
      if (soloist && secs(listening) >= soloist) event(secs(listening), "Soloist listening")
      if (soloist && secs(loggedin) >= soloist) event(secs(loggedin), "Soloist logged in (ready)")
      if (m) event(began[rid[1]], "first request")
      # The home asks for all its cards artwork at once, which no other screen of requests does.
      for (k = 1; k + 9 <= m; k++) if (began[rid[k + 9]] - began[rid[k]] <= 0.05) break
      if (k + 9 <= m) {
        first = began[rid[k]]
        for (j = 1; j <= m; j++) if (began[rid[j]] >= first && began[rid[j]] - first <= 0.1) {
          count++; if (ended[rid[j]] > last) last = ended[rid[j]]
        }
        event(first, sprintf("home laid out: asks for %d images at once", count))
        event(last, "home artwork all in")
      }
      for (i = 2; i <= e; i++) for (j = i; j > 1 && at[j] < at[j - 1]; j--) {
        x = at[j]; at[j] = at[j - 1]; at[j - 1] = x; x = what[j]; what[j] = what[j - 1]; what[j - 1] = x
      }
      printf "launch of pid %d, spawned at %s\n", pid, spawned
      for (i = 1; i <= e; i++) printf "  +%5.2f s  %s\n", at[i], what[i]
      printf "  the first ten requests (start, duration):"
      for (k = 1; k <= m && k <= 10; k++) printf "%s+%.2f %s", (k % 5 == 1 ? "\n    " : ", "), began[rid[k]] - start, (rid[k] in ended ? sprintf("%.2f s", ended[rid[k]] - began[rid[k]]) : "open")
      print ""
    }'
}

mtime() {
  [[ -f $1 ]] || return
  local m=$(stat -f %Fm $1)
  echo "$(date -r ${m%.*} +%T).${${m#*.}:0:3}"
}

# A command over Soloist's loopback socket, the way the app talks to it, and the replies within a
# second. A zero mask key leaves the frame's text as it is.
soloist() {
  local port=$(<"$SOLOIST_DATA/ws.port") cmd="{\"type\":\"command\",$1}"
  { printf 'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'
    printf "\\x81\\x$(printf %x $((128 + ${#cmd})))\\x00\\x00\\x00\\x00%s" $cmd; sleep 1 } |
    nc 127.0.0.1 $port | LC_ALL=C tr -c '[:print:]' '\n'
}

# Keys go to the app's process, wherever the focus is.
ui() {
  osascript -l JavaScript -e 'ObjC.import("AppKit"); ObjC.import("CoreGraphics")
    function run(argv) {
      var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(argv[1]))
      var front = $.NSWorkspace.sharedWorkspace.frontmostApplication
      if (argv[0] == "front") return front.bundleURL.path.js
      if (argv[0] == "infront") return front.processIdentifier == parseInt(argv[1])
      if (argv[0] == "hide") { app.hide; return }
      if (argv[0] == "unhide") { app.unhide; return }
      [true, false].forEach(function (down) {
        var event = $.CGEventCreateKeyboardEvent($(), parseInt(argv[2]), down)
        $.CGEventSetFlags(event, $.kCGEventFlagMaskCommand)
        $.CGEventPostToPid(parseInt(argv[1]), event)
      })
    }' $1 $pid $2
}

memory() {
  footprint -p $pid | awk '
    function bytes(v, u) { return v * (u == "GB" ? 2^30 : u == "MB" ? 2^20 : u == "KB" ? 2^10 : 1) }
    /Footprint:/ { total = $(NF - 5) " " $(NF - 4) }
    NF >= 6 && $2 ~ /^(B|KB|MB|GB)$/ && $NF != "TOTAL" {
      category = $8; for (f = 9; f <= NF; f++) category = category " " $f
      group = category ~ /graphics|IOSurface|IOAccelerator|CoreAnimation|CG Image|CoreUI|Image IO|CoreGraphics/ ? "window and images" : category ~ /^Malloc/ ? "heap" : "code and other"
      sum[group] += bytes($1, $2)
    }
    END { printf "    memory %s: window and images %.0f MB, heap %.0f MB, code and other %.0f MB\n", total, sum["window and images"] / 2^20, sum["heap"] / 2^20, sum["code and other"] / 2^20 }'
}

# Says whether the app stayed in front, which the visible case needs: a window over it stops the
# waveform as hiding does.
cpu() {
  local before=$(ps -o time= -p $pid) front=$(ui infront)
  sleep 30
  local after=$(ps -o time= -p $pid)
  [[ $(ui infront) == true && $front == true ]] && front="in front throughout" || front="not in front throughout"
  [[ $(soloist '"command":"get_state"') == *'"status":"playing"'* ]] && front+=", playing" || front+=", NOT playing"
  awk -v a=$before -v b=$after -v front=$front 'function s(t, p) { split(t, p, ":"); return p[1] * 60 + p[2] }
    BEGIN { printf "    CPU over 30 s: %.1f%% (%s)\n", (s(b) - s(a)) / 30 * 100, front }'
}

play() {
  local uri=${1:-$PLAY_URI}
  [[ -n $uri ]] || die "usage: measure.sh play <spotify-uri> (or set PLAY_URI)"
  local state=$(soloist '"command":"get_state"')
  [[ $state == *'"status":"playing"'* ]] && die "Soloist is playing; measure while nothing plays"
  local volume=$(grep -o '"volume":[0-9]*' <<< $state | head -1 | cut -d: -f2)
  [[ -n $volume ]] || die "could not read Soloist's state"
  local front=$(ui front)

  open $APP; sleep 1; ui key 18; sleep 1    # ⌘1, Favorites
  soloist '"command":"set_volume","volume":0' >/dev/null
  soloist "\"command\":\"play\",\"uri\":\"$uri\"" >/dev/null
  sleep 5
  echo "  playing, the window showing Favorites"; memory; cpu
  ui hide; sleep 3
  echo "  playing, hidden"; cpu
  ui unhide; open $APP; sleep 1; ui key 13; sleep 5    # ⌘W
  echo "  window closed"; memory

  soloist '"command":"pause"' >/dev/null
  soloist "\"command\":\"set_volume\",\"volume\":$volume" >/dev/null
  open $APP; sleep 2; open $front
}

case $1 in
  launch) launch ;;
  play) play $2 ;;
  *) die "usage: measure.sh launch | play <spotify-uri>" ;;
esac
