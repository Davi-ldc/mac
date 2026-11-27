# Smart zsh-autosuggestions strategies + Shift+Tab Claude session picker.
# Priority order:
#   1. claude_resume  — latest (or prefix-matched) Claude Code session UUID for $PWD
#   2. screen_hints   — runnable commands extracted from recent terminal output (via ttyhints)
#   3. cd             — only directories that actually exist from $PWD
#   4. cwd_history    — successful commands previously run in $PWD (or this git repo)
#   5. project        — package.json scripts, Makefile targets, local git branches
#   6. match_prev_cmd — command bigrams from ~/.zsh_history
#   7. history        — global ~/.zsh_history

zmodload -F zsh/stat b:zstat 2>/dev/null
autoload -Uz add-zsh-hook

typeset -g _SHELL_HIST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/shell-history"
typeset -g _SHELL_CWD_HIST_FILE="$_SHELL_HIST_DIR/cwd.tsv"
typeset -ga _cwd_hist_local=()
typeset -ga _ttyhints_cache=()
typeset -g _ttyhints_mtime=0
typeset -g _shell_pending_cmd=""
typeset -g _shell_last_cmd=""

typeset -g _proj_pkg_dir=""
typeset -g _proj_pkg_mtime=0
typeset -ga _proj_pkg_scripts=()

typeset -g _proj_make_dir=""
typeset -g _proj_make_mtime=0
typeset -ga _proj_make_targets=()

typeset -g _proj_git_dir=""
typeset -ga _proj_git_branches=()
typeset -g _proj_git_dirty=1

# --- Helpers ---

_claude_project_dirs() {
  emulate -L zsh
  local cmd=$1
  local slug=${PWD//[^a-zA-Z0-9-]/-}
  local native="$HOME/.claude/projects/$slug"
  local gateway="${XDG_DATA_HOME:-$HOME/.local/share}/cc-gateway/claude/projects/$slug"
  reply=()
  if [[ "$cmd" == "c" ]]; then
    [[ -d "$gateway" ]] && reply+=("$gateway")
    [[ -d "$native" ]] && reply+=("$native")
  else
    [[ -d "$native" ]] && reply+=("$native")
    [[ -d "$gateway" ]] && reply+=("$gateway")
  fi
}

_shell_reload_cwd_history() {
  emulate -L zsh
  _cwd_hist_local=()
  [[ -r "$_SHELL_CWD_HIST_FILE" ]] || return

  local pwd_now=$PWD
  local git_root=""
  local d=$PWD
  while [[ "$d" != "/" && -n "$d" ]]; do
    if [[ -e "$d/.git" ]]; then
      git_root=$d
      break
    fi
    d=${d:h}
  done

  local -a exact_rev=() repo_rev=()
  local line dir cmd
  while IFS=$'\t' read -r dir cmd; do
    [[ -n "$cmd" ]] || continue
    if [[ "$dir" == "$pwd_now" ]]; then
      exact_rev+=("$cmd")
    elif [[ -n "$git_root" && ( "$dir" == "$git_root" || "$dir" == "$git_root/"* ) ]]; then
      repo_rev+=("$cmd")
    fi
  done < "$_SHELL_CWD_HIST_FILE"

  # Store newest-first, deduplicated, exact $PWD before sibling repo dirs.
  local -A seen=()
  local i
  for (( i = $#exact_rev; i >= 1; i-- )); do
    cmd=$exact_rev[i]
    if (( ! ${+seen[$cmd]} )); then
      seen[$cmd]=1
      _cwd_hist_local+=("$cmd")
    fi
  done
  for (( i = $#repo_rev; i >= 1; i-- )); do
    cmd=$repo_rev[i]
    if (( ! ${+seen[$cmd]} )); then
      seen[$cmd]=1
      _cwd_hist_local+=("$cmd")
    fi
  done
}

_shell_reload_project_caches() {
  emulate -L zsh
  local -A st

  # package.json scripts
  if [[ -r "$PWD/package.json" ]]; then
    zstat -H st "$PWD/package.json" 2>/dev/null
    if [[ "$PWD" != "$_proj_pkg_dir" || "${st[mtime]:-0}" != "$_proj_pkg_mtime" ]]; then
      _proj_pkg_dir=$PWD
      _proj_pkg_mtime=${st[mtime]:-0}
      _proj_pkg_scripts=()
      if (( $+commands[jq] )); then
        _proj_pkg_scripts=( "${(@f)$(jq -r '(.scripts // {}) | keys_unsorted[]' "$PWD/package.json" 2>/dev/null)}" )
      fi
    fi
  else
    _proj_pkg_dir=""
    _proj_pkg_mtime=0
    _proj_pkg_scripts=()
  fi

  # Makefile targets
  local mk=""
  [[ -r "$PWD/Makefile" ]] && mk="$PWD/Makefile"
  [[ -z "$mk" && -r "$PWD/makefile" ]] && mk="$PWD/makefile"
  if [[ -n "$mk" ]]; then
    zstat -H st "$mk" 2>/dev/null
    if [[ "$PWD" != "$_proj_make_dir" || "${st[mtime]:-0}" != "$_proj_make_mtime" ]]; then
      _proj_make_dir=$PWD
      _proj_make_mtime=${st[mtime]:-0}
      _proj_make_targets=()
      local line target
      while IFS= read -r line; do
        if [[ "$line" =~ '^([A-Za-z0-9][A-Za-z0-9_./-]*)[[:space:]]*:([^=]|$)' ]]; then
          target=${match[1]}
          [[ "$target" == *.* && "$target" != */* ]] && continue
          _proj_make_targets+=("$target")
        fi
      done < "$mk"
    fi
  else
    _proj_make_dir=""
    _proj_make_mtime=0
    _proj_make_targets=()
  fi

  # Local git branches (sorted by most recent commit)
  if (( _proj_git_dirty )) || [[ "$PWD" != "$_proj_git_dir" ]]; then
    _proj_git_dir=$PWD
    _proj_git_dirty=0
    _proj_git_branches=()
    local d=$PWD has_git=0
    while [[ "$d" != "/" && -n "$d" ]]; do
      [[ -e "$d/.git" ]] && { has_git=1; break }
      d=${d:h}
    done
    if (( has_git )); then
      _proj_git_branches=( "${(@f)$(git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads 2>/dev/null)}" )
    fi
  fi
}

_shell_reload_ttyhints() {
  emulate -L zsh
  [[ -n "$TTYHINTS_FILE" && -r "$TTYHINTS_FILE" ]] || return
  local -A st
  zstat -H st "$TTYHINTS_FILE" 2>/dev/null || return
  if [[ "${st[mtime]:-0}" != "$_ttyhints_mtime" ]]; then
    _ttyhints_mtime=${st[mtime]:-0}
    _ttyhints_cache=( "${(@f)$(< "$TTYHINTS_FILE")}" )
  fi
}

# --- Shell lifecycle hooks ---

_shell_preexec() {
  emulate -L zsh
  local raw=$1
  # Respect HIST_IGNORE_SPACE: commands starting with a space are private.
  if [[ "$raw" != [[:space:]]* ]]; then
    _shell_pending_cmd=${raw%%[[:space:]]##}
  else
    _shell_pending_cmd=""
  fi
  if [[ -n "$TTYHINTS_PID" ]]; then
    kill -USR1 "$TTYHINTS_PID" 2>/dev/null
  fi
}

_shell_precmd() {
  local rc=$?
  emulate -L zsh

  if [[ -n "$TTYHINTS_PID" ]]; then
    kill -USR2 "$TTYHINTS_PID" 2>/dev/null
  fi

  local cmd=$_shell_pending_cmd
  _shell_pending_cmd=""

  if [[ -n "$cmd" ]]; then
    _shell_last_cmd=$cmd

    # Refresh git branch cache after any git command.
    if [[ "$cmd" == git\ * ]]; then
      _proj_git_dirty=1
      _shell_reload_project_caches
    fi

    # Record commands that succeeded (0) or were stopped with Ctrl+C (130, e.g. dev servers).
    if (( rc == 0 || rc == 130 )) &&
       [[ "$cmd" != cd\ * && "$cmd" != "cd" && "$cmd" != "clear" && "$cmd" != "exit" && "$cmd" != *$'\n'* && ${#cmd} -ge 2 ]]; then
      [[ -d "$_SHELL_HIST_DIR" ]] || mkdir -p -m 700 "$_SHELL_HIST_DIR"
      print -r -- "${PWD}"$'\t'"${cmd}" >> "$_SHELL_CWD_HIST_FILE"

      # Prepend to in-memory cache, deduplicated.
      _cwd_hist_local=( "$cmd" "${(@)_cwd_hist_local:#$cmd}" )

      # Occasionally compact the file if it grows past 20k lines.
      local -A st
      if zstat -H st "$_SHELL_CWD_HIST_FILE" 2>/dev/null && (( ${st[size]:-0} > 1500000 )); then
        local tmp="${_SHELL_CWD_HIST_FILE}.tmp.$$"
        tail -n 10000 "$_SHELL_CWD_HIST_FILE" > "$tmp" 2>/dev/null && mv -f "$tmp" "$_SHELL_CWD_HIST_FILE"
      fi
    fi
  fi
}

_shell_chpwd() {
  emulate -L zsh
  _proj_git_dirty=1
  _shell_reload_cwd_history
  _shell_reload_project_caches
}

add-zsh-hook preexec _shell_preexec
add-zsh-hook precmd _shell_precmd
add-zsh-hook chpwd _shell_chpwd

# Initial load for the starting directory.
_shell_reload_cwd_history
_shell_reload_project_caches

# --- Autosuggestion strategies ---

# 1. Claude Code --resume completion from ~/.claude/projects/<pwd-slug>/*.jsonl
_zsh_autosuggest_strategy_claude_resume() {
  emulate -L zsh
  setopt extended_glob

  local buf=$1 cmd="" flag="" prefix="" has_space=0
  if [[ "$buf" =~ '^(claude|cskip|c)([[:space:]].*)?[[:space:]](--resume|-r)([[:space:]]+)([^[:space:]]*)$' ]]; then
    cmd=${match[1]}
    flag=${match[3]}
    prefix=${match[5]}
    has_space=1
  elif [[ "$buf" =~ '^(claude|cskip|c)([[:space:]].*)?[[:space:]](--resume|-r)$' ]]; then
    cmd=${match[1]}
    flag=${match[3]}
  elif [[ "$buf" =~ '^(--resume)([[:space:]]+)([^[:space:]]*)$' ]]; then
    cmd="claude"
    flag="--resume"
    prefix=${match[3]}
    has_space=1
  elif [[ "$buf" == "--resume" ]]; then
    cmd="claude"
    flag="--resume"
  else
    return
  fi

  _claude_project_dirs "$cmd"
  (( $#reply )) || return

  local best_file="" best_mtime=-1 dir f
  local -a files
  local -A st
  for dir in "${reply[@]}"; do
    files=( "$dir"/${prefix}*.jsonl(Nom[1]) )
    if (( $#files )); then
      f=${files[1]}
      if (( $#reply == 1 )); then
        best_file=$f
        break
      fi
      zstat -H st "$f" 2>/dev/null
      if (( ${st[mtime]:-0} > best_mtime )); then
        best_mtime=${st[mtime]:-0}
        best_file=$f
      fi
    fi
  done

  [[ -n "$best_file" ]] || return
  local id=${best_file:t:r}
  if (( has_space )); then
    [[ "$id" == "$prefix" ]] && return
    suggestion="${buf%${prefix}}${id}"
  else
    suggestion="${buf} ${id}"
  fi
}

# 2. Recent command hints extracted from terminal output by ttyhints
_zsh_autosuggest_strategy_screen_hints() {
  emulate -L zsh
  _shell_reload_ttyhints
  (( $#_ttyhints_cache )) || return

  local h
  for h in "${_ttyhints_cache[@]}"; do
    [[ -n "$h" && "$h" != "$_shell_last_cmd" ]] || continue
    if [[ "$h" == ${1}?* ]]; then
      suggestion=$h
      return
    fi
  done
}

# 3. Directory-aware cd (only destinations that actually exist from $PWD)
_zsh_autosuggest_strategy_cd() {
  emulate -L zsh
  [[ $1 == 'cd '* ]] || return
  local entry dir
  for entry in ${(M)history:#${(b)1}?*}; do
    dir=${(Q)${(z)entry}[2]}
    [[ -d ${dir/#\~/$HOME} ]] && suggestion=$entry && return
  done
  dir=${${(Q)1#cd }/#\~/$HOME}
  local -a dirs=( $dir*(N-/) )
  (( $#dirs )) && suggestion=$1${(q)dirs[1]#$dir}/
}

# 4. Successful command history scoped to current directory / git repository
_zsh_autosuggest_strategy_cwd_history() {
  emulate -L zsh
  (( $#_cwd_hist_local )) || return
  local entry
  for entry in "${_cwd_hist_local[@]}"; do
    if [[ "$entry" == ${1}?* ]]; then
      suggestion=$entry
      return
    fi
  done
}

# 5. Project-local targets: package.json scripts, Makefile targets, git branches
_zsh_autosuggest_strategy_project() {
  emulate -L zsh
  local buf=$1 prefix item

  # npm run / bun run / pnpm run / yarn
  if (( $#_proj_pkg_scripts )); then
    if [[ "$buf" == ("npm run"|"bun run"|"pnpm run") ]]; then
      suggestion="${buf} ${_proj_pkg_scripts[1]}"
      return
    elif [[ "$buf" =~ '^(npm run|bun run|pnpm run|yarn)[[:space:]]+([^[:space:]]*)$' ]]; then
      prefix=${match[2]}
      for item in "${_proj_pkg_scripts[@]}"; do
        [[ -n "$item" && "$item" == ${prefix}?* ]] && suggestion="${buf%${prefix}}${item}" && return
      done
    fi
  fi

  # make <target>
  if (( $#_proj_make_targets )) && [[ "$buf" =~ '^make[[:space:]]+([^[:space:]]*)$' ]]; then
    prefix=${match[1]}
    for item in "${_proj_make_targets[@]}"; do
      [[ -n "$item" && "$item" == ${prefix}?* ]] && suggestion="${buf%${prefix}}${item}" && return
    done
  fi

  # git checkout / switch / merge / rebase / branch -d/-D <branch>
  if (( $#_proj_git_branches )) && [[ "$buf" =~ '^git[[:space:]]+(checkout|switch|merge|rebase|branch[[:space:]]+-[dD])[[:space:]]+([^[:space:]]*)$' ]]; then
    prefix=${match[2]}
    for item in "${_proj_git_branches[@]}"; do
      [[ -n "$item" && "$item" == ${prefix}?* ]] && suggestion="${buf%${prefix}}${item}" && return
    done
  fi
}

# --- Shift+Tab interactive fzf picker for Claude --resume ---

_claude_resume_fzf_picker() {
  emulate -L zsh
  setopt extended_glob

  local buf=$LBUFFER cmd="" prefix="" has_space=0
  if [[ "$buf" =~ '^(claude|cskip|c)([[:space:]].*)?[[:space:]](--resume|-r)([[:space:]]+)([^[:space:]]*)$' ]]; then
    cmd=${match[1]}
    prefix=${match[5]}
    has_space=1
  elif [[ "$buf" =~ '^(claude|cskip|c)([[:space:]].*)?[[:space:]](--resume|-r)$' ]]; then
    cmd=${match[1]}
  elif [[ "$buf" =~ '^(--resume)([[:space:]]+)([^[:space:]]*)$' ]]; then
    cmd="claude"
    prefix=${match[3]}
    has_space=1
  elif [[ "$buf" == "--resume" ]]; then
    cmd="claude"
  else
    return 1
  fi

  _claude_project_dirs "$cmd"
  (( $#reply )) || return 1

  local -a files=()
  local dir
  for dir in "${reply[@]}"; do
    files+=( "$dir"/*.jsonl(Nom[1,30]) )
  done
  (( $#files )) || return 1

  # Build formatted lines: "<uuid>\t<date>  <short-id>  <first prompt>"
  local -a rows=()
  local -A seen_ids=() st
  local f id when prompt
  for f in "${files[@]}"; do
    id=${f:t:r}
    (( ${+seen_ids[$id]} )) && continue
    seen_ids[$id]=1
    zstat -H st -F '%m-%d %H:%M' "$f" 2>/dev/null
    when=${st[mtime]:-"--:--"}
    prompt=""
    if (( $+commands[jq] )); then
      prompt=$(jq -r '
        select(.type=="user" and (.isMeta != true))
        | .message.content
        | if type=="string" then .
          elif type=="array" then ([.[] | select(.type=="text") | .text] | join(" "))
          else "" end
        | gsub("[\r\n\t]+"; " ")
        | select(length > 0 and (startswith("<") | not))
      ' "$f" 2>/dev/null | head -n 1 | cut -c 1-80)
    fi
    [[ -z "$prompt" ]] && prompt="(no prompt preview)"
    rows+=( "${id}"$'\t'"${when}  ${id[1,8]}  ${prompt}" )
  done

  local picked
  picked=$(printf '%s\n' "${rows[@]}" | fzf \
    --height=40% \
    --reverse \
    --delimiter=$'\t' \
    --with-nth=2 \
    --query="$prefix" \
    --prompt="claude resume> ")

  if [[ -n "$picked" ]]; then
    local chosen_id=${picked%%$'\t'*}
    if (( has_space )); then
      LBUFFER="${buf%${prefix}}${chosen_id}"
    else
      LBUFFER="${buf} ${chosen_id}"
    fi
  fi
  zle reset-prompt
  return 0
}

_smart_fzf_complete() {
  if ! _claude_resume_fzf_picker; then
    zle fzf-completion
  fi
}
zle -N _smart_fzf_complete

_tab_accept_or_complete() {
  if [[ -n "$POSTDISPLAY" ]]; then
    zle autosuggest-accept
  else
    zle _smart_fzf_complete
  fi
}
zle -N _tab_accept_or_complete

bindkey '^I' _tab_accept_or_complete
bindkey '^[[Z' _smart_fzf_complete

# --- Wire into zsh-autosuggestions ---

ZSH_AUTOSUGGEST_STRATEGY=(
  claude_resume
  screen_hints
  cd
  cwd_history
  project
  match_prev_cmd
  history
)
ZSH_AUTOSUGGEST_HISTORY_IGNORE='cd *'
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=60
# Keep synchronous: all strategies are in-memory / single-glob (<1 ms),
# and running in the main shell keeps caches warm without subshell forks.
unset ZSH_AUTOSUGGEST_USE_ASYNC
