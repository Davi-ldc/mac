#!/bin/zsh
# Builds one commit of the fork and wraps it as a bundle under bench/stage/<name>.app, so
# measure.sh can compare builds. Waits for power before building and pauses without it
# (see powerguard.sh).
#   build-stage.sh <name> <git ref>
# Leaves the checkout back on the branch it was on. Refuses to run with uncommitted changes,
# since checking out another ref would carry them along.
setopt PIPE_FAIL
HERE=${0:A:h}
NAME=${1:?name}; REF=${2:?git ref}
SRC=${HERE:h:h}/local/zed
STAGE=$HERE/stage/$NAME.app
die() { echo "$1"; exit 1 }

cd $SRC || die "missing checkout $SRC"
[[ -z $(git status --porcelain --untracked-files=no) ]] || die "$SRC has uncommitted changes"
branch=$(git branch --show-current)
git rev-parse -q --verify "$REF^{commit}" >/dev/null || die "unknown ref $REF"
until $HERE/../powerguard.sh --check; do sleep 30; done
# A killed run must not leave the checkout detached: signals become a normal exit so the
# EXIT trap still puts the branch back.
trap 'exit 1' INT TERM HUP
trap 'git checkout --quiet $branch' EXIT
git checkout --quiet --detach $REF || die "could not check out $REF"
echo "building $NAME ($(git rev-parse --short HEAD)) at $(date +%H:%M)"
CARGO_PROFILE_RELEASE_DEBUG=false \
  ZED_UPDATE_EXPLANATION="Zed Mini is updated by ${HERE:h}/update.sh" \
  $HERE/../powerguard.sh nice -n 10 cargo build --release -p zed --features gpui_platform/runtime_shaders \
  || die "build of $NAME failed"
tag=$(/usr/libexec/PlistBuddy -c 'Print :ZedMiniUpstreamTag' "/Applications/Zed Mini.app/Contents/Info.plist" 2>/dev/null || echo v0.0.0)
rm -rf $STAGE; mkdir -p $HERE/stage
# Bench bundles are signed ad hoc: they open nothing behind a privacy prompt, and the
# fixed identity could put a keychain dialog in front of the user.
$HERE/../bundle.sh --no-cli $SRC/target/release/zed $STAGE $tag - || die "bundling $NAME failed"
# The unstripped binary keeps its symbols for malloc_history; bundle.sh strips the copy.
cp $SRC/target/release/zed $HERE/stage/$NAME.symbols
echo "staged $STAGE at $(date +%H:%M)"
