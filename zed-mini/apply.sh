#!/bin/zsh
# Applies the patch series in this folder on top of an upstream Zed tag, leaving the
# checkout on a branch named mini-<tag>. Prints one line on stdout: what it applied, or
# why not (git's own output goes to stderr).
#   apply.sh <zed checkout> <tag>
SRC=${1:?zed checkout}; TAG=${2:?tag}; HERE=${0:A:h}
die() { echo "$1"; exit 1 }

# git am records a committer, and the checkout has no git identity configured.
export GIT_COMMITTER_NAME=mini GIT_COMMITTER_EMAIL=mini@local

cd "$SRC" || die "missing checkout $SRC"
# Abort any interrupted `git am` left behind by a killed run before checking status.
rebase_dir=$(git rev-parse --git-path rebase-apply 2>/dev/null || true)
if [[ -n $rebase_dir && -d $rebase_dir ]]; then
  git am --abort >&2 || rm -rf "$rebase_dir"
fi
# Resetting the branch to the tag would silently drop uncommitted work.
[[ -z $(git status --porcelain --untracked-files=no) ]] || die "$SRC has uncommitted changes"
prev_ref=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --verify HEAD 2>/dev/null || true)
restore_prev() {
  [[ -n $prev_ref ]] && git checkout --quiet "$prev_ref" >&2 || true
}

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  if [[ $(git rev-parse --is-shallow-repository 2>/dev/null) == true ]]; then
    git fetch --quiet --depth 1 origin tag "$TAG" || die "could not fetch $TAG"
  else
    git fetch --quiet origin tag "$TAG" || die "could not fetch $TAG"
  fi
fi
git checkout --quiet -B "mini-$TAG" "$TAG" || { restore_prev; die "could not check out $TAG" }

patches=("$HERE"/0*.patch)
deepened=0
for patch in "${patches[@]}"; do
  if ! git am --quiet --3way "$patch" >&2; then
    git am --abort >&2 || true
    # A shallow clone can lack the base blobs `--3way` needs across upstream tags;
    # deepen once and retry before declaring the patch broken.
    if (( ! deepened )) && [[ $(git rev-parse --is-shallow-repository 2>/dev/null) == true ]]; then
      deepened=1
      git fetch --quiet --deepen=500 origin >&2 || true
      if git am --quiet --3way "$patch" >&2; then
        continue
      fi
      git am --abort >&2 || true
    fi
    restore_prev
    die "patch ${patch:t} does not apply on $TAG"
  fi
done
echo "applied ${#patches} patches on $TAG"
