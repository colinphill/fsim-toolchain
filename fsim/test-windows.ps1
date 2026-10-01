# Verify a packaged fsim toolchain on Windows: the compiler, linker and
# debugger work, the LLVM overlay builds against the shipped libLLVM with
# RTTI, and the redistributable omits the GPL/LGPL build tools.
param(
  [Parameter(Mandatory = $true)][string]$Dist,
  [Parameter(Mandatory = $true)][string]$Name
)
$ErrorActionPreference = 'Stop'

function Check([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "toolchain test failed: $Message" }
}

function Run([string]$Program, [string[]]$Arguments) {
  $output = & $Program @Arguments 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    throw "$Program $($Arguments -join ' ') failed ($LASTEXITCODE):`n$output"
  }
  return $output
}

$dist = (Resolve-Path $Dist).Path
$work = Join-Path ([IO.Path]::GetTempPath()) "fsim-toolchain-test"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Path $work | Out-Null

# The build toolchain with the LLVM overlay extracted over it, as fsim CI uses it.
$build = Join-Path $work "build"
Expand-Archive (Join-Path $dist "$Name.zip") $build
Expand-Archive (Join-Path $dist "$Name-llvm-dev.zip") $build -Force
$root = Join-Path $build $Name
$bin = Join-Path $root "bin"
$env:PATH = "$bin;$env:PATH"

foreach ($arch in 'i686', 'armv7', 'aarch64', 'arm64ec') {
  Check (-not (Test-Path (Join-Path $root "$arch-w64-mingw32"))) "$arch sysroot is present"
}
Check (-not (Get-ChildItem (Join-Path $root "lib/clang/*/lib/linux") -ErrorAction SilentlyContinue)) `
  "native Linux runtimes are present"
$exports = Run "$bin/llvm-readobj.exe" @('--coff-exports', "$bin/libLLVM-22.dll")
Check ($exports -match '_ZTIN4llvm') "libLLVM-22.dll exports no RTTI type information"
$triple = (Run "$bin/clang++.exe" @('-print-target-triple')).Trim()
Check ($triple -eq 'x86_64-w64-windows-gnu') "unexpected default target $triple"

# Compile, link and run C++20 against the shared libc++.
$src = Join-Path $work "src"
New-Item -ItemType Directory -Path $src | Out-Null
Set-Content -Path "$src/hello.cpp" -Encoding ascii -Value @'
#include <format>
#include <iostream>
extern "C" __declspec(dllimport) int plugin_answer();
int main() {
    std::cout << std::format("answer={}", plugin_answer()) << '\n';
    return plugin_answer() == 42 ? 0 : 1;
}
'@
Set-Content -Path "$src/plugin.cpp" -Encoding ascii -Value @'
#include <string>
extern "C" __declspec(dllexport) int plugin_answer() {
    return static_cast<int>(std::string(42, 'x').size());
}
'@
Run "$bin/clang++.exe" @('-std=c++20', '-g', '-shared', "$src/plugin.cpp",
  '-o', "$src/plugin.dll", "-Wl,--out-implib,$src/libplugin.dll.a") | Out-Null
Run "$bin/clang++.exe" @('-std=c++20', '-g', "$src/hello.cpp",
  "-L$src", '-lplugin', '-o', "$src/hello.exe") | Out-Null
$env:PATH = "$src;$env:PATH"
$hello = Run "$src/hello.exe" @()
Check ($hello -match 'answer=42') "hello.exe printed: $hello"

# Debug the program: stop at the plug-in function and show the frame.
$lldb = Run "$bin/lldb.exe" @('--batch', '-o', 'breakpoint set --name plugin_answer',
  '-o', 'run', '-o', 'bt', '-o', 'continue', "$src/hello.exe")
Check ($lldb -match 'stop reason = breakpoint') "lldb did not stop at the breakpoint:`n$lldb"
Check ($lldb -match 'plugin_answer') "lldb backtrace lacks plugin_answer:`n$lldb"
Run "$bin/lldb-dap.exe" @('--help') | Out-Null

# Build against the LLVM CMake package; dynamic_cast needs libLLVM RTTI.
$cmakeSource = Join-Path $work "llvm-consumer"
New-Item -ItemType Directory -Path $cmakeSource | Out-Null
Set-Content -Path "$cmakeSource/CMakeLists.txt" -Encoding ascii -Value @'
cmake_minimum_required(VERSION 3.20)
project(llvm_consumer CXX)
find_package(LLVM 22.1.8 EXACT CONFIG REQUIRED)
add_executable(llvm_consumer main.cpp)
target_include_directories(llvm_consumer SYSTEM PRIVATE ${LLVM_INCLUDE_DIRS})
target_compile_features(llvm_consumer PRIVATE cxx_std_17)
target_link_libraries(llvm_consumer PRIVATE LLVM)
'@
Set-Content -Path "$cmakeSource/main.cpp" -Encoding ascii -Value @'
#include <llvm/Config/llvm-config.h>
#include <llvm/IR/Constants.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Type.h>
#include <llvm/Support/raw_ostream.h>
int main() {
    llvm::LLVMContext context;
    llvm::Value* value = llvm::ConstantInt::get(llvm::Type::getInt32Ty(context), 7);
    auto* constant = dynamic_cast<llvm::ConstantInt*>(value);
    llvm::outs() << "llvm=" << LLVM_VERSION_STRING
                 << " value=" << (constant ? constant->getZExtValue() : 0) << "\n";
    return constant && constant->getZExtValue() == 7 ? 0 : 1;
}
'@
$cmakeBuild = Join-Path $work "llvm-consumer-build"
Run "cmake" @('-S', $cmakeSource, '-B', $cmakeBuild, '-G', 'Ninja',
  "-DCMAKE_CXX_COMPILER=$bin/clang++.exe",
  "-DLLVM_DIR=$root/lib/cmake/llvm") | Out-Null
Run "cmake" @('--build', $cmakeBuild) | Out-Null
$consumer = Run "$cmakeBuild/llvm_consumer.exe" @()
Check ($consumer -match 'llvm=22\.1\.8 value=7') "LLVM consumer printed: $consumer"

# The redistributable is the build toolchain without GPL/LGPL build tools.
$redist = Join-Path $work "redist"
Expand-Archive (Join-Path $dist "$Name-redist.zip") $redist
$redistRoot = Join-Path $redist $Name
foreach ($path in 'busybox', 'bin/mingw32-make.exe', 'bin/gendef.exe', 'bin/widl.exe') {
  Check (-not (Test-Path (Join-Path $redistRoot $path))) "redistributable contains $path"
}
foreach ($path in 'bin/clang++.exe', 'bin/clang-22.exe', 'bin/ld.lld.exe', 'bin/lldb.exe',
                  'bin/lldb-dap.exe', 'bin/libLLVM-22.dll', 'bin/libc++.dll',
                  'bin/libunwind.dll', 'x86_64-w64-mingw32/lib/libucrt.a',
                  'FSIM-TOOLCHAIN.txt') {
  Check (Test-Path (Join-Path $redistRoot $path)) "redistributable lacks $path"
}
$manifest = Get-Content (Join-Path $redistRoot 'FSIM-TOOLCHAIN.txt') -Raw
Check ($manifest -match 'variant=redist') "redistributable manifest: $manifest"

Write-Host "fsim toolchain tests passed: $Name"
