param(
    [string]$Experiment = "exp002_4_2_bias_relu_variants",
    [string]$N = "32"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$exe = Join-Path $root "build\experiments\$Experiment\$Experiment.exe"

if (!(Test-Path $exe)) {
    Write-Error "Executable not found: $exe"
    exit 1
}

& $exe $N