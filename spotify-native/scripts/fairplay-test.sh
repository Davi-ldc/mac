#!/usr/bin/env bash
# Phase 0 1-command live FairPlay test for spotify-native.
# Opens browser for Spotify OAuth PKCE (no Keychain writes), fetches Client-Token,
# tests FairPlay CKC exchange + 5s AVFoundation CBCS playback on Rick Astley
# (4cOdK2wGLETKBW3PvgPWqT by default), and prints a clear PASS/FAIL verdict.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -x "$ROOT/tools/fairplay_probe" ]]; then
  echo "[fairplay-test] Building tools/fairplay_probe..."
  make -j4 probe
fi

exec "$ROOT/tools/fairplay_probe" --live --oauth-login --track-id "4cOdK2wGLETKBW3PvgPWqT" "$@"
