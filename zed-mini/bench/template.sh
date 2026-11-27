#!/bin/zsh
# Rebuilds db-template, the database every bench launch starts from: one launch on an
# empty database lets Zed store feed.m as the only open file, then a selection is added
# to that editor. A restored selection makes Zed draw paths, as any editing session does
# as soon as something is selected or highlighted. db-template-plain is the same without
# the selection, to measure what drawing paths costs.
#   template.sh [app bundle]
HERE=${0:A:h}
source $HERE/lib.sh
APP=${1:-/Applications/Zed Mini.app}
DB=$HERE/data/db/0-stable/db.sqlite

rm -rf $HERE/db-template $HERE/db-template-plain $HERE/data/db
mkdir -p $HERE/db-template
prepare_data
launch_zed "$APP" || exit 1
sleep 15; kill $pid; while kill -0 $pid 2>/dev/null; do sleep 1; done; sleep 1

# The path column is a blob, which never equals a text literal.
editor=$(sqlite3 $DB "select item_id || ', ' || workspace_id from editors where cast(path as text) = '$BENCH_FILE'")
[[ -n $editor ]] || { echo "Zed did not store an editor for $BENCH_FILE"; exit 1 }
sqlite3 $DB "delete from editor_selections;"
rm -rf $HERE/db-template; cp -R $HERE/data/db $HERE/db-template-plain
sqlite3 $DB "insert into editor_selections (editor_id, workspace_id, start, end) values ($editor, 120, 900);"
cp -R $HERE/data/db $HERE/db-template
echo "template: selection 120-900 in $BENCH_FILE"
