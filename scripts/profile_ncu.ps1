param()

. (Join-Path $PSScriptRoot "common.ps1")

$root = Get-ProjectRoot
Set-Location $root

Require-Command "ncu" | Out-Null

$exePath = Join-Path $root "build/probe_ffma.exe"
$profilerDir = Join-Path $root "results/profiler"
$profileRuntimeDir = Join-Path $profilerDir "runtime"
Ensure-Directory $profilerDir
Ensure-Directory $profileRuntimeDir

if (-not (Test-Path $exePath)) {
    throw "Missing executable. Run scripts/build.ps1 first: $exePath"
}

$reportBase = Join-Path $profilerDir "probe_ffma_profile"
$reportPath = "$reportBase.ncu-rep"

Invoke-NativeCapture -Command "ncu" `
    -Arguments @(
        "--set", "full",
        "--export", $reportBase,
        "--force-overwrite",
        $exePath,
        $profileRuntimeDir,
        "1",
        "0"
    ) `
    -OutputPath (Join-Path $profilerDir "ncu_collect_console.txt") | Out-Null

if (-not (Test-Path $reportPath)) {
    throw "Nsight Compute report was not generated: $reportPath"
}

Invoke-NativeCapture -Command "ncu" `
    -Arguments @("--import", $reportPath, "--page", "raw", "--csv") `
    -OutputPath (Join-Path $profilerDir "probe_ffma_ncu_raw.csv") | Out-Null

Invoke-NativeCapture -Command "ncu" `
    -Arguments @(
        "--import", $reportPath,
        "--page", "source",
        "--print-source", "sass"
    ) `
    -OutputPath (Join-Path $profilerDir "probe_ffma_ncu_sass.txt") | Out-Null

Write-Host "`nNsight Compute outputs collected in: $profilerDir" -ForegroundColor Green
