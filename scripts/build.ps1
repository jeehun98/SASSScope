param(
    [ValidateRange(50, 999)]
    [int]$Arch = 86,

    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$commonPath = Join-Path $PSScriptRoot "common.ps1"

if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "common.ps1 was not found: $commonPath"
}

. $commonPath

$root = Get-ProjectRoot
Push-Location $root

try {
    Require-Command "nvcc" | Out-Null

    $buildDir = Join-Path $root "build"
    $resultDir = Join-Path $root "results/build"

    $includeDir = Join-Path $root "include"
    $headerPath = Join-Path $includeDir "probe_kernels.cuh"
    $mainSource = Join-Path $root "src/main.cu"
    $kernelSource = Join-Path $root "src/probe_kernels.cu"

    $exePath = Join-Path $buildDir "probe_ffma.exe"
    $buildLog = Join-Path $resultDir "probe_ffma_build.txt"

    foreach ($path in @($headerPath, $mainSource, $kernelSource)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required source file was not found: $path"
        }
    }

    if ($Clean -and (Test-Path -LiteralPath $buildDir)) {
        Remove-Item -LiteralPath $buildDir -Recurse -Force
    }

    Ensure-Directory $buildDir
    Ensure-Directory $resultDir

    # Prevent an old executable from surviving a failed build.
    Remove-Item -LiteralPath $exePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $buildLog -Force -ErrorAction SilentlyContinue

    $arguments = @(
        "-std=c++17"
        "-O3"
        "--fmad=true"
        "-gencode=arch=compute_$Arch,code=sm_$Arch"
        "-Xptxas=-v"
        "-I$includeDir"
        "-Xcompiler=/utf-8"
        "-Xcompiler=/EHsc"
        $mainSource
        $kernelSource
        "-o"
        $exePath
    )

    Invoke-NativeCapture `
        -Command "nvcc" `
        -Arguments $arguments `
        -OutputPath $buildLog |
        Out-Null

    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "Executable was not generated: $exePath"
    }

    if ((Get-Item -LiteralPath $exePath).Length -eq 0) {
        throw "Executable is empty: $exePath"
    }

    Write-Host "`nBuild completed." -ForegroundColor Green
    Write-Host "  Architecture : sm_$Arch"
    Write-Host "  Executable   : $exePath"
    Write-Host "  Build log    : $buildLog"
}
finally {
    Pop-Location
}