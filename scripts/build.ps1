param(
    [int]$Arch = 86,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

$commonPath = Join-Path $PSScriptRoot "common.ps1"

if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "common.ps1 was not found: $commonPath"
}

. $commonPath

$root = Get-ProjectRoot
Set-Location $root

Require-Command "nvcc" | Out-Null

$buildDir = Join-Path $root "build"
$resultBuildDir = Join-Path $root "results/build"

Ensure-Directory $buildDir
Ensure-Directory $resultBuildDir

if ($Clean) {
    Write-Host "Cleaning build directory: $buildDir"

    Get-ChildItem `
        -LiteralPath $buildDir `
        -Force `
        -ErrorAction SilentlyContinue |
        Remove-Item -Force -Recurse
}

$exePath = Join-Path $buildDir "probe_ffma.exe"
$cubinPath = Join-Path $buildDir "probe_kernels_sm$Arch.cubin"

$includeDir = Join-Path $root "include"
$mainSource = Join-Path $root "src/main.cu"
$kernelSource = Join-Path $root "src/probe_kernels.cu"

if (-not (Test-Path -LiteralPath $mainSource -PathType Leaf)) {
    throw "Source file was not found: $mainSource"
}

if (-not (Test-Path -LiteralPath $kernelSource -PathType Leaf)) {
    throw "Source file was not found: $kernelSource"
}

if (-not (Test-Path -LiteralPath $includeDir -PathType Container)) {
    throw "Include directory was not found: $includeDir"
}

$commonArguments = @(
    "-std=c++17"
    "-O3"
    "-lineinfo"

    # MSVC가 CUDA 헤더와 프로젝트 소스를 UTF-8로 해석하게 한다.
    "-Xcompiler=/utf-8"

    # ptxas의 레지스터 및 메모리 사용 정보를 출력한다.
    "-Xptxas=-v"

    "-arch=sm_$Arch"
    "-I$includeDir"
)

$exeArguments = $commonArguments + @(
    $mainSource
    $kernelSource
    "-o"
    $exePath
)

Invoke-NativeCapture `
    -Command "nvcc" `
    -Arguments $exeArguments `
    -OutputPath (Join-Path $resultBuildDir "probe_ffma_build.txt") |
    Out-Null

$cubinArguments = $commonArguments + @(
    "--cubin"
    $kernelSource
    "-o"
    $cubinPath
)

Invoke-NativeCapture `
    -Command "nvcc" `
    -Arguments $cubinArguments `
    -OutputPath (Join-Path $resultBuildDir "probe_kernels_cubin_build.txt") |
    Out-Null

if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "Executable was not generated: $exePath"
}

if (-not (Test-Path -LiteralPath $cubinPath -PathType Leaf)) {
    throw "CUBIN was not generated: $cubinPath"
}

$exeInfo = Get-Item -LiteralPath $exePath
$cubinInfo = Get-Item -LiteralPath $cubinPath

Write-Host "`nBuild completed." -ForegroundColor Green
Write-Host "  Architecture : sm_$Arch"
Write-Host "  EXE          : $exePath"
Write-Host "  EXE size     : $($exeInfo.Length) bytes"
Write-Host "  CUBIN        : $cubinPath"
Write-Host "  CUBIN size   : $($cubinInfo.Length) bytes"
Write-Host "  Build logs   : $resultBuildDir"
