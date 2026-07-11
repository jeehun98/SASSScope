param(
    [int]$Arch = 86
)

. (Join-Path $PSScriptRoot "common.ps1")

$root = Get-ProjectRoot
Set-Location $root

Require-Command "cuobjdump" | Out-Null
Require-Command "nvdisasm" | Out-Null
Require-Command "python" | Out-Null

$exePath = Join-Path $root "build/probe_ffma.exe"
$cubinPath = Join-Path $root "build/probe_kernels_sm$Arch.cubin"
$binaryDir = Join-Path $root "results/binary"
Ensure-Directory $binaryDir

if (-not (Test-Path $exePath)) {
    throw "Missing executable. Run scripts/build.ps1 first: $exePath"
}
if (-not (Test-Path $cubinPath)) {
    throw "Missing CUBIN. Run scripts/build.ps1 first: $cubinPath"
}

Invoke-NativeCapture -Command "cuobjdump" -Arguments @("--dump-ptx", $exePath) `
    -OutputPath (Join-Path $binaryDir "probe_ffma.ptx.txt") | Out-Null

Invoke-NativeCapture -Command "cuobjdump" -Arguments @("--dump-sass", $exePath) `
    -OutputPath (Join-Path $binaryDir "probe_ffma_full.sass.txt") | Out-Null

Invoke-NativeCapture -Command "cuobjdump" -Arguments @("--dump-resource-usage", $exePath) `
    -OutputPath (Join-Path $binaryDir "probe_ffma_resource_usage.txt") | Out-Null

Invoke-NativeCapture -Command "nvdisasm" `
    -Arguments @("-c", "-g", "-sf", $cubinPath) `
    -OutputPath (Join-Path $binaryDir "probe_ffma_lineinfo.sass.txt") | Out-Null

Invoke-NativeCapture -Command "nvdisasm" `
    -Arguments @("-c", "-hex", "-plr", "-sf", $cubinPath) `
    -OutputPath (Join-Path $binaryDir "probe_ffma_detailed.sass.txt") | Out-Null

Invoke-NativeCapture -Command "python" `
    -Arguments @(
        (Join-Path $root "tools/analyze_sass.py"),
        "--input",
        (Join-Path $binaryDir "probe_ffma_full.sass.txt"),
        "--output-dir",
        $binaryDir
    ) `
    -OutputPath (Join-Path $binaryDir "sass_analyzer_console.txt") | Out-Null

Write-Host "`nBinary outputs collected in: $binaryDir" -ForegroundColor Green
