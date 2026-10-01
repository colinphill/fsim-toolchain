#!/bin/sh
#
# Package a toolchain built by fsim/build.sh into three archives, each with a
# single top-level directory NAME so they can be extracted over one another:
#
#   NAME.zip            the complete toolchain fsim builds with, including
#                       BusyBox and GNU make for Tcl's configure step
#   NAME-llvm-dev.zip   LLVM headers, CMake package and libLLVM import
#                       library; extract over NAME.zip to build fsim
#   NAME-redist.zip     what fsim's release archive bundles: NAME.zip
#                       without the GPL/LGPL build tools
#
#   fsim/package.sh TOOLCHAIN LLVM_DEV DIST NAME
#
# Entries are sorted and carry one fixed timestamp, so repeated packaging of
# one build is byte-identical; FSIM-TOOLCHAIN.txt records the commit instead.

set -e

if [ $# -ne 4 ]; then
    sed -n '/^#   fsim/s/^#   //p' "$0" 1>&2
    exit 1
fi
for dep in zip sha256sum; do
    if ! command -v $dep >/dev/null; then
        echo "$dep not installed. Please install it and retry" 1>&2
        exit 1
    fi
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="$(cd "$1" && pwd)"
LLVM_DEV="$(cd "$2" && pwd)"
mkdir -p "$3"
DIST="$(cd "$3" && pwd)"
NAME="$4"
# Zip timestamps have no time zone and extractors read them as local time.
# A recent time such as the commit date would extract hours in the future
# west of UTC, which makes CMake and Ninja regenerate endlessly, so every
# entry gets 2000-01-01T00:00:00Z instead.
ENTRY_TIME=946684800

# Build tools under the GPL or LGPL stay out of the redistributable bundle.
REDIST_EXCLUDES="
busybox
bin/mingw32-make.exe
share/make
bin/gendef.exe
share/gendef
bin/widl.exe
bin/x86_64-w64-mingw32-widl.exe
share/widl
"

version_of() {
    sed -n "s/^: \${$1:=\(.*\)}\$/\1/p" "$ROOT/$2"
}

write_manifest() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<EOF
name=$NAME
variant=$2
fork_commit=$(git -C "$ROOT" rev-parse HEAD)
upstream=llvm-mingw 20260616
llvm=${LLVM_VERSION:-$(version_of LLVM_VERSION build-llvm.sh)}
mingw_w64=${MINGW_W64_VERSION:-$(version_of MINGW_W64_VERSION build-mingw-w64.sh)}
target=x86_64-w64-mingw32
crt=ucrt
llvm_targets=X86
EOF
}

make_zip() {
    stage="$1"
    zip_path="$2"
    find "$stage" -exec touch -h -d "@$ENTRY_TIME" {} +
    rm -f "$zip_path"
    (cd "$(dirname "$stage")" && find "$(basename "$stage")" -print \
        | LC_ALL=C sort | TZ=UTC zip -X -9 -q "$zip_path" -@)
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

stage="$WORK/full/$NAME"
mkdir -p "$stage"
cp -a "$TOOLCHAIN/." "$stage"
write_manifest "$stage/FSIM-TOOLCHAIN.txt" build
make_zip "$stage" "$DIST/$NAME.zip"

stage="$WORK/dev/$NAME"
mkdir -p "$stage"
cp -a "$LLVM_DEV/." "$stage"
# A separate name, so the overlay never replaces the toolchain's manifest.
write_manifest "$stage/share/fsim-toolchain/llvm-dev.txt" llvm-dev
make_zip "$stage" "$DIST/$NAME-llvm-dev.zip"

stage="$WORK/redist/$NAME"
mkdir -p "$stage"
cp -a "$TOOLCHAIN/." "$stage"
for path in $REDIST_EXCLUDES; do
    rm -rf "$stage/$path"
done
write_manifest "$stage/FSIM-TOOLCHAIN.txt" redist
make_zip "$stage" "$DIST/$NAME-redist.zip"

(cd "$DIST" && sha256sum "$NAME.zip" "$NAME-llvm-dev.zip" "$NAME-redist.zip" \
    > "$NAME.sha256")
cat "$DIST/$NAME.sha256"
