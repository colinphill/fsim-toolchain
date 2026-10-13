#!/bin/sh
#
# Package the Linux-hosted cross toolchain built by `fsim/build.sh linux`:
#
#   NAME.tar.xz    clang, lld and the x86_64-w64-mingw32 UCRT runtimes,
#                  running on x86_64 Linux; one top-level directory NAME
#   NAME.sha256    its SHA-256
#
#   fsim/package-linux.sh TOOLCHAIN DIST NAME
#
# Entries are sorted with fixed owners and one timestamp, so packaging one
# build twice is byte-identical; FSIM-TOOLCHAIN.txt records the commit.

set -e

if [ $# -ne 3 ]; then
    sed -n '/^#   fsim/s/^#   //p' "$0" 1>&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="$(cd "$1" && pwd)"
mkdir -p "$2"
DIST="$(cd "$2" && pwd)"
NAME="$3"
# Matches the zip archives' entry time (see package.sh).
ENTRY_TIME=946684800

version_of() {
    sed -n "s/^: \${$1:=\(.*\)}\$/\1/p" "$ROOT/$2"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -a "$TOOLCHAIN" "$WORK/$NAME"
cat > "$WORK/$NAME/FSIM-TOOLCHAIN.txt" <<MANIFEST
name=$NAME
variant=linux-cross
fork_commit=$(git -C "$ROOT" rev-parse HEAD)
upstream=llvm-mingw 20260616
llvm=${LLVM_VERSION:-$(version_of LLVM_VERSION build-llvm.sh)}
mingw_w64=${MINGW_W64_VERSION:-$(version_of MINGW_W64_VERSION build-mingw-w64.sh)}
host=x86_64-linux-gnu
target=x86_64-w64-mingw32
crt=ucrt
llvm_targets=X86
MANIFEST

tar -C "$WORK" -Jcf "$DIST/$NAME.tar.xz" --format=ustar --numeric-owner \
    --owner=0 --group=0 --sort=name --mtime="@$ENTRY_TIME" "$NAME"
(cd "$DIST" && sha256sum "$NAME.tar.xz" > "$NAME.sha256")
cat "$DIST/$NAME.sha256"
