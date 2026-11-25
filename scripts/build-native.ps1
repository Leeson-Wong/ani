# 交叉编译 Rust 核心(fqapi_ohos)并拷贝 .so 到 entry/libs
# 用法: powershell -ExecutionPolicy Bypass -File scripts\build-native.ps1 [-Targets "aarch64-unknown-linux-ohos"]
param(
    [string[]]$Targets = @("aarch64-unknown-linux-ohos", "x86_64-unknown-linux-ohos")
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Native = "D:/devtools/Huawei/DevEco Studio/sdk/default/openharmony/native"

$env:CC_aarch64_unknown_linux_ohos = "$Native/llvm/bin/clang.exe"
$env:CXX_aarch64_unknown_linux_ohos = "$Native/llvm/bin/clang++.exe"
$env:AR_aarch64_unknown_linux_ohos = "$Native/llvm/bin/llvm-ar.exe"
$env:CC_x86_64_unknown_linux_ohos = "$Native/llvm/bin/clang.exe"
$env:CXX_x86_64_unknown_linux_ohos = "$Native/llvm/bin/clang++.exe"
$env:AR_x86_64_unknown_linux_ohos = "$Native/llvm/bin/llvm-ar.exe"

foreach ($t in $Targets) {
    $abi = if ($t -eq "aarch64-unknown-linux-ohos") { "arm64-v8a" } else { "x86_64" }
    Write-Host "== cargo build --release --target $t =="
    Push-Location "$Root/rust"
    cargo build --release --target $t -p fqapi_ohos
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed for $t" }
    Pop-Location

    $dest = "$Root/entry/libs/$abi"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item "$Root/rust/target/$t/release/libfqapi_ohos.so" "$dest/libfqapi_ohos.so" -Force
    Write-Host "== copied to $dest/libfqapi_ohos.so =="
}
