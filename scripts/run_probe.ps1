param(
    [ValidateRange(1, 1000000)]
    [int]$Samples = 100,

    [ValidateRange(0, 1000000)]
    [int]$Warmups = 10,

    [switch]$KeepExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$root = Get-ProjectRoot
Set-Location $root

$exePath = Join-Path $root "build/probe_ffma.exe"
$analyzerPath = Join-Path $root "tools/analyze_runtime.py"

$runtimeDir = Join-Path $root "results/runtime"
Ensure-Directory $runtimeDir

$runtimeConsolePath =
    Join-Path $runtimeDir "runtime_console.txt"

$runtimeAnalyzerConsolePath =
    Join-Path $runtimeDir "runtime_analyzer_console.txt"

$runtimeRawPath =
    Join-Path $runtimeDir "runtime_raw.csv"

$runtimeSummaryPath =
    Join-Path $runtimeDir "runtime_summary.txt"

$runtimeCheckPath =
    Join-Path $runtimeDir "runtime_check.txt"

$metadataPath =
    Join-Path $runtimeDir "metadata.json"


function Assert-OutputFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    if (
        -not (
            Test-Path `
                -LiteralPath $Path `
                -PathType Leaf
        )
    ) {
        throw (
            "$Description was not generated: $Path"
        )
    }

    $fileInfo =
        Get-Item `
            -LiteralPath $Path

    if ($fileInfo.Length -le 0) {
        throw (
            "$Description is empty: $Path"
        )
    }
}


# -------------------------------------------------------------------------
# Validate inputs
# -------------------------------------------------------------------------

if (
    -not (
        Test-Path `
            -LiteralPath $exePath `
            -PathType Leaf
    )
) {
    throw (
        "Missing runtime executable. " +
        "Run scripts/build.ps1 first: $exePath"
    )
}

if (
    -not (
        Test-Path `
            -LiteralPath $analyzerPath `
            -PathType Leaf
    )
) {
    throw (
        "Missing runtime analyzer: $analyzerPath"
    )
}


# -------------------------------------------------------------------------
# Remove stale outputs
#
# A stale runtime_raw.csv must never be reused after a failed executable run.
# -------------------------------------------------------------------------

$generatedPaths = @(
    $runtimeConsolePath
    $runtimeAnalyzerConsolePath
    $runtimeRawPath
    $runtimeSummaryPath
    $runtimeCheckPath
    $metadataPath
)

if (-not $KeepExisting) {
    foreach ($path in $generatedPaths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item `
                -LiteralPath $path `
                -Force
        }
    }
}


# -------------------------------------------------------------------------
# Record executable identity before execution
# -------------------------------------------------------------------------

$exeFile =
    Get-Item `
        -LiteralPath $exePath

$exeHash =
    Get-FileHash `
        -LiteralPath $exePath `
        -Algorithm SHA256


Write-Host ""
Write-Host "Running FFMA probe..." -ForegroundColor Cyan
Write-Host "  Executable : $exePath"
Write-Host "  EXE size   : $($exeFile.Length) bytes"
Write-Host "  EXE SHA-256: $($exeHash.Hash.ToLowerInvariant())"
Write-Host "  Samples    : $Samples"
Write-Host "  Warmups    : $Warmups"
Write-Host "  Output dir : $runtimeDir"


# -------------------------------------------------------------------------
# Execute the runtime probe
#
# Expected executable arguments:
#
#   probe_ffma.exe <output-directory> <samples> <warmups>
# -------------------------------------------------------------------------

Invoke-NativeCapture `
    -Command $exePath `
    -Arguments @(
        $runtimeDir
        [string]$Samples
        [string]$Warmups
    ) `
    -OutputPath $runtimeConsolePath |
    Out-Null


# -------------------------------------------------------------------------
# Validate runtime outputs before running the Python analyzer
# -------------------------------------------------------------------------

Assert-OutputFile `
    -Path $runtimeRawPath `
    -Description "Runtime raw CSV"

Assert-OutputFile `
    -Path $runtimeSummaryPath `
    -Description "Runtime summary"

Assert-OutputFile `
    -Path $metadataPath `
    -Description "Runtime metadata"


# Check the CSV header early so renamed or stale schemas fail clearly.
$runtimeCsvHeader =
    Get-Content `
        -LiteralPath $runtimeRawPath `
        -TotalCount 1

$requiredCsvColumns = @(
    "run"
    "kernel"
    "dynamic_ffma_count"
    "total_cycles"
    "cycles_per_ffma"
    "checksum"
)

$actualCsvColumns =
    @(
        $runtimeCsvHeader -split "," |
        ForEach-Object {
            $_.Trim().Trim('"')
        }
    )

$missingCsvColumns =
    @(
        $requiredCsvColumns |
        Where-Object {
            $_ -notin $actualCsvColumns
        }
    )

if ($missingCsvColumns.Count -gt 0) {
    throw (
        "runtime_raw.csv does not match the expected schema.`n" +
        "Missing columns: " +
        ($missingCsvColumns -join ", ") +
        "`nActual header: $runtimeCsvHeader"
    )
}


# -------------------------------------------------------------------------
# Analyze runtime results
# -------------------------------------------------------------------------

Write-Host ""
Write-Host "Analyzing runtime samples..." -ForegroundColor Cyan

Invoke-NativeCapture `
    -Command "python" `
    -Arguments @(
        $analyzerPath
        "--input"
        $runtimeRawPath
        "--output"
        $runtimeCheckPath
    ) `
    -OutputPath $runtimeAnalyzerConsolePath |
    Out-Null

Assert-OutputFile `
    -Path $runtimeCheckPath `
    -Description "Runtime validation report"


# -------------------------------------------------------------------------
# Final report
# -------------------------------------------------------------------------

Write-Host ""
Write-Host "Runtime outputs collected successfully." `
    -ForegroundColor Green

Write-Host "  Samples             : $Samples"
Write-Host "  Warmups             : $Warmups"
Write-Host "  Runtime executable  : $exePath"
Write-Host "  Raw CSV             : $runtimeRawPath"
Write-Host "  Runtime summary     : $runtimeSummaryPath"
Write-Host "  Runtime validation  : $runtimeCheckPath"
Write-Host "  Runtime metadata    : $metadataPath"
Write-Host "  Runtime console     : $runtimeConsolePath"
Write-Host "  Analyzer console    : $runtimeAnalyzerConsolePath"