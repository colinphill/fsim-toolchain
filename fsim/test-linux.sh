#!/bin/sh
#
# Verify the Linux-hosted cross toolchain: it compiles C++20 for
# x86_64-w64-mingw32, its target runtimes are byte-identical to those of the
# Windows-hosted toolchain, and fsim's LLVM overlay cross-builds against the
# shipped libLLVM with RTTI. Programs run under Wine when it is installed.
#
#   fsim/test-linux.sh DIST LINUX_NAME WINDOWS_NAME
#
# DIST holds LINUX_NAME.tar.xz, WINDOWS_NAME.zip and WINDOWS_NAME-llvm-dev.zip.

set -e

if [ $# -ne 3 ]; then
    sed -n '/^#   fsim/s/^#   //p' "$0" 1>&2
    exit 1
fi
DIST="$(cd "$1" && pwd)"
LINUX_NAME="$2"
WINDOWS_NAME="$3"

fail() {
    echo "toolchain test failed: $*" 1>&2
    exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -C "$WORK" -Jxf "$DIST/$LINUX_NAME.tar.xz"
unzip -q "$DIST/$WINDOWS_NAME.zip" -d "$WORK/windows"
unzip -q "$DIST/$WINDOWS_NAME-llvm-dev.zip" -d "$WORK/windows"
ROOT="$WORK/$LINUX_NAME"
WINDOWS="$WORK/windows/$WINDOWS_NAME"
CXX="$ROOT/bin/x86_64-w64-mingw32-clang++"
TARGET_BIN="$ROOT/x86_64-w64-mingw32/bin"

grep -q '^variant=linux-cross$' "$ROOT/FSIM-TOOLCHAIN.txt" || fail "manifest variant"
for arch in i686 armv7 aarch64 arm64ec; do
    [ ! -e "$ROOT/$arch-w64-mingw32" ] || fail "$arch sysroot is present"
done
triple="$("$CXX" -print-target-triple)"
[ "$triple" = x86_64-w64-windows-gnu ] || fail "unexpected target $triple"
"$CXX" --version | grep -q 'clang version 22\.1\.8' || fail "unexpected clang version"

# The runtimes cross-built binaries load are the ones fsim ships on Windows.
for dll in libc++.dll libunwind.dll; do
    a="$(sha256sum < "$TARGET_BIN/$dll")"
    b="$(sha256sum < "$WINDOWS/bin/$dll")"
    [ "$a" = "$b" ] || fail "$dll differs from the Windows-hosted toolchain's"
done

if command -v wine64 >/dev/null; then
    WINE=wine64
elif command -v wine >/dev/null; then
    WINE=wine
else
    WINE=
fi
# Runs a Windows program with the DLLs from DLL_DIR copied beside it (as a
# Windows installation would place them).
run_windows() {
    if [ -z "$WINE" ]; then
        echo "wine is not installed; skipping $1" 1>&2
        return 0
    fi
    for dll in "$2"/*.dll; do
        [ -e "$(dirname "$1")/$(basename "$dll")" ] || cp "$dll" "$(dirname "$1")/"
    done
    WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" $WINE "$1"
}

# Cross-compile C++20 with a plug-in DLL, as fsim plug-ins are built.
SRC="$WORK/src"
mkdir -p "$SRC"
cat > "$SRC/hello.cpp" <<'CPP'
#include <format>
#include <iostream>
#include <thread>
extern "C" __declspec(dllimport) int plugin_answer();
int main() {
    int answer = 0;
    std::thread worker([&] { answer = plugin_answer(); });
    worker.join();
    try {
        throw answer;
    } catch (int value) {
        std::cout << std::format("answer={}", value) << '\n';
    }
    return answer == 42 ? 0 : 1;
}
CPP
cat > "$SRC/plugin.cpp" <<'CPP'
#include <string>
extern "C" __declspec(dllexport) int plugin_answer() {
    return static_cast<int>(std::string(42, 'x').size());
}
CPP
"$CXX" -std=c++20 -g -shared "$SRC/plugin.cpp" -o "$SRC/plugin.dll" \
    -Wl,--out-implib,"$SRC/libplugin.dll.a"
"$CXX" -std=c++20 -g "$SRC/hello.cpp" -L"$SRC" -lplugin -o "$SRC/hello.exe"
if [ -n "$WINE" ]; then
    output="$(run_windows "$SRC/hello.exe" "$TARGET_BIN")"
    echo "$output" | grep -q 'answer=42' || fail "hello.exe printed: $output"
fi

# Cross-build against fsim's LLVM overlay (the Windows libLLVM import
# library and CMake package); dynamic_cast needs libLLVM's RTTI.
CONSUMER="$WORK/llvm-consumer"
mkdir -p "$CONSUMER"
cat > "$CONSUMER/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.20)
project(llvm_consumer CXX)
find_package(LLVM 22.1.8 EXACT CONFIG REQUIRED)
add_executable(llvm_consumer main.cpp)
target_include_directories(llvm_consumer SYSTEM PRIVATE ${LLVM_INCLUDE_DIRS})
target_compile_features(llvm_consumer PRIVATE cxx_std_17)
target_link_libraries(llvm_consumer PRIVATE LLVM)
CMAKE
cat > "$CONSUMER/main.cpp" <<'CPP'
#include <llvm/Config/llvm-config.h>
#include <llvm/IR/Constants.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Type.h>
#include <llvm/Support/raw_ostream.h>
int main() {
    llvm::LLVMContext context;
    auto* constant = llvm::ConstantInt::get(llvm::Type::getInt32Ty(context), 7);
    llvm::raw_ostream* stream = &llvm::outs();
    auto* file = dynamic_cast<llvm::raw_fd_ostream*>(stream);
    llvm::outs() << "llvm=" << LLVM_VERSION_STRING
                 << " value=" << constant->getZExtValue()
                 << " rtti=" << (file != nullptr) << "\n";
    return constant->getZExtValue() == 7 && file != nullptr ? 0 : 1;
}
CPP
cat > "$WORK/toolchain.cmake" <<CMAKE
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER "$ROOT/bin/x86_64-w64-mingw32-clang")
set(CMAKE_CXX_COMPILER "$ROOT/bin/x86_64-w64-mingw32-clang++")
set(CMAKE_RC_COMPILER "$ROOT/bin/x86_64-w64-mingw32-windres")
set(CMAKE_FIND_ROOT_PATH "$ROOT/x86_64-w64-mingw32" "$WINDOWS")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
CMAKE
cmake -S "$CONSUMER" -B "$WORK/llvm-consumer-build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$WORK/toolchain.cmake" \
    -DLLVM_DIR="$WINDOWS/lib/cmake/llvm" > "$WORK/cmake.log" \
    || { cat "$WORK/cmake.log"; fail "configuring the LLVM consumer"; }
cmake --build "$WORK/llvm-consumer-build" > "$WORK/build.log" \
    || { cat "$WORK/build.log"; fail "building the LLVM consumer"; }
if [ -n "$WINE" ]; then
    output="$(run_windows "$WORK/llvm-consumer-build/llvm_consumer.exe" "$WINDOWS/bin")"
    echo "$output" | grep -q 'llvm=22\.1\.8 value=7 rtti=1' || fail "LLVM consumer printed: $output"
fi

echo "fsim Linux cross toolchain tests passed: $LINUX_NAME"
