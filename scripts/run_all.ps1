param(
    [int]$Arch = 86,
    [int]$Samples = 100,
    [int]$Warmups = 10,
    [switch]$Clean,
    [switch]$WithNcu
)

$ErrorActionPreference = "Stop"

& (Join-Path $PSScriptRoot "check_tools.ps1")
& (Join-Path $PSScriptRoot "build.ps1") -Arch $Arch -Clean:$Clean
& (Join-Path $PSScriptRoot "collect_binary_outputs.ps1") -Arch $Arch
& (Join-Path $PSScriptRoot "run_probe.ps1") -Samples $Samples -Warmups $Warmups

if ($WithNcu) {
    & (Join-Path $PSScriptRoot "profile_ncu.ps1")
}

Write-Host "`nAll requested stages completed." -ForegroundColor Green
