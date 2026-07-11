param(
    [int]$Samples = 100,
    [int]$Warmups = 10
)

. (Join-Path $PSScriptRoot "common.ps1")

$root = Get-ProjectRoot
Set-Location $root

$exePath = Join-Path $root "build/probe_ffma.exe"
$runtimeDir = Join-Path $root "results/runtime"
Ensure-Directory $runtimeDir

if (-not (Test-Path $exePath)) {
    throw "Missing executable. Run scripts/build.ps1 first: $exePath"
}

Invoke-NativeCapture -Command $exePath `
    -Arguments @($runtimeDir, [string]$Samples, [string]$Warmups) `
    -OutputPath (Join-Path $runtimeDir "runtime_console.txt") | Out-Null

Invoke-NativeCapture -Command "python" `
    -Arguments @(
        (Join-Path $root "tools/analyze_runtime.py"),
        "--input",
        (Join-Path $runtimeDir "runtime_raw.csv"),
        "--output",
        (Join-Path $runtimeDir "runtime_check.txt")
    ) `
    -OutputPath (Join-Path $runtimeDir "runtime_analyzer_console.txt") | Out-Null

Write-Host "`nRuntime outputs collected in: $runtimeDir" -ForegroundColor Green
