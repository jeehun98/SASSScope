param(
    [ValidateRange(1, 1000000)]
    [int]$Samples = 100,

    [ValidateRange(0, 1000000)]
    [int]$Warmups = 10,

    [ValidateRange(0.000001, 1000000.0)]
    [double]$MinimumRatio = 1.20,

    [ValidateRange(0.0, 10.0)]
    [double]$MaxCv = 0.05,

    [switch]$FailOnWarning,

    # Preserve previous runtime outputs by moving them into a timestamped
    # archive directory. The active output directory is still cleaned so
    # stale files can never be mistaken for newly generated results.
    [switch]$KeepExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$root = Get-ProjectRoot
Set-Location $root

$exePath =
    Join-Path $root "build/probe_ffma.exe"

$analyzerPath =
    Join-Path $root "tools/analyze_runtime.py"

$runtimeDir =
    Join-Path $root "results/runtime"

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

$runtimeRunManifestPath =
    Join-Path $runtimeDir "runtime_run_manifest.json"


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


function Get-RequiredJsonProperty {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$DocumentName
    )

    $property =
        $Object.PSObject.Properties[$Name]

    if ($null -eq $property) {
        throw (
            "$DocumentName is missing required property '$Name'."
        )
    }

    return $property.Value
}


function Get-ArtifactRecord {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Assert-OutputFile `
        -Path $Path `
        -Description "Artifact"

    $file =
        Get-Item `
            -LiteralPath $Path

    $hash =
        Get-FileHash `
            -LiteralPath $Path `
            -Algorithm SHA256

    return [ordered]@{
        path       = $file.FullName
        size_bytes = $file.Length
        sha256     = $hash.Hash.ToLowerInvariant()
    }
}


# -------------------------------------------------------------------------
# Validate inputs and tools
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

$pythonCommandInfo =
    Get-Command `
        "python" `
        -ErrorAction Stop

$pythonCommand =
    if ($pythonCommandInfo.Path) {
        $pythonCommandInfo.Path
    } else {
        $pythonCommandInfo.Source
    }

if ([string]::IsNullOrWhiteSpace($pythonCommand)) {
    throw "Unable to resolve the Python executable."
}


# -------------------------------------------------------------------------
# Remove or archive stale outputs
#
# Even when -KeepExisting is specified, the active output files are moved
# away before execution. This prevents stale output from passing validation.
# -------------------------------------------------------------------------

$generatedPaths = @(
    $runtimeConsolePath
    $runtimeAnalyzerConsolePath
    $runtimeRawPath
    $runtimeSummaryPath
    $runtimeCheckPath
    $metadataPath
    $runtimeRunManifestPath
)

$existingGeneratedPaths =
    @(
        $generatedPaths |
        Where-Object {
            Test-Path `
                -LiteralPath $_ `
                -PathType Leaf
        }
    )

if ($existingGeneratedPaths.Count -gt 0) {
    if ($KeepExisting) {
        $archiveTimestamp =
            Get-Date -Format "yyyyMMdd_HHmmss"

        $archiveDir =
            Join-Path `
                $runtimeDir `
                "archive/$archiveTimestamp"

        Ensure-Directory $archiveDir

        foreach ($path in $existingGeneratedPaths) {
            Move-Item `
                -LiteralPath $path `
                -Destination $archiveDir `
                -Force
        }

        Write-Host ""
        Write-Host (
            "Previous runtime outputs archived to: " +
            $archiveDir
        ) -ForegroundColor DarkYellow
    } else {
        foreach ($path in $existingGeneratedPaths) {
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

$exeHashText =
    $exeHash.Hash.ToLowerInvariant()

Write-Host ""
Write-Host "Running FFMA probe..." -ForegroundColor Cyan
Write-Host "  Executable     : $exePath"
Write-Host "  EXE size       : $($exeFile.Length) bytes"
Write-Host "  EXE SHA-256    : $exeHashText"
Write-Host "  Samples        : $Samples"
Write-Host "  Warmups        : $Warmups"
Write-Host "  Minimum ratio  : $MinimumRatio"
Write-Host "  Maximum CV     : $MaxCv"
Write-Host "  Fail on warning: $FailOnWarning"
Write-Host "  Output dir     : $runtimeDir"


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
# Validate executable outputs
# -------------------------------------------------------------------------

Assert-OutputFile `
    -Path $runtimeConsolePath `
    -Description "Runtime console output"

Assert-OutputFile `
    -Path $runtimeRawPath `
    -Description "Runtime raw CSV"

Assert-OutputFile `
    -Path $runtimeSummaryPath `
    -Description "Runtime summary"

Assert-OutputFile `
    -Path $metadataPath `
    -Description "Runtime metadata"


# -------------------------------------------------------------------------
# Validate CSV schema
# -------------------------------------------------------------------------

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
# Validate basic CSV row count
#
# Each measured run must contain:
#
#   timer_only
#   dependent
#   independent_8
# -------------------------------------------------------------------------

$runtimeRows =
    @(
        Import-Csv `
            -LiteralPath $runtimeRawPath
    )

$expectedRowCount =
    $Samples * 3

if ($runtimeRows.Count -ne $expectedRowCount) {
    throw (
        "runtime_raw.csv contains an unexpected number of rows.`n" +
        "Expected: $expectedRowCount`n" +
        "Actual  : $($runtimeRows.Count)"
    )
}


# -------------------------------------------------------------------------
# Validate metadata produced by main.cu
# -------------------------------------------------------------------------

try {
    $runtimeMetadata =
        Get-Content `
            -LiteralPath $metadataPath `
            -Raw |
        ConvertFrom-Json
} catch {
    throw (
        "Failed to parse runtime metadata JSON: " +
        "$metadataPath`n$($_.Exception.Message)"
    )
}

$metadataSamples =
    [int](
        Get-RequiredJsonProperty `
            -Object $runtimeMetadata `
            -Name "samples" `
            -DocumentName "metadata.json"
    )

$metadataWarmups =
    [int](
        Get-RequiredJsonProperty `
            -Object $runtimeMetadata `
            -Name "warmups" `
            -DocumentName "metadata.json"
    )

$metadataDynamicFfmaCount =
    [long](
        Get-RequiredJsonProperty `
            -Object $runtimeMetadata `
            -Name "dynamic_ffma_count" `
            -DocumentName "metadata.json"
    )

$metadataExecutionOrderPolicy =
    [string](
        Get-RequiredJsonProperty `
            -Object $runtimeMetadata `
            -Name "execution_order_policy" `
            -DocumentName "metadata.json"
    )

$metadataCsvRowOrder =
    [string](
        Get-RequiredJsonProperty `
            -Object $runtimeMetadata `
            -Name "csv_row_order" `
            -DocumentName "metadata.json"
    )

$metadataDependentFirstRuns =
    [int](
        Get-RequiredJsonProperty `
            -Object $runtimeMetadata `
            -Name "dependent_first_runs" `
            -DocumentName "metadata.json"
    )

$metadataIndependentFirstRuns =
    [int](
        Get-RequiredJsonProperty `
            -Object $runtimeMetadata `
            -Name "independent_first_runs" `
            -DocumentName "metadata.json"
    )

if ($metadataSamples -ne $Samples) {
    throw (
        "metadata.json samples mismatch.`n" +
        "Requested: $Samples`n" +
        "Metadata : $metadataSamples"
    )
}

if ($metadataWarmups -ne $Warmups) {
    throw (
        "metadata.json warmups mismatch.`n" +
        "Requested: $Warmups`n" +
        "Metadata : $metadataWarmups"
    )
}

if ($metadataDynamicFfmaCount -le 0) {
    throw (
        "metadata.json dynamic_ffma_count must be positive. " +
        "Found: $metadataDynamicFfmaCount"
    )
}

$expectedExecutionOrderPolicy =
    "timer_first_then_alternating_ffma_by_run_parity"

if (
    $metadataExecutionOrderPolicy `
        -ne $expectedExecutionOrderPolicy
) {
    throw (
        "Unexpected execution_order_policy in metadata.json.`n" +
        "Expected: $expectedExecutionOrderPolicy`n" +
        "Actual  : $metadataExecutionOrderPolicy"
    )
}

$expectedCsvRowOrder =
    "actual_kernel_launch_order"

if ($metadataCsvRowOrder -ne $expectedCsvRowOrder) {
    throw (
        "Unexpected csv_row_order in metadata.json.`n" +
        "Expected: $expectedCsvRowOrder`n" +
        "Actual  : $metadataCsvRowOrder"
    )
}

$expectedDependentFirstRuns =
    [int][Math]::Ceiling(
        [double]$Samples / 2.0
    )

$expectedIndependentFirstRuns =
    [int][Math]::Floor(
        [double]$Samples / 2.0
    )

if (
    $metadataDependentFirstRuns `
        -ne $expectedDependentFirstRuns
) {
    throw (
        "metadata.json dependent_first_runs mismatch.`n" +
        "Expected: $expectedDependentFirstRuns`n" +
        "Actual  : $metadataDependentFirstRuns"
    )
}

if (
    $metadataIndependentFirstRuns `
        -ne $expectedIndependentFirstRuns
) {
    throw (
        "metadata.json independent_first_runs mismatch.`n" +
        "Expected: $expectedIndependentFirstRuns`n" +
        "Actual  : $metadataIndependentFirstRuns"
    )
}


# -------------------------------------------------------------------------
# Analyze runtime results
# -------------------------------------------------------------------------

Write-Host ""
Write-Host "Analyzing runtime samples..." -ForegroundColor Cyan

$invariantCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

$minimumRatioText =
    $MinimumRatio.ToString(
        "G17",
        $invariantCulture
    )

$maxCvText =
    $MaxCv.ToString(
        "G17",
        $invariantCulture
    )

$analyzerArguments = @(
    $analyzerPath
    "--input"
    $runtimeRawPath
    "--output"
    $runtimeCheckPath
    "--expected-samples"
    [string]$Samples
    "--minimum-ratio"
    $minimumRatioText
    "--max-cv"
    $maxCvText
)

if ($FailOnWarning) {
    $analyzerArguments +=
        "--fail-on-warning"
}

Invoke-NativeCapture `
    -Command $pythonCommand `
    -Arguments $analyzerArguments `
    -OutputPath $runtimeAnalyzerConsolePath |
    Out-Null

Assert-OutputFile `
    -Path $runtimeAnalyzerConsolePath `
    -Description "Runtime analyzer console output"

Assert-OutputFile `
    -Path $runtimeCheckPath `
    -Description "Runtime validation report"


# -------------------------------------------------------------------------
# Read analyzer status
# -------------------------------------------------------------------------

$statusMatch =
    Select-String `
        -LiteralPath $runtimeCheckPath `
        -Pattern "^\s*status\s*:\s*(\S+)\s*$" |
    Select-Object -First 1

$validationStatus =
    if (
        $null -ne $statusMatch -and
        $statusMatch.Matches.Count -gt 0
    ) {
        $statusMatch.Matches[0].Groups[1].Value.ToUpperInvariant()
    } else {
        "UNKNOWN"
    }

if (
    $validationStatus -notin @(
        "PASS"
        "WARN"
    )
) {
    throw (
        "Unexpected runtime analyzer status: " +
        "$validationStatus"
    )
}


# -------------------------------------------------------------------------
# Write runtime execution manifest
# -------------------------------------------------------------------------

$runtimeRunManifest = [ordered]@{
    schema_version = 1
    generated_at   = (Get-Date).ToString("o")

    configuration = [ordered]@{
        samples         = $Samples
        warmups         = $Warmups
        minimum_ratio   = $MinimumRatio
        maximum_cv      = $MaxCv
        fail_on_warning = [bool]$FailOnWarning
    }

    executable = [ordered]@{
        path       = $exeFile.FullName
        size_bytes = $exeFile.Length
        sha256     = $exeHashText
    }

    runtime_metadata = [ordered]@{
        dynamic_ffma_count      = $metadataDynamicFfmaCount
        execution_order_policy  = $metadataExecutionOrderPolicy
        csv_row_order           = $metadataCsvRowOrder
        dependent_first_runs    = $metadataDependentFirstRuns
        independent_first_runs  = $metadataIndependentFirstRuns
    }

    analyzer = [ordered]@{
        python_path = $pythonCommand
        script_path = $analyzerPath
        status      = $validationStatus
        arguments   = $analyzerArguments
    }

    outputs = [ordered]@{
        runtime_console =
            Get-ArtifactRecord $runtimeConsolePath

        runtime_raw =
            Get-ArtifactRecord $runtimeRawPath

        runtime_summary =
            Get-ArtifactRecord $runtimeSummaryPath

        runtime_check =
            Get-ArtifactRecord $runtimeCheckPath

        runtime_analyzer_console =
            Get-ArtifactRecord $runtimeAnalyzerConsolePath

        metadata =
            Get-ArtifactRecord $metadataPath
    }
}

$runtimeRunManifest |
    ConvertTo-Json -Depth 10 |
    Set-Content `
        -LiteralPath $runtimeRunManifestPath `
        -Encoding UTF8

Assert-OutputFile `
    -Path $runtimeRunManifestPath `
    -Description "Runtime run manifest"


# -------------------------------------------------------------------------
# Final report
# -------------------------------------------------------------------------

$finalColor =
    if ($validationStatus -eq "PASS") {
        "Green"
    } else {
        "Yellow"
    }

Write-Host ""
Write-Host (
    "Runtime outputs collected successfully. " +
    "Validation status: $validationStatus"
) -ForegroundColor $finalColor

Write-Host "  Samples             : $Samples"
Write-Host "  Warmups             : $Warmups"
Write-Host "  Dynamic FFMA/probe  : $metadataDynamicFfmaCount"
Write-Host "  Dependent first     : $metadataDependentFirstRuns"
Write-Host "  Independent first   : $metadataIndependentFirstRuns"
Write-Host "  Runtime executable  : $exePath"
Write-Host "  EXE SHA-256         : $exeHashText"
Write-Host "  Raw CSV             : $runtimeRawPath"
Write-Host "  Runtime summary     : $runtimeSummaryPath"
Write-Host "  Runtime validation  : $runtimeCheckPath"
Write-Host "  Runtime metadata    : $metadataPath"
Write-Host "  Runtime manifest    : $runtimeRunManifestPath"
Write-Host "  Runtime console     : $runtimeConsolePath"
Write-Host "  Analyzer console    : $runtimeAnalyzerConsolePath"