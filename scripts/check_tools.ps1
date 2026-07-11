param()

. (Join-Path $PSScriptRoot "common.ps1")

$root = Get-ProjectRoot
$environmentDir = Join-Path $root "results/environment"
Ensure-Directory $environmentDir

$required = @(
    "nvcc",
    "cuobjdump",
    "nvdisasm",
    "python"
)

foreach ($tool in $required) {
    $path = Require-Command $tool
    Write-Host "$tool -> $path"
}

$cl = Get-Command "cl.exe" -ErrorAction SilentlyContinue

if ($null -eq $cl) {
    Write-Warning @"
cl.exe is not currently in PATH.
On Windows, run this project from "x64 Native Tools Command Prompt for VS 2022"
or a PowerShell session initialized by VsDevCmd.bat if nvcc reports that it
cannot find the host compiler.
"@
}
else {
    Write-Host "cl.exe -> $($cl.Source)"
}

Invoke-NativeCapture `
    -Command "nvcc" `
    -Arguments @("--version") `
    -OutputPath (Join-Path $environmentDir "nvcc_version.txt") |
    Out-Null

Invoke-NativeCapture `
    -Command "cuobjdump" `
    -Arguments @("--version") `
    -OutputPath (Join-Path $environmentDir "cuobjdump_version.txt") |
    Out-Null

Invoke-NativeCapture `
    -Command "nvdisasm" `
    -Arguments @("--version") `
    -OutputPath (Join-Path $environmentDir "nvdisasm_version.txt") |
    Out-Null

Invoke-NativeCapture `
    -Command "python" `
    -Arguments @("--version") `
    -OutputPath (Join-Path $environmentDir "python_version.txt") |
    Out-Null

$nvidiaSmi = Require-Command "nvidia-smi" -Optional

if ($null -ne $nvidiaSmi) {
    Invoke-NativeCapture `
        -Command "nvidia-smi" `
        -OutputPath (Join-Path $environmentDir "gpu_environment.txt") |
        Out-Null
}
else {
    Write-Warning "nvidia-smi was not found. GPU environment information was not collected."
}

$ncu = Require-Command "ncu" -Optional

if ($null -ne $ncu) {
    Invoke-NativeCapture `
        -Command "ncu" `
        -Arguments @("--version") `
        -OutputPath (Join-Path $environmentDir "ncu_version.txt") |
        Out-Null
}
else {
    Write-Warning "ncu was not found. Nsight Compute version information was not collected."
}

Write-Host "`nTool check completed." -ForegroundColor Green
Write-Host "Environment files: $environmentDir"