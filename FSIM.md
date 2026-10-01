# fsim toolchain

This repository is a fork of [llvm-mingw](https://github.com/mstorsjo/llvm-mingw)
that builds the Windows toolchain fsim compiles with and ships in its
release archive. fsim bundles it so users can build SystemC, DPI and VPI
plug-ins with the exact compiler and C++ runtime fsim itself was built
with, and debug them with LLDB.

The fork is pinned to upstream tag `20260616` (LLVM 22.1.8, the LLVM
version fsim requires).

## Differences from upstream

- Hosts and targets x86_64 Windows only (`TOOLCHAIN_ARCHS=x86_64`), with the
  UCRT. LLVM is built with only the X86 backend.
- Contains clang, lld and LLDB (with `lldb-dap`), without clang-tools-extra
  (clangd, clang-tidy), `lldb-mi`, or Python scripting for LLDB.
- LLVM is built with RTTI, which fsim's JIT requires.
- The same build also produces an LLVM development overlay (headers, CMake
  package, `libLLVM-22.dll` import library), so fsim compiles against exactly
  the `libLLVM-22.dll` it ships. The CMake package exports only the shared
  `LLVM` target.
- The native Linux runtimes the stage1 compiler builds for its own use are
  not copied into the Windows toolchain.

The upstream changes are confined to `build-llvm.sh`,
`build-cross-tools.sh` and `prepare-cross-toolchain.sh`; everything specific
to fsim lives under `fsim/` and in `.github/workflows/fsim.yml`.

## Outputs

`fsim/package.sh` writes three archives with one top-level directory each,
plus a SHA-256 list:

| Archive | Contents | Used by |
|---|---|---|
| `NAME.zip` | The complete toolchain, including BusyBox and GNU make | fsim CI, to build fsim (Tcl's configure step needs `sh` and `make`) |
| `NAME-llvm-dev.zip` | LLVM headers, CMake package and import library | Extracted over `NAME.zip` for fsim CI's `LLVM_DIR` |
| `NAME-redist.zip` | `NAME.zip` without BusyBox, GNU make, `widl` and `gendef` | fsim's release archive |

The redistributable leaves out the build tools licensed under the GPL or
LGPL. What remains is under LLVM's Apache-2.0 WITH LLVM-exception
license, the mingw-w64 runtime and header licenses (ZPL, public domain,
MIT/BSD for winpthreads), and ISC for the llvm-mingw wrappers.

Each archive carries `FSIM-TOOLCHAIN.txt` (the overlay uses
`share/fsim-toolchain/llvm-dev.txt`) naming the fork commit, the upstream
tag, and the LLVM and mingw-w64 versions.

## Building

CI (`.github/workflows/fsim.yml`) follows upstream's release flow: a
Linux-hosted stage1 compiler, a PGO profile, then the Windows-hosted
toolchain cross-built with ThinLTO and PGO, tested on a Windows runner by
`fsim/test-windows.ps1`. Pushing a tag `fsim-VERSION` publishes the
archives as a GitHub release named `fsim-toolchain-VERSION-ucrt-x86_64`.

A local build on Ubuntu 22.04 or later needs `build-essential cmake
ninja-build git curl zip unzip libltdl-dev autoconf-archive`:

```sh
fsim/build.sh all /path/to/work          # add --pgo to match releases
fsim/package.sh /path/to/work/toolchain /path/to/work/llvm-dev dist \
    fsim-toolchain-local-ucrt-x86_64
```

## Updating

To move to a newer upstream release, merge the upstream tag, keep the
changes above, and update the pinned tag here and in `fsim/package.sh`.
Bump fsim's required LLVM version at the same time if it changes.
