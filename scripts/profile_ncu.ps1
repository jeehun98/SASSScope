param(
    [ValidateNotNullOrEmpty()]
    [string]$KernelName = "probe_timer_only",

    # Basic:
    #   Basic sections for capture and launch validation.
    #
    # Source:
    #   Basic sections plus SourceCounters.
    #
    # Full:
    #   Full predefined set.
    [ValidateSet("Basic", "Source", "Full")]
    [string]$CollectionMode = "Basic",

    [ValidateRange(1, 1000000)]
    [int]$Samples = 1,

    [ValidateRange(0, 1000000)]
    [int]$Warmups = 0,

    [ValidateSet("base", "boost", "none")]
    [string]$ClockControl = "base",

    # Archive the previous capture instead of deleting it.
    [switch]$KeepExisting,

    # Skip the potentially large global metric query.
    [switch]$SkipMetricQuery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")


# =========================================================================
# Project root and commands
# =========================================================================

$root = Get-ProjectRoot
Set-Location $root

Require-Command "ncu" | Out-Null
Require-Command "nvdisasm" | Out-Null
Require-Command "python" | Out-Null


function Resolve-CommandPath {
    param(
        [Parameter(Mandatory)]
        [object]$CommandInfo,

        [Parameter(Mandatory)]
        [string]$CommandName
    )

    $pathProperty =
        $CommandInfo.PSObject.Properties["Path"]

    if (
        $null -ne $pathProperty -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$pathProperty.Value
        )
    ) {
        return [string]$pathProperty.Value
    }

    $sourceProperty =
        $CommandInfo.PSObject.Properties["Source"]

    if (
        $null -ne $sourceProperty -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$sourceProperty.Value
        )
    ) {
        return [string]$sourceProperty.Value
    }

    throw "Unable to resolve command path: $CommandName"
}


$ncuCommandInfo =
    Get-Command `
        "ncu" `
        -ErrorAction Stop

$nvdisasmCommandInfo =
    Get-Command `
        "nvdisasm" `
        -ErrorAction Stop

$pythonCommandInfo =
    Get-Command `
        "python" `
        -ErrorAction Stop

$ncuPath =
    Resolve-CommandPath `
        -CommandInfo $ncuCommandInfo `
        -CommandName "ncu"

$nvdisasmPath =
    Resolve-CommandPath `
        -CommandInfo $nvdisasmCommandInfo `
        -CommandName "nvdisasm"

$pythonPath =
    Resolve-CommandPath `
        -CommandInfo $pythonCommandInfo `
        -CommandName "python"


# =========================================================================
# Input paths
# =========================================================================

$exePath =
    Join-Path $root "build/probe_ffma.exe"

$runtimeCubinPath =
    Join-Path `
        $root `
        "results/binary/probe_ffma_runtime_sm86.cubin"

$sassListingAnalyzerPath =
    Join-Path `
        $root `
        "tools/extract_sass_listing.py"

$srcDir =
    Join-Path $root "src"

$includeDir =
    Join-Path $root "include"


# =========================================================================
# Output directories
# =========================================================================

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


# =========================================================================
# Nsight Compute output paths
# =========================================================================

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


# =========================================================================
# Canonical SASS output paths
# =========================================================================

$canonicalSassLineInfoPath =
    Join-Path `
        $captureDir `
        "canonical_sass_lineinfo.txt"

$sassInstructionCsvPath =
    Join-Path `
        $captureDir `
        "sass_instructions.csv"

$sassInstructionTextPath =
    Join-Path `
        $captureDir `
        "sass_instructions.txt"

$sassInstructionJsonPath =
    Join-Path `
        $captureDir `
        "sass_instructions.json"

$sassAnalyzerConsolePath =
    Join-Path `
        $captureDir `
        "sass_instruction_analyzer_console.txt"


# =========================================================================
# Manifest and environment output paths
# =========================================================================

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
            -LiteralPath $runtimeCubinPath `
            -PathType Leaf
    )
) {
    throw (
        "Missing canonical runtime CUBIN. " +
        "Run scripts/collect_binary_outputs.ps1 first: " +
        $runtimeCubinPath
    )
}

if (
    -not (
        Test-Path `
            -LiteralPath $sassListingAnalyzerPath `
            -PathType Leaf
    )
) {
    throw (
        "Missing SASS listing analyzer: " +
        $sassListingAnalyzerPath
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
# Archive or remove previous capture
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
# Record artifact identities
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

$runtimeCubinFile =
    Get-Item `
        -LiteralPath $runtimeCubinPath

$runtimeCubinHash =
    Get-FileHash `
        -LiteralPath $runtimeCubinPath `
        -Algorithm SHA256

$runtimeCubinHashText =
    $runtimeCubinHash.Hash.ToLowerInvariant()


# =========================================================================
# Record Nsight Compute environment
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

$nvidiaSmiCommand =
    Get-Command `
        "nvidia-smi" `
        -ErrorAction SilentlyContinue

if ($null -ne $nvidiaSmiCommand) {
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
                "CollectionMode Source requires SourceCounters, " +
                "but the section was not found in ncu --list-sections."
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


# Record metrics activated by the selected configuration.
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
        "--source-folders. Source import will rely on -lineinfo paths."
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
Write-Host "  Runtime CUBIN   : $runtimeCubinPath"
Write-Host "  CUBIN SHA-256   : $runtimeCubinHashText"
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
# Export optional Details views
#
# Nsight Compute 2025.4 does not accept --apply-rules with --import.
# Details may still invoke Python-based rule processing, so these exports
# are optional. Raw and Source exports remain mandatory.
# =========================================================================

Write-Host ""
Write-Host "Exporting report views..." `
    -ForegroundColor Cyan

$detailsTextSucceeded =
    Invoke-OptionalNcuImportToFile `
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

$detailsCsvSucceeded =
    Invoke-OptionalNcuImportToFile `
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


# =========================================================================
# Export mandatory Raw and SASS views
# =========================================================================

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


# =========================================================================
# Export optional CUDA-SASS correlation
# =========================================================================

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


# =========================================================================
# Export optional session information
# =========================================================================

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
# Generate canonical runtime-CUBIN SASS with source line information
# =========================================================================

Write-Host ""
Write-Host "Generating canonical SASS listing..." `
    -ForegroundColor Cyan

Invoke-NativeCapture `
    -Command $nvdisasmPath `
    -Arguments @(
        "-gi"
        $runtimeCubinPath
    ) `
    -OutputPath $canonicalSassLineInfoPath |
    Out-Null

Assert-ProfilerFile `
    -Path $canonicalSassLineInfoPath `
    -Description "Canonical SASS line-info output"


# =========================================================================
# Extract normalized SASS instruction table
# =========================================================================

Write-Host ""
Write-Host "Extracting normalized SASS instructions..." `
    -ForegroundColor Cyan

# -S prevents user-site .pth processing.
# -X utf8 enables stable UTF-8 handling on Windows.
Invoke-NativeCapture `
    -Command $pythonPath `
    -Arguments @(
        "-X"
        "utf8"

        "-S"

        $sassListingAnalyzerPath

        "--input"
        $canonicalSassLineInfoPath

        "--kernel"
        $KernelName

        "--output-csv"
        $sassInstructionCsvPath

        "--output-text"
        $sassInstructionTextPath

        "--output-json"
        $sassInstructionJsonPath

        "--source-root"
        $root

        "--source-root"
        $srcDir

        "--source-root"
        $includeDir
    ) `
    -OutputPath $sassAnalyzerConsolePath |
    Out-Null

Assert-ProfilerFile `
    -Path $sassInstructionCsvPath `
    -Description "Normalized SASS instruction CSV"

Assert-ProfilerFile `
    -Path $sassInstructionTextPath `
    -Description "SASS instruction text listing"

Assert-ProfilerFile `
    -Path $sassInstructionJsonPath `
    -Description "SASS instruction JSON report"

Assert-ProfilerFile `
    -Path $sassAnalyzerConsolePath `
    -Description "SASS instruction analyzer console"


# =========================================================================
# Validate required NCU outputs
# =========================================================================

$kernelFoundInDetails =
    $false

if ($detailsTextSucceeded) {
    $kernelFoundInDetails =
        Test-TextFileContains `
            -Path $detailsTextPath `
            -Pattern $KernelName `
            -SimpleMatch
}

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
        $kernelFoundInRaw -or
        $kernelFoundInSass
    )
) {
    throw (
        "The selected kernel name was not found in the required " +
        "raw or SASS report views: $KernelName"
    )
}

if (
    $detailsTextSucceeded -and
    -not $kernelFoundInDetails
) {
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
        -Pattern '\b(CS2R|FFMA|S2R|MOV|EXIT|BRA|STG|LDG|ULDC)\b'

if (-not $sourceSassContainsInstruction) {
    throw (
        "source_sass.txt does not appear to contain SASS " +
        "instructions: $sourceSassTextPath"
    )
}


# =========================================================================
# Detect Details rule-processing errors
# =========================================================================

$detailsContainsTraceback =
    $false

$detailsContainsEncodingError =
    $false

if (
    $detailsTextSucceeded -and
    (
        Test-Path `
            -LiteralPath $detailsTextPath `
            -PathType Leaf
    )
) {
    $detailsContainsTraceback =
        Test-TextFileContains `
            -Path $detailsTextPath `
            -Pattern "Traceback (most recent call last):" `
            -SimpleMatch

    $detailsContainsEncodingError =
        Test-TextFileContains `
            -Path $detailsTextPath `
            -Pattern "unknown encoding: utf-8-sig" `
            -SimpleMatch
}

if ($detailsContainsTraceback) {
    $warnings.Add(
        "Python traceback was detected in details.txt. " +
        "The NCU report remains usable through raw and source exports."
    ) | Out-Null
}

if ($detailsContainsEncodingError) {
    $warnings.Add(
        "The Details rule environment reported " +
        "'unknown encoding: utf-8-sig'. Raw and SASS exports remain usable."
    ) | Out-Null
}


# =========================================================================
# Validate CUDA source correlation
# =========================================================================

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
# Validate normalized canonical SASS listing
# =========================================================================

try {
    $sassListingJson =
        Get-Content `
            -LiteralPath $sassInstructionJsonPath `
            -Raw |
        ConvertFrom-Json
} catch {
    throw (
        "Failed to parse sass_instructions.json: " +
        $_.Exception.Message
    )
}

$instructionCountProperty =
    $sassListingJson.PSObject.Properties[
        "instruction_count"
    ]

$sourceMappedCountProperty =
    $sassListingJson.PSObject.Properties[
        "source_mapped_count"
    ]

$sourceTextCountProperty =
    $sassListingJson.PSObject.Properties[
        "source_text_count"
    ]

if (
    $null -eq $instructionCountProperty -or
    $null -eq $sourceMappedCountProperty -or
    $null -eq $sourceTextCountProperty
) {
    throw (
        "sass_instructions.json is missing one or more required " +
        "summary properties."
    )
}

$sassInstructionCount =
    [int]$instructionCountProperty.Value

$sassSourceMappedCount =
    [int]$sourceMappedCountProperty.Value

$sassSourceTextCount =
    [int]$sourceTextCountProperty.Value

if ($sassInstructionCount -le 0) {
    throw (
        "No canonical SASS instructions were extracted for " +
        "$KernelName."
    )
}

if ($sassSourceMappedCount -le 0) {
    $warnings.Add(
        "Canonical SASS instructions were extracted, but no " +
        "CUDA source-line mapping was found."
    ) | Out-Null
}

if ($sassSourceTextCount -le 0) {
    $warnings.Add(
        "CUDA source-line metadata exists, but source text could " +
        "not be resolved from the current source tree."
    ) | Out-Null
}

$timerCs2rCount =
    0

$opcodeCountsProperty =
    $sassListingJson.PSObject.Properties[
        "opcode_counts"
    ]

if ($null -ne $opcodeCountsProperty) {
    $cs2rProperty =
        $opcodeCountsProperty.Value.PSObject.Properties[
            "CS2R"
        ]

    if ($null -ne $cs2rProperty) {
        $timerCs2rCount =
            [int]$cs2rProperty.Value
    }
}

if (
    $KernelName -eq "probe_timer_only" -and
    $timerCs2rCount -lt 2
) {
    throw (
        "probe_timer_only canonical SASS should contain at least " +
        "two CS2R instructions. Found: $timerCs2rCount"
    )
}


# =========================================================================
# Related build and binary manifests
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
    $relatedManifestRecords[
        "binary_collection_manifest"
    ] =
        Get-ProfilerArtifactRecord `
            -Path $binaryManifestPath
}


# =========================================================================
# Output artifact records
# =========================================================================

$outputPaths =
    [ordered]@{
        report =
            $reportPath

        capture_console =
            $captureConsolePath

        raw_csv =
            $rawCsvPath

        source_sass_text =
            $sourceSassTextPath

        source_sass_csv =
            $sourceSassCsvPath

        canonical_sass_line_info =
            $canonicalSassLineInfoPath

        sass_instructions_csv =
            $sassInstructionCsvPath

        sass_instructions_text =
            $sassInstructionTextPath

        sass_instructions_json =
            $sassInstructionJsonPath

        sass_analyzer_console =
            $sassAnalyzerConsolePath

        active_metrics =
            $activeMetricsPath
    }

if (
    Test-Path `
        -LiteralPath $detailsTextPath `
        -PathType Leaf
) {
    $outputPaths["details_text"] =
        $detailsTextPath
}

if (
    Test-Path `
        -LiteralPath $detailsCsvPath `
        -PathType Leaf
) {
    $outputPaths["details_csv"] =
        $detailsCsvPath
}

if (
    Test-Path `
        -LiteralPath $sourceCudaSassTextPath `
        -PathType Leaf
) {
    $outputPaths["source_cuda_sass_text"] =
        $sourceCudaSassTextPath
}

if (
    Test-Path `
        -LiteralPath $sourceCudaSassCsvPath `
        -PathType Leaf
) {
    $outputPaths["source_cuda_sass_csv"] =
        $sourceCudaSassCsvPath
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


# =========================================================================
# Environment artifact records
# =========================================================================

$environmentPaths =
    [ordered]@{
        ncu_version =
            $ncuVersionPath

        ncu_help =
            $ncuHelpPath

        ncu_sets =
            $ncuSetsPath

        ncu_sections =
            $ncuSectionsPath
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
        schema_version = 3
        generated_at   = (Get-Date).ToString("o")
        status         = $captureStatus

        objective = (
            "Establish a repeatable CUDA-source, canonical-SASS, " +
            "and Nsight Compute correlation process."
        )

        kernel = [ordered]@{
            requested_name =
                $KernelName

            name_base =
                "function"

            launch_count =
                1

            filter_mode =
                "global"
        }

        collection = [ordered]@{
            mode =
                $CollectionMode

            description =
                $collectionDescription

            replay_mode =
                "kernel"

            cache_control =
                "all"

            clock_control =
                $ClockControl

            import_source =
                $true

            details_rule_policy =
                "ncu_default_rules_import_option_unavailable"

            source_folders_supported =
                $supportsSourceFolders

            source_folders =
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
            samples =
                $Samples

            warmups =
                $Warmups

            runtime_arguments = @(
                $profileRuntimeDir
                [string]$Samples
                [string]$Warmups
            )
        }

        executable = [ordered]@{
            path =
                $exeFile.FullName

            size_bytes =
                $exeFile.Length

            sha256 =
                $exeHashText
        }

        canonical_runtime_cubin = [ordered]@{
            path =
                $runtimeCubinFile.FullName

            size_bytes =
                $runtimeCubinFile.Length

            sha256 =
                $runtimeCubinHashText
        }

        tools = [ordered]@{
            ncu_path =
                $ncuPath

            ncu_version_text =
                $ncuVersionText

            nvdisasm_path =
                $nvdisasmPath

            python_path =
                $pythonPath

            sass_listing_analyzer =
                $sassListingAnalyzerPath
        }

        ncu_arguments =
            $captureArguments

        sass_listing = [ordered]@{
            instruction_count =
                $sassInstructionCount

            source_mapped_count =
                $sassSourceMappedCount

            source_text_count =
                $sassSourceTextCount

            timer_cs2r_count =
                $timerCs2rCount
        }

        validations = [ordered]@{
            report_generated =
                $true

            details_text_exported =
                $detailsTextSucceeded

            details_csv_exported =
                $detailsCsvSucceeded

            kernel_found_in_details =
                $kernelFoundInDetails

            kernel_found_in_raw =
                $kernelFoundInRaw

            kernel_found_in_sass =
                $kernelFoundInSass

            ncu_sass_instruction_found =
                $sourceSassContainsInstruction

            cuda_sass_text_exported =
                $cudaSassTextSucceeded

            cuda_sass_csv_exported =
                $cudaSassCsvSucceeded

            cuda_source_correlation_found =
                $cudaSourceCorrelationFound

            details_traceback_found =
                $detailsContainsTraceback

            details_encoding_error_found =
                $detailsContainsEncodingError

            canonical_sass_generated =
                $true

            canonical_sass_instruction_count =
                $sassInstructionCount

            canonical_source_mapping_found =
                ($sassSourceMappedCount -gt 0)

            canonical_source_text_found =
                ($sassSourceTextCount -gt 0)

            session_exported =
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
    ConvertTo-Json -Depth 14 |
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
    "Nsight Compute and SASS capture completed. " +
    "Status: $captureStatus"
) -ForegroundColor $finalColor

Write-Host ""
Write-Host "Capture configuration:"
Write-Host "  Kernel               : $KernelName"
Write-Host "  Collection mode      : $CollectionMode"
Write-Host "  Collection           : $collectionDescription"
Write-Host "  Launch count         : 1"
Write-Host "  Samples              : $Samples"
Write-Host "  Warmups              : $Warmups"

Write-Host ""
Write-Host "Artifact identity:"
Write-Host "  Executable           : $exePath"
Write-Host "  EXE SHA-256          : $exeHashText"
Write-Host "  Runtime CUBIN        : $runtimeCubinPath"
Write-Host "  CUBIN SHA-256        : $runtimeCubinHashText"

Write-Host ""
Write-Host "Nsight Compute outputs:"
Write-Host "  NCU report           : $reportPath"
Write-Host "  Details TXT success  : $detailsTextSucceeded"
Write-Host "  Details CSV success  : $detailsCsvSucceeded"
Write-Host "  Raw metrics          : $rawCsvPath"
Write-Host "  NCU SASS             : $sourceSassTextPath"
Write-Host "  CUDA-SASS success    : $cudaSassTextSucceeded"
Write-Host "  CUDA-SASS source     : $sourceCudaSassTextPath"

Write-Host ""
Write-Host "Canonical SASS outputs:"
Write-Host "  Full line-info SASS  : $canonicalSassLineInfoPath"
Write-Host "  Instruction listing  : $sassInstructionTextPath"
Write-Host "  Instruction CSV      : $sassInstructionCsvPath"
Write-Host "  Instruction JSON     : $sassInstructionJsonPath"
Write-Host "  Instruction count    : $sassInstructionCount"
Write-Host "  Source-mapped count  : $sassSourceMappedCount"
Write-Host "  Source-text count    : $sassSourceTextCount"

Write-Host ""
Write-Host "Capture metadata:"
Write-Host "  Capture manifest     : $captureManifestPath"
Write-Host "  Capture directory    : $captureDir"

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnings:" -ForegroundColor Yellow

    foreach ($warning in $warnings) {
        Write-Host "  - $warning" -ForegroundColor Yellow
    }
}