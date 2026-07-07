param(
    [string]$Experiment = "exp002_4_2_bias_relu_variants",
    [string]$Arch = "86",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$build = Join-Path $root "build"
$expDir = Join-Path $root "experiments\$Experiment"
$results = Join-Path $expDir "results"

if (!(Test-Path $expDir)) {
    Write-Error "Experiment directory not found: $expDir"
    exit 1
}

if (!(Test-Path (Join-Path $expDir "src\main.cu"))) {
    Write-Error "Missing main.cu: $(Join-Path $expDir 'src\main.cu')"
    exit 1
}

if ($Clean -and (Test-Path $build)) {
    Remove-Item -Recurse -Force $build
}

New-Item -ItemType Directory -Force $results | Out-Null

$cmakeConfigureArgs = @(
    "-S", "$root",
    "-B", "$build",
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_CUDA_ARCHITECTURES=$($Arch)",
    "-DSASSSCOPE_EXPERIMENT=$($Experiment)"
)

Write-Host "=== CMake configure ==="
cmake @cmakeConfigureArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "CMake configure failed."
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "=== Build ==="
cmake --build $build --config Release

if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed."
    exit $LASTEXITCODE
}

$exe = Join-Path $build "experiments\$Experiment\$Experiment.exe"

if (!(Test-Path $exe)) {
    Write-Error "Build finished, but executable was not found: $exe"
    exit 1
}

Write-Host ""
Write-Host "Build success"
Write-Host "Experiment: $Experiment"
Write-Host "CUDA arch: $Arch"
Write-Host "Executable: $exe"