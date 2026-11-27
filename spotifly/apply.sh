#!/bin/zsh
# Applies the patch series in this folder on top of an upstream Spotifly tag, leaving the
# checkout on a branch named patched-<tag>. Prints one line on stdout: what it applied, or
# why not (git's own output goes to stderr).
#   apply.sh <spotifly checkout> <tag>
SRC=${1:?spotifly checkout}; TAG=${2:?tag}; HERE=${0:A:h}
die() { echo "$1"; exit 1 }

# git am records a committer, and the checkout has no git identity configured.
export GIT_COMMITTER_NAME=patched GIT_COMMITTER_EMAIL=patched@local

cd $SRC || die "missing checkout $SRC"
# Resetting the branch to the tag would silently drop uncommitted work.
[[ -z $(git status --porcelain --untracked-files=no) ]] || die "$SRC has uncommitted changes"
git fetch --quiet --tags origin || die "could not fetch $TAG"
git checkout --quiet -B patched-$TAG $TAG || die "could not check out $TAG"
patches=($HERE/0*.patch)
for patch in $patches; do
  git am --quiet --3way $patch >&2 || {
    git am --abort >&2
    die "patch ${patch:t} does not apply on $TAG"
  }
done
echo "applied ${#patches} patches on $TAG"
