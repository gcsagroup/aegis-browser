#!/bin/sh
# Build in a new directory from the pinned upstream Git tree, irrespective of checkout state.
set -eu
if [ "$#" != 3 ]; then
    echo "usage: $0 XRAY_GIT_CHECKOUT NEW_BUILD_DIRECTORY OUTPUT_BINARY" >&2
    exit 2
fi
adapter=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
commit=676eaf66f8f05d4d558ee7a74b4736623d3feeb9
[ "$(go env GOVERSION)" = go1.27.3 ] || { echo "Go 1.27.3 required" >&2; exit 1; }
output=$(cd -- "$(dirname -- "$3")" && pwd -P)/$(basename -- "$3")
mkdir -- "$2"
builddir=$(cd -- "$2" && pwd -P)
git -C "$1" archive --format=tar -o "$builddir/source.tar" "$commit"
cd -- "$builddir"
tar -xf source.tar
rm source.tar
git apply "$adapter/xray.patch"
mkdir common/aegismeter
cp "$adapter"/aegismeter/*.go common/aegismeter/
go test -mod=readonly ./common/aegismeter
go build -mod=readonly -trimpath -buildvcs=false -o "$output" ./main
