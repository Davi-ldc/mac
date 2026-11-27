#!/bin/zsh
# Builds ttyhints, installs it to ~/.local/bin, and symlinks ~/.zshrc + Ghostty config.
set -e
ROOT=${0:A:h:h}
BIN="$HOME/.local/bin/ttyhints"
GHOSTTY_CFG="$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"

make -C "$ROOT"
mkdir -p "${BIN:h}" "${GHOSTTY_CFG:h}"

# Copy as a fresh inode so macOS code-signature cache never rejects an updated binary.
rm -f "$BIN"
cp "$ROOT/build/ttyhints" "$BIN"
chmod 755 "$BIN"

link_with_backup() {
  local src=$1 dst=$2
  if [[ -L "$dst" ]]; then
    rm -f "$dst"
  elif [[ -e "$dst" ]]; then
    local bak="${dst}.pre-shell-bak"
    [[ -e "$bak" ]] || cp -p "$dst" "$bak"
    rm -f "$dst"
  fi
  ln -s "$src" "$dst"
  echo "linked $dst -> $src"
}

link_with_backup "$ROOT/zsh/zshrc" "$HOME/.zshrc"

# Render Ghostty config with the current user's $HOME (Ghostty's `direct:` does not expand ~).
if [[ -L "$GHOSTTY_CFG" ]]; then
  rm -f "$GHOSTTY_CFG"
elif [[ -e "$GHOSTTY_CFG" ]]; then
  bak="${GHOSTTY_CFG}.pre-shell-bak"
  [[ -e "$bak" ]] || cp -p "$GHOSTTY_CFG" "$bak"
fi
sed "s|__HOME__|$HOME|g" "$ROOT/ghostty/config.ghostty" > "$GHOSTTY_CFG"
echo "installed $GHOSTTY_CFG"
echo "installed $BIN"
