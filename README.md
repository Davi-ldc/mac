# mac

Native rewrites of Slack and of Raycast + Rectangle + Hammerspoon, plus patched forks of Spotifly and of Zed styled as VS Code, to use less RAM (100 MB vs 1.1 GB on Slack, 100 MB vs 1 GB on Spotify, 300 MB vs 1.4 GB for VS Code). Also, /wallpaper lets you use a video as your wallpaper with 20% less power and 4× less memory than Phosphene, and /shell packs a lean Zsh + Ghostty setup with a native PTY wrapper (`ttyhints`) for output-aware and context-aware autocomplete.

## /deskkit (Raycast + Rectangle + Hammerspoon) has some opinionated settings:
- Screenshots go straight to the clipboard, ready for ⌘V
- When a window closes, focus goes back to the window you used before it
- Closing the last window of an app quits it
- Clipboard history on ⌘⇧V
- Ghostty: ⌘Q only quits when held, ⌘V pastes copied images
