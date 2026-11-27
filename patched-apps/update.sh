#!/bin/zsh
# The weekly rebuild of the locally patched apps, run by the LaunchAgent local.patched-apps.update.
# One after the other, so two builds do not compete for the CPU, and each on its own: a failed
# update notifies, keeps its app as it was, and does not stop the other. Spotifly's takes about a
# minute and goes first, so Zed's, which can take hours paused on battery, never holds it up.

export PATH="$HOME/.cargo/bin:$PATH"

# At 04:00 the network can still be down (the first run failed on "Could not resolve host:
# github.com"), so both wait up to five minutes for GitHub before trying.
online=0
for _ in {1..30}; do
  if curl -fsS -o /dev/null -m 10 https://github.com 2>/dev/null; then
    online=1
    break
  fi
  sleep 10
done
if (( ! online )); then
  echo "github.com unreachable after 5 min, skipping weekly update"
  exit 0
fi

"${0:A:h:h}/spotifly/update.sh"
"${0:A:h:h}/zed-mini/update.sh"
