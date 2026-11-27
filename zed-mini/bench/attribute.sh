#!/bin/zsh
# Attributes a Zed Mini process's memory to the code that allocated it: launches a staged
# build with malloc stack logging, lets it settle, then writes to runs/<label>.*
#   footprint   categories
#   surfaces    the GPU surface regions (vmmap)
#   calltree    who owns the live malloc blocks and VM regions, top down
#   inverted    the same from the allocating frames up
#   bysize      the largest allocations with their full stacks (window-sized surfaces first)
#   sample      3 s of every thread's stack, which also names the threads
#   attribute.sh <label> <staged build name> [wait seconds]
HERE=${0:A:h}
source $HERE/lib.sh
LABEL=${1:?label}; NAME=${2:?staged build name}; WAIT=${3:-60}
OUT=$HERE/runs/$LABEL
[[ -d $HERE/stage/$NAME.app && -f $HERE/stage/$NAME.symbols ]] || { echo "no staged build $NAME (see build-stage.sh)"; exit 1 }

# malloc_history names frames from the binary on disk, and bundle.sh strips that one, so
# the launch uses a copy of the bundle with the unstripped binary put back.
APP=$HERE/stage/$NAME-symbols.app
rm -rf $APP; cp -Rc $HERE/stage/$NAME.app $APP; cp -c $HERE/stage/$NAME.symbols $APP/Contents/MacOS/zed
codesign --force --sign - $APP 2>/dev/null
trap 'rm -rf $APP' EXIT

prepare_data
BENCH_ENV="MallocStackLogging=1 $BENCH_ENV" launch_zed $APP || exit 1
sleep $WAIT
footprint $pid > $OUT.footprint 2>&1
vmmap $pid 2>/dev/null | grep -E "^(IOSurface|IOAccelerator)" > $OUT.surfaces
malloc_history $pid -callTree -consolidateAllBySymbol -chargeSystemLibraries > $OUT.calltree 2>&1
malloc_history $pid -callTree -invert -consolidateAllBySymbol -chargeSystemLibraries > $OUT.inverted 2>&1
malloc_history $pid -allBySize 2>/dev/null | head -60 > $OUT.bysize
sample $pid 3 -file $OUT.sample >/dev/null 2>&1
kill $pid
echo "wrote $OUT.{footprint,surfaces,calltree,inverted,bysize,sample}"
grep -E "Footprint:|IOSurface|Malloc Small|Malloc Large" $OUT.footprint
