#!/bin/zsh
# Builds a git ref of the fork as "/Applications/Zed Mini Test.app": a second app to try a
# change in before it goes into Zed Mini. The ref has to carry the test identity (its own
# single-instance port, data dir and log), or the app would exit as a second Zed Mini.
# Like update.sh, it installs only a build that stays up in a smoke launch.
#   test-app.sh <git ref>
HERE=${0:A:h}
source $HERE/lib.sh
REF=${1:?git ref}
APP="/Applications/Zed Mini Test.app"
die() { echo "$1"; exit 1 }

$HERE/build-stage.sh test $REF || die "build of $REF failed"
grep -a -q "Zed Mini Test Instance Running" $HERE/stage/test.symbols \
  || die "$REF does not carry the test identity"
tag=$(/usr/libexec/PlistBuddy -c 'Print :ZedMiniUpstreamTag' $HERE/stage/test.app/Contents/Info.plist)
TMP=$(mktemp -d); trap 'rm -rf $TMP' EXIT
$HERE/../bundle.sh $HERE/stage/test.symbols "$TMP/${APP:t}" $tag || die "bundling failed"

prev=$(front_bundle)
open -g -n -a "$TMP/${APP:t}" --env ZED_STATELESS=1 --args --user-data-dir $TMP/data
sleep 1; pid=$(pgrep -n -f "$TMP/${APP:t}/Contents/MacOS/zed")
[[ -n $pid ]] && guard_focus $pid "$prev"
sleep 20
kill -0 $pid 2>/dev/null || die "smoke launch exited early"
kill $pid; while kill -0 $pid 2>/dev/null; do sleep 1; done

rm -rf "$APP"; mv "$TMP/${APP:t}" "$APP" || die "installing $APP failed"
echo "installed $APP from $REF"
