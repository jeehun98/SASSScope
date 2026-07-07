param(
    [string]$Experiment = "exp002_4_2_bias_relu_variants"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$exe = Join-Path $root "build\experiments\$Experiment\$Experiment.exe"
$outDir = Join-Path $root "experiments\$Experiment\results"
$out = Join-Path $outDir "resource_usage.txt"

if (!(Test-Path $exe)) {
    Write-Error "Executable not found: $exe"
    exit 1
}

New-Item -ItemType Directory -Force $outDir | Out-Null

cuobjdump --dump-resource-usage $exe | Tee-Object -FilePath $out

Write-Host "`nSaved: $out"