param(
    # First fixture for establishing the profiling process.
    [ValidateNotNullOrEmpty()]
    [string]$KernelName = "probe_timer_only",

    # Basic:
    #   Default section set. Used to verify report generation and filtering.
    #
    # Source:
    #   Basic set plus SourceCounters.
    #
    # Full:
    #   Full predefined set. Use only after Basic and Source are working.
    [ValidateSet("Basic", "Source", "Full")]
    [string]$CollectionMode = "Basic",

    # The target executable receives:
    #
    #   probe_ffma.exe <output-dir> <samples> <warmups>
    #
    # One sample and zero warmups make kernel selection easiest to verify.
    [ValidateRange(1, 1000000)]
    [int]$Samples = 1,

    [ValidateRange(0, 1000000)]
    [int]$Warmups = 0,

    # Explicitly record the clock-control policy used during profiling.
    [ValidateSet("base", "boost", "none")]
    [string]$ClockControl = "base",

    # Preserve the existing active capture by moving it into an archive.
    [switch]$KeepExisting,

    # Querying all available metric base names can create a large file.
    [switch]$SkipMetricQuery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")


# =========================================================================
# Paths
# =========================================================================

$root = Get-ProjectRoot
Set-Location $root

Require-Command "ncu" | Out-Null

$ncuCommandInfo =
    Get-Command `
        "ncu" `
        -ErrorAction Stop

$ncuPath =
    if (
        $null -ne $ncuCommandInfo.Path -and
        -not [string]::IsNullOrWhiteSpace(
            $ncuCommandInfo.Path
        )
    ) {
        $ncuCommandInfo.Path
    } else {
        $ncuCommandInfo.Source
    }

if ([string]::IsNullOrWhiteSpace($ncuPath)) {
    throw "Unable to resolve the Nsight Compute CLI path."
}

$exePath =
    Join-Path $root "build/probe_ffma.exe"

$srcDir =
    Join-Path $root "src"

$includeDir =
    Join-Path $root "include"

$profilerDir =
    Join-Path $root "results/profiler"

$environmentDir =
    Join-Path $profilerDir "environment"

$captureRoot =
    Join-Path $profilerDir "captures"

$archiveRoot =
    Join-Path $profilerDir "archive"

Ensure-Directory $profilerDir
Ensure-Directory $environmentDir
Ensure-Directory $captureRoot
Ensure-Directory $archiveRoot

$safeKernelName =
    $KernelName -replace '[^A-Za-z0-9_.-]', '_'

$modeName =
    $CollectionMode.ToLowerInvariant()

$kernelCaptureRoot =
    Join-Path $captureRoot $safeKernelName

$captureDir =
    Join-Path $kernelCaptureRoot $modeName

$profileRuntimeDir =
    Join-Path $captureDir "runtime"

$reportBase =
    Join-Path $captureDir "profile"

$reportPath =
    "$reportBase.ncu-rep"

$captureConsolePath =
    Join-Path $captureDir "capture_console.txt"

$detailsTextPath =
    Join-Path $captureDir "details.txt"

$detailsCsvPath =
    Join-Path $captureDir "details.csv"

$rawCsvPath =
    Join-Path $captureDir "raw.csv"

$sourceSassTextPath =
    Join-Path $captureDir "source_sass.txt"

$sourceSassCsvPath =
    Join-Path $captureDir "source_sass.csv"

$sourceCudaSassTextPath =
    Join-Path $captureDir "source_cuda_sass.txt"

$sourceCudaSassCsvPath =
    Join-Path $captureDir "source_cuda_sass.csv"

$sessionTextPath =
    Join-Path $captureDir "session.txt"

$activeMetricsPath =
    Join-Path $captureDir "active_metrics.txt"

$captureManifestPath =
    Join-Path $captureDir "capture_manifest.json"

$ncuVersionPath =
    Join-Path $environmentDir "ncu_version.txt"

$ncuHelpPath =
    Join-Path $environmentDir "ncu_help.txt"

$ncuSetsPath =
    Join-Path $environmentDir "ncu_sets.txt"

$ncuSectionsPath =
    Join-Path $environmentDir "ncu_sections.txt"

$ncuMetricsPath =
    Join-Path $environmentDir "ncu_metrics.txt"

$gpuInfoPath =
    Join-Path $environmentDir "gpu_info.txt"


# =========================================================================
# Helpers
# =========================================================================

function Assert-ProfilerFile {
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
        throw "$Description was not generated: $Path"
    }

    $fileInfo =
        Get-Item `
            -LiteralPath $Path

    if ($fileInfo.Length -le 0) {
        throw "$Description is empty: $Path"
    }
}


function Get-ProfilerArtifactRecord {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Assert-ProfilerFile `
        -Path $Path `
        -Description "Profiler artifact"

    $fileInfo =
        Get-Item `
            -LiteralPath $Path

    $hash =
        Get-FileHash `
            -LiteralPath $Path `
            -Algorithm SHA256

    return [ordered]@{
        path       = $fileInfo.FullName
        size_bytes = $fileInfo.Length
        sha256     = $hash.Hash.ToLowerInvariant()
    }
}


function Invoke-NcuCaptureToFile {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$Description
    )

    Invoke-NativeCapture `
        -Command $ncuPath `
        -Arguments $Arguments `
        -OutputPath $OutputPath |
        Out-Null

    Assert-ProfilerFile `
        -Path $OutputPath `
        -Description $Description
}


function Invoke-NcuImportToFile {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $fullArguments =
        @(
            "--import"
            $reportPath
        ) + $Arguments

    Invoke-NcuCaptureToFile `
        -Arguments $fullArguments `
        -OutputPath $OutputPath `
        -Description $Description
}


$warnings =
    [System.Collections.Generic.List[string]]::new()


function Invoke-OptionalNcuToFile {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$Description
    )

    try {
        Invoke-NcuCaptureToFile `
            -Arguments $Arguments `
            -OutputPath $OutputPath `
            -Description $Description

        return $true
    } catch {
        $message =
            "$Description failed: $($_.Exception.Message)"

        $warnings.Add($message) |
            Out-Null

        $failureText = @(
            "OPTIONAL NCU STEP FAILED"
            ""
            "Description: $Description"
            "Command    : $ncuPath"
            "Arguments  : $($Arguments -join ' ')"
            ""
            $message
        )

        $failureText |
            Set-Content `
                -LiteralPath $OutputPath `
                -Encoding UTF8

        return $false
    }
}


function Invoke-OptionalNcuImportToFile {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $fullArguments =
        @(
            "--import"
            $reportPath
        ) + $Arguments

    return Invoke-OptionalNcuToFile `
        -Arguments $fullArguments `
        -OutputPath $OutputPath `
        -Description $Description
}


function Test-TextFileContains {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [switch]$SimpleMatch
    )

    if (
        -not (
            Test-Path `
                -LiteralPath $Path `
                -PathType Leaf
        )
    ) {
        return $false
    }

    if ($SimpleMatch) {
        return [bool](
            Select-String `
                -LiteralPath $Path `
                -Pattern $Pattern `
                -SimpleMatch `
                -Quiet
        )
    }

    return [bool](
        Select-String `
            -LiteralPath $Path `
            -Pattern $Pattern `
            -Quiet
    )
}


# =========================================================================
# Validate inputs
# =========================================================================

if (
    -not (
        Test-Path `
            -LiteralPath $exePath `
            -PathType Leaf
    )
) {
    throw (
        "Missing executable. Run scripts/build.ps1 first: " +
        $exePath
    )
}

if (
    -not (
        Test-Path `
            -LiteralPath $srcDir `
            -PathType Container
    )
) {
    throw "Missing source directory: $srcDir"
}

if (
    -not (
        Test-Path `
            -LiteralPath $includeDir `
            -PathType Container
    )
) {
    throw "Missing include directory: $includeDir"
}


# =========================================================================
# Archive or remove the previous active capture
# =========================================================================

if (
    Test-Path `
        -LiteralPath $captureDir `
        -PathType Container
) {
    if ($KeepExisting) {
        $timestamp =
            Get-Date -Format "yyyyMMdd_HHmmss"

        $archiveName =
            "${timestamp}_${safeKernelName}_${modeName}"

        $archivePath =
            Join-Path $archiveRoot $archiveName

        Move-Item `
            -LiteralPath $captureDir `
            -Destination $archivePath `
            -Force

        Write-Host ""
        Write-Host (
            "Previous capture archived to: " +
            $archivePath
        ) -ForegroundColor DarkYellow
    } else {
        Remove-Item `
            -LiteralPath $captureDir `
            -Recurse `
            -Force
    }
}

Ensure-Directory $kernelCaptureRoot
Ensure-Directory $captureDir
Ensure-Directory $profileRuntimeDir


# =========================================================================
# Record executable identity
# =========================================================================

$exeFile =
    Get-Item `
        -LiteralPath $exePath

$exeHash =
    Get-FileHash `
        -LiteralPath $exePath `
        -Algorithm SHA256

$exeHashText =
    $exeHash.Hash.ToLowerInvariant()


# =========================================================================
# Record the Nsight Compute environment
# =========================================================================

Write-Host ""
Write-Host "Recording Nsight Compute environment..." `
    -ForegroundColor Cyan

Invoke-NcuCaptureToFile `
    -Arguments @(
        "--version"
    ) `
    -OutputPath $ncuVersionPath `
    -Description "Nsight Compute version output"

Invoke-NcuCaptureToFile `
    -Arguments @(
        "--help"
    ) `
    -OutputPath $ncuHelpPath `
    -Description "Nsight Compute help output"

Invoke-NcuCaptureToFile `
    -Arguments @(
        "--list-sets"
    ) `
    -OutputPath $ncuSetsPath `
    -Description "Nsight Compute set list"

Invoke-NcuCaptureToFile `
    -Arguments @(
        "--list-sections"
    ) `
    -OutputPath $ncuSectionsPath `
    -Description "Nsight Compute section list"

$ncuHelpText =
    Get-Content `
        -LiteralPath $ncuHelpPath `
        -Raw

$ncuSectionsText =
    Get-Content `
        -LiteralPath $ncuSectionsPath `
        -Raw

$supportsSourceFolders =
    $ncuHelpText -match
        '(?im)(?:--)?source-folders'

$supportsQueryMetricsMode =
    $ncuHelpText -match
        '(?im)(?:--)?query-metrics-mode'

$supportsSessionPage =
    $ncuHelpText -match
        '(?im)\bsession\b'

if (-not $SkipMetricQuery) {
    $metricQueryArguments =
        @(
            "--query-metrics"
        )

    if ($supportsQueryMetricsMode) {
        $metricQueryArguments +=
            @(
                "--query-metrics-mode"
                "base"
            )
    }

    [void](
        Invoke-OptionalNcuToFile `
            -Arguments $metricQueryArguments `
            -OutputPath $ncuMetricsPath `
            -Description "Nsight Compute metric query"
    )
}

$nvidiaSmi =
    Get-Command `
        "nvidia-smi" `
        -ErrorAction SilentlyContinue

if ($null -ne $nvidiaSmi) {
    try {
        Invoke-NativeCapture `
            -Command "nvidia-smi" `
            -Arguments @(
                "-q"
            ) `
            -OutputPath $gpuInfoPath |
            Out-Null

        Assert-ProfilerFile `
            -Path $gpuInfoPath `
            -Description "GPU information"
    } catch {
        $warnings.Add(
            "nvidia-smi environment collection failed: " +
            $_.Exception.Message
        ) | Out-Null
    }
}


# =========================================================================
# Select collection set and sections
# =========================================================================

$collectionArguments =
    @()

$collectionDescription =
    ""

switch ($CollectionMode) {
    "Basic" {
        $collectionArguments +=
            @(
                "--set"
                "basic"
            )

        $collectionDescription =
            "basic section set"
    }

    "Source" {
        if (
            $ncuSectionsText -notmatch
                '(?im)\bSourceCounters\b'
        ) {
            throw (
                "CollectionMode Source requires the " +
                "SourceCounters section, but it was not found " +
                "in ncu --list-sections."
            )
        }

        $collectionArguments +=
            @(
                "--set"
                "basic"
                "--section"
                "SourceCounters"
            )

        $collectionDescription =
            "basic section set plus SourceCounters"
    }

    "Full" {
        $collectionArguments +=
            @(
                "--set"
                "full"
            )

        $collectionDescription =
            "full section set"
    }

    default {
        throw "Unsupported collection mode: $CollectionMode"
    }
}


# Record the metrics activated by the selected set/sections.
[void](
    Invoke-OptionalNcuToFile `
        -Arguments (
            $collectionArguments +
            @(
                "--list-metrics"
            )
        ) `
        -OutputPath $activeMetricsPath `
        -Description "Active metric list"
)


# =========================================================================
# Build capture arguments
# =========================================================================

$sourceArguments =
    @(
        "--import-source"
        "yes"
    )

$sourceFolderText =
    @(
        $srcDir
        $includeDir
    ) -join ","

if ($supportsSourceFolders) {
    $sourceArguments +=
        @(
            "--source-folders"
            $sourceFolderText
        )
} else {
    $warnings.Add(
        "This Nsight Compute version does not advertise " +
        "--source-folders. Source import will rely on paths " +
        "embedded through -lineinfo."
    ) | Out-Null
}

$captureArguments =
    @(
        "--target-processes"
        "application-only"

        "--check-exit-code"
        "yes"

        "--filter-mode"
        "global"

        "--kernel-name-base"
        "function"

        "--kernel-name"
        $KernelName

        "--launch-count"
        "1"

        "--replay-mode"
        "kernel"

        "--cache-control"
        "all"

        "--clock-control"
        $ClockControl
    )

$captureArguments +=
    $collectionArguments

$captureArguments +=
    $sourceArguments

$captureArguments +=
    @(
        "--export"
        $reportBase

        "--force-overwrite"

        $exePath
        $profileRuntimeDir
        [string]$Samples
        [string]$Warmups
    )


# =========================================================================
# Capture one matching kernel launch
# =========================================================================

Write-Host ""
Write-Host "Capturing Nsight Compute report..." `
    -ForegroundColor Cyan

Write-Host "  Kernel          : $KernelName"
Write-Host "  Collection mode : $CollectionMode"
Write-Host "  Collection      : $collectionDescription"
Write-Host "  Launch count    : 1"
Write-Host "  Samples         : $Samples"
Write-Host "  Warmups         : $Warmups"
Write-Host "  Clock control   : $ClockControl"
Write-Host "  Executable      : $exePath"
Write-Host "  EXE SHA-256     : $exeHashText"
Write-Host "  Capture dir     : $captureDir"

Invoke-NativeCapture `
    -Command $ncuPath `
    -Arguments $captureArguments `
    -OutputPath $captureConsolePath |
    Out-Null

Assert-ProfilerFile `
    -Path $reportPath `
    -Description "Nsight Compute report"

Assert-ProfilerFile `
    -Path $captureConsolePath `
    -Description "Nsight Compute capture console"


# =========================================================================
# Reuse the report to export multiple views
# =========================================================================

Write-Host ""
Write-Host "Exporting report views..." `
    -ForegroundColor Cyan

Invoke-NcuImportToFile `
    -Arguments @(
        "--page"
        "details"

        "--print-details"
        "all"

        "--print-units"
        "base"
    ) `
    -OutputPath $detailsTextPath `
    -Description "Details text output"

Invoke-NcuImportToFile `
    -Arguments @(
        "--page"
        "details"

        "--print-details"
        "all"

        "--print-units"
        "base"

        "--csv"
    ) `
    -OutputPath $detailsCsvPath `
    -Description "Details CSV output"

Invoke-NcuImportToFile `
    -Arguments @(
        "--page"
        "raw"

        "--print-units"
        "base"

        "--csv"
    ) `
    -OutputPath $rawCsvPath `
    -Description "Raw metric CSV output"

Invoke-NcuImportToFile `
    -Arguments @(
        "--page"
        "source"

        "--print-source"
        "sass"
    ) `
    -OutputPath $sourceSassTextPath `
    -Description "SASS source text output"

Invoke-NcuImportToFile `
    -Arguments @(
        "--page"
        "source"

        "--print-source"
        "sass"

        "--print-units"
        "base"

        "--csv"
    ) `
    -OutputPath $sourceSassCsvPath `
    -Description "SASS source CSV output"


# CUDA-SASS correlation is useful but may not be available if the source
# path cannot be resolved by the installed NCU version.
$cudaSassTextSucceeded =
    Invoke-OptionalNcuImportToFile `
        -Arguments @(
            "--page"
            "source"

            "--print-source"
            "cuda,sass"
        ) `
        -OutputPath $sourceCudaSassTextPath `
        -Description "CUDA-SASS correlation text output"

$cudaSassCsvSucceeded =
    Invoke-OptionalNcuImportToFile `
        -Arguments @(
            "--page"
            "source"

            "--print-source"
            "cuda,sass"

            "--print-units"
            "base"

            "--csv"
        ) `
        -OutputPath $sourceCudaSassCsvPath `
        -Description "CUDA-SASS correlation CSV output"


$sessionSucceeded =
    $false

if ($supportsSessionPage) {
    $sessionSucceeded =
        Invoke-OptionalNcuImportToFile `
            -Arguments @(
                "--page"
                "session"
            ) `
            -OutputPath $sessionTextPath `
            -Description "Session information output"
} else {
    $warnings.Add(
        "This Nsight Compute version does not advertise the " +
        "session page. session.txt was not generated."
    ) | Out-Null
}


# =========================================================================
# Validate the exported report
# =========================================================================

$kernelFoundInDetails =
    Test-TextFileContains `
        -Path $detailsTextPath `
        -Pattern $KernelName `
        -SimpleMatch

$kernelFoundInRaw =
    Test-TextFileContains `
        -Path $rawCsvPath `
        -Pattern $KernelName `
        -SimpleMatch

$kernelFoundInSass =
    Test-TextFileContains `
        -Path $sourceSassTextPath `
        -Pattern $KernelName `
        -SimpleMatch

if (
    -not (
        $kernelFoundInDetails -or
        $kernelFoundInRaw -or
        $kernelFoundInSass
    )
) {
    throw (
        "The selected kernel name was not found in any imported " +
        "report view: $KernelName"
    )
}

if (-not $kernelFoundInDetails) {
    $warnings.Add(
        "Kernel name was not found in details.txt: $KernelName"
    ) | Out-Null
}

if (-not $kernelFoundInRaw) {
    $warnings.Add(
        "Kernel name was not found in raw.csv: $KernelName"
    ) | Out-Null
}

if (-not $kernelFoundInSass) {
    $warnings.Add(
        "Kernel name was not found in source_sass.txt: $KernelName"
    ) | Out-Null
}


$sourceSassContainsInstruction =
    Test-TextFileContains `
        -Path $sourceSassTextPath `
        -Pattern '\b(CS2R|FFMA|S2R|MOV|EXIT|BRA)\b'

if (-not $sourceSassContainsInstruction) {
    throw (
        "source_sass.txt does not appear to contain SASS " +
        "instructions: $sourceSassTextPath"
    )
}


$cudaSourceCorrelationFound =
    $false

if ($cudaSassTextSucceeded) {
    $cudaSourceCorrelationFound =
        (
            Test-TextFileContains `
                -Path $sourceCudaSassTextPath `
                -Pattern "probe_kernels.cu" `
                -SimpleMatch
        ) -or (
            Test-TextFileContains `
                -Path $sourceCudaSassTextPath `
                -Pattern '\.cu\b'
        )

    if (-not $cudaSourceCorrelationFound) {
        $warnings.Add(
            "CUDA-SASS output was generated, but a CUDA .cu " +
            "source reference was not detected. Inspect " +
            "source_cuda_sass.txt manually."
        ) | Out-Null
    }
}


# =========================================================================
# Related manifests
# =========================================================================

$relatedManifestRecords =
    [ordered]@{}

$buildManifestPath =
    Join-Path `
        $root `
        "results/build/build_manifest.json"

$binaryManifestPath =
    Join-Path `
        $root `
        "results/binary/binary_collection_manifest.json"

if (
    Test-Path `
        -LiteralPath $buildManifestPath `
        -PathType Leaf
) {
    $relatedManifestRecords["build_manifest"] =
        Get-ProfilerArtifactRecord `
            -Path $buildManifestPath
}

if (
    Test-Path `
        -LiteralPath $binaryManifestPath `
        -PathType Leaf
) {
    $relatedManifestRecords["binary_collection_manifest"] =
        Get-ProfilerArtifactRecord `
            -Path $binaryManifestPath
}


# =========================================================================
# Output artifact records
# =========================================================================

$outputPaths =
    [ordered]@{
        report                = $reportPath
        capture_console       = $captureConsolePath
        details_text          = $detailsTextPath
        details_csv           = $detailsCsvPath
        raw_csv               = $rawCsvPath
        source_sass_text      = $sourceSassTextPath
        source_sass_csv       = $sourceSassCsvPath
        source_cuda_sass_text = $sourceCudaSassTextPath
        source_cuda_sass_csv  = $sourceCudaSassCsvPath
        active_metrics        = $activeMetricsPath
    }

if ($sessionSucceeded) {
    $outputPaths["session_text"] =
        $sessionTextPath
}

$outputRecords =
    [ordered]@{}

foreach ($entry in $outputPaths.GetEnumerator()) {
    if (
        Test-Path `
            -LiteralPath $entry.Value `
            -PathType Leaf
    ) {
        $outputRecords[$entry.Key] =
            Get-ProfilerArtifactRecord `
                -Path $entry.Value
    }
}


$environmentPaths =
    [ordered]@{
        ncu_version  = $ncuVersionPath
        ncu_help     = $ncuHelpPath
        ncu_sets     = $ncuSetsPath
        ncu_sections = $ncuSectionsPath
    }

if (
    Test-Path `
        -LiteralPath $ncuMetricsPath `
        -PathType Leaf
) {
    $environmentPaths["ncu_metrics"] =
        $ncuMetricsPath
}

if (
    Test-Path `
        -LiteralPath $gpuInfoPath `
        -PathType Leaf
) {
    $environmentPaths["gpu_info"] =
        $gpuInfoPath
}

$environmentRecords =
    [ordered]@{}

foreach ($entry in $environmentPaths.GetEnumerator()) {
    $environmentRecords[$entry.Key] =
        Get-ProfilerArtifactRecord `
            -Path $entry.Value
}


# =========================================================================
# Capture manifest
# =========================================================================

$ncuVersionText =
    (
        Get-Content `
            -LiteralPath $ncuVersionPath `
            -Raw
    ).Trim()

$captureStatus =
    if ($warnings.Count -gt 0) {
        "WARN"
    } else {
        "PASS"
    }

$captureManifest =
    [ordered]@{
        schema_version = 1
        generated_at   = (Get-Date).ToString("o")
        status         = $captureStatus

        objective = (
            "Establish a repeatable static-SASS and Nsight " +
            "Compute report collection process."
        )

        kernel = [ordered]@{
            requested_name   = $KernelName
            name_base        = "function"
            launch_count     = 1
            filter_mode      = "global"
        }

        collection = [ordered]@{
            mode             = $CollectionMode
            description      = $collectionDescription
            replay_mode      = "kernel"
            cache_control    = "all"
            clock_control    = $ClockControl
            import_source    = $true
            source_folders_supported =
                $supportsSourceFolders
            source_folders   =
                if ($supportsSourceFolders) {
                    @(
                        $srcDir
                        $includeDir
                    )
                } else {
                    @()
                }
        }

        target_application = [ordered]@{
            samples = $Samples
            warmups = $Warmups

            runtime_arguments = @(
                $profileRuntimeDir
                [string]$Samples
                [string]$Warmups
            )
        }

        executable = [ordered]@{
            path       = $exeFile.FullName
            size_bytes = $exeFile.Length
            sha256     = $exeHashText
        }

        ncu = [ordered]@{
            path         = $ncuPath
            version_text = $ncuVersionText
            arguments    = $captureArguments
        }

        validations = [ordered]@{
            report_generated          = $true
            kernel_found_in_details    = $kernelFoundInDetails
            kernel_found_in_raw        = $kernelFoundInRaw
            kernel_found_in_sass       = $kernelFoundInSass
            sass_instruction_found     =
                $sourceSassContainsInstruction
            cuda_sass_text_exported    =
                $cudaSassTextSucceeded
            cuda_sass_csv_exported     =
                $cudaSassCsvSucceeded
            cuda_source_correlation_found =
                $cudaSourceCorrelationFound
            session_exported           =
                $sessionSucceeded
        }

        related_manifests =
            $relatedManifestRecords

        environment =
            $environmentRecords

        outputs =
            $outputRecords

        warnings =
            @($warnings)
    }

$captureManifest |
    ConvertTo-Json -Depth 12 |
    Set-Content `
        -LiteralPath $captureManifestPath `
        -Encoding UTF8

Assert-ProfilerFile `
    -Path $captureManifestPath `
    -Description "Capture manifest"


# =========================================================================
# Final output
# =========================================================================

$finalColor =
    if ($captureStatus -eq "PASS") {
        "Green"
    } else {
        "Yellow"
    }

Write-Host ""
Write-Host (
    "Nsight Compute capture completed. " +
    "Status: $captureStatus"
) -ForegroundColor $finalColor

Write-Host "  Kernel               : $KernelName"
Write-Host "  Collection mode      : $CollectionMode"
Write-Host "  Collection           : $collectionDescription"
Write-Host "  Launch count         : 1"
Write-Host "  Executable           : $exePath"
Write-Host "  EXE SHA-256          : $exeHashText"
Write-Host "  NCU report           : $reportPath"
Write-Host "  Details              : $detailsTextPath"
Write-Host "  Raw metrics          : $rawCsvPath"
Write-Host "  SASS source          : $sourceSassTextPath"
Write-Host "  CUDA-SASS source     : $sourceCudaSassTextPath"
Write-Host "  Capture manifest     : $captureManifestPath"
Write-Host "  Capture directory    : $captureDir"

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnings:" -ForegroundColor Yellow

    foreach ($warning in $warnings) {
        Write-Host "  - $warning" -ForegroundColor Yellow
    }
}