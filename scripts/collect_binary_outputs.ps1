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

function Assert-NonEmptyFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not found: $Path"
    }

    if ((Get-Item -LiteralPath $Path).Length -eq 0) {
        throw "$Description is empty: $Path"
    }
}

$root = Get-ProjectRoot
Push-Location $root

try {
    Require-Command "cuobjdump" | Out-Null
    Require-Command "python" | Out-Null

    $exePath = Join-Path $root "build/probe_ffma.exe"
    $analyzerPath = Join-Path $root "tools/analyze_sass.py"
    $binaryDir = Join-Path $root "results/binary"

    $canonicalSassPath =
        Join-Path $binaryDir "probe_ffma_full.sass.txt"

    $summaryJsonPath =
        Join-Path $binaryDir "sass_summary.json"

    # Retained only when analysis fails; removed after success.
    $analyzerConsolePath =
        Join-Path $binaryDir "sass_analyzer_console.txt"

    Assert-NonEmptyFile `
        -Path $exePath `
        -Description "Runtime executable"

    Assert-NonEmptyFile `
        -Path $analyzerPath `
        -Description "SASS analyzer"

    if ($Clean -and (Test-Path -LiteralPath $binaryDir)) {
        Remove-Item `
            -LiteralPath $binaryDir `
            -Recurse `
            -Force
    }

    Ensure-Directory $binaryDir

    # Prevent stale outputs from being mistaken for the current analysis.
    foreach ($path in @(
        $canonicalSassPath,
        $summaryJsonPath,
        $analyzerConsolePath
    )) {
        Remove-Item `
            -LiteralPath $path `
            -Force `
            -ErrorAction SilentlyContinue
    }

    # Canonical machine code: extracted directly from the executable that
    # run_probe.ps1 executes.
    Invoke-NativeCapture `
        -Command "cuobjdump" `
        -Arguments @(
            "--dump-sass"
            "--gpu-architecture"
            "sm_$Arch"
            $exePath
        ) `
        -OutputPath $canonicalSassPath |
        Out-Null

    Assert-NonEmptyFile `
        -Path $canonicalSassPath `
        -Description "Canonical runtime SASS"

    $requiredKernelNames = @(
        "probe_timer_only"
        "probe_dependent_ffma"
        "probe_independent_ffma_8"
    )

    foreach ($kernelName in $requiredKernelNames) {
        if (-not (
            Select-String `
                -LiteralPath $canonicalSassPath `
                -SimpleMatch `
                -Pattern $kernelName `
                -Quiet
        )) {
            throw "Kernel was not found in canonical SASS: $kernelName"
        }
    }

    Invoke-NativeCapture `
        -Command "python" `
        -Arguments @(
            $analyzerPath
            "--input"
            $canonicalSassPath
            "--output-dir"
            $binaryDir
        ) `
        -OutputPath $analyzerConsolePath |
        Out-Null

    Assert-NonEmptyFile `
        -Path $summaryJsonPath `
        -Description "SASS JSON summary"

    Remove-Item `
        -LiteralPath $analyzerConsolePath `
        -Force `
        -ErrorAction SilentlyContinue

    Write-Host "`nBinary analysis completed." -ForegroundColor Green
    Write-Host "  Architecture  : sm_$Arch"
    Write-Host "  Canonical SASS: $canonicalSassPath"
    Write-Host "  JSON summary  : $summaryJsonPath"
}
finally {
    Pop-Location
}
