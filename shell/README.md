# shell

Lean Zsh + Ghostty setup with context-aware and output-aware autocomplete, without `oh-my-zsh` startup overhead.

## What is included

- **`src/ttyhints.c`** (~52 KB native binary installed to `~/.local/bin/ttyhints`): lightweight PTY wrapper for Ghostty that strips ANSI/alt-screen output between `preexec` (`SIGUSR1`) and `precmd` (`SIGUSR2`), extracts runnable command hints (e.g. `claude --resume <id>`, `git push --set-upstream ...`, quoted `"Run ..."` commands), and writes them atomically to `$TTYHINTS_FILE`.
- **`zsh/autosuggest.zsh`**: custom `zsh-autosuggestions` strategies in priority order:
  1. `claude_resume` — completes `claude`/`cskip`/`c`/`--resume` from the latest (or prefix-matched) session `.jsonl` for `$PWD` under `~/.claude/projects/` and `~/.local/share/cc-gateway/claude/projects/`. `Shift+Tab` opens an `fzf` picker with date + first prompt preview.
  2. `screen_hints` — suggests runnable commands captured from recent terminal output by `ttyhints`.
  3. `cd` — only suggests directories that actually exist from `$PWD`.
  4. `cwd_history` — records commands that exited `0` (or `130` on Ctrl+C) scoped by `$PWD` and git repo root in `~/.local/share/shell-history/cwd.tsv`.
  5. `project` — completes `package.json` scripts (`npm`/`bun`/`pnpm`/`yarn`), `Makefile` targets, and local git branches.
  6. `match_prev_cmd` & `history` — global `~/.zsh_history` fallback.
- **`zsh/zshrc`**: loads `powerlevel10k`, `zsh-autosuggestions`, `zsh-syntax-highlighting`, `zoxide`, `fzf`, and Ghostty shell integration directly (cached init + daily `compinit`).
- **`ghostty/config.ghostty`**: runs Ghostty tabs through `ttyhints --login /bin/zsh`.

## Install

```bash
./scripts/install.sh
```
