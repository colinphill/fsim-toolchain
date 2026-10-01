#!/bin/sh
#
# Build the fsim Windows toolchain: clang, lld and lldb for x86_64 Windows,
# targeting only x86_64-w64-mingw32 with the UCRT, plus the LLVM development
# overlay that fsim compiles its JIT against.
#
# The phases mirror upstream llvm-mingw's CI: a Linux-hosted stage1
# compiler, an optional PGO profile, then a Windows-hosted toolchain
# cross-built with stage1. Run them separately (CI) or all at once (local).
#
#   fsim/build.sh stage1 STAGE1
#   fsim/build.sh profile STAGE1          writes ./profile.profdata
#   fsim/build.sh windows STAGE1 OUT DEV [--pgo]
#   fsim/build.sh all WORK [--pgo]        WORK/{stage1,toolchain,llvm-dev}
#
# --pgo builds the Windows toolchain with ThinLTO and ./profile.profdata,
# matching upstream release builds; without it the build is much faster.

set -e

cd "$(dirname "$0")/.."

export TOOLCHAIN_ARCHS=x86_64
# libxml2 and Python serve LLVM/LLDB features fsim does not ship; leaving
# them out keeps the binaries free of extra runtime dependencies.
export LLVM_CMAKEFLAGS="$LLVM_CMAKEFLAGS -DLLVM_ENABLE_LIBXML2=OFF -DLLDB_ENABLE_PYTHON=OFF"

stage1() {
    ./build-all.sh "$1" --stage1 --disable-clang-tools-extra
}

profile() {
    ./build-all.sh --profile "$1"
}

windows() {
    stage1_dir="$1"
    out_dir="$2"
    dev_dir="$3"
    optimize="$4"
    flags="--with-busybox --disable-lldb-mi --disable-clang-tools-extra"
    if [ "$optimize" = "--pgo" ]; then
        flags="$flags --thinlto --pgo"
    fi
    ./build-cross-tools.sh "$stage1_dir" "$out_dir" x86_64 \
        --with-llvm-dev="$dev_dir" $flags
}

usage() {
    sed -n '/^#   /s/^#   //p' "$0" 1>&2
    exit 1
}

phase="$1"
[ -n "$phase" ] || usage
shift
case "$phase" in
stage1)
    [ $# -eq 1 ] || usage
    stage1 "$1"
    ;;
profile)
    [ $# -eq 1 ] || usage
    profile "$1"
    ;;
windows)
    [ $# -ge 3 ] || usage
    windows "$1" "$2" "$3" "$4"
    ;;
all)
    [ $# -ge 1 ] || usage
    work="$1"
    mkdir -p "$work"
    work="$(cd "$work" && pwd)"
    stage1 "$work/stage1"
    if [ "$2" = "--pgo" ]; then
        profile "$work/stage1"
    fi
    windows "$work/stage1" "$work/toolchain" "$work/llvm-dev" "$2"
    ;;
*)
    usage
    ;;
esac
