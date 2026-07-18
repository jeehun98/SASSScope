param(
    [ValidateRange(50, 999)]
    [int]$Arch = 86
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$commonPath = Join-Path $PSScriptRoot "common.ps1"

if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "common.ps1 was not found: $commonPath"
}

. $commonPath

function Assert-FileExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not found: $Path"
    }
}

function Assert-NonEmptyFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    Assert-FileExists `
        -Path $Path `
        -Description $Description

    $item = Get-Item -LiteralPath $Path

    if ($item.Length -eq 0) {
        throw "$Description is empty: $Path"
    }
}

function Get-FileRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Assert-FileExists `
        -Path $Path `
        -Description "File"

    $item = Get-Item -LiteralPath $Path
    $hash = Get-FileHash `
        -LiteralPath $Path `
        -Algorithm SHA256

    return [ordered]@{
        path       = $item.FullName
        size_bytes = $item.Length
        sha256     = $hash.Hash.ToLowerInvariant()
    }
}

function Assert-HashMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedHash,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $actualHash = (
        Get-FileHash `
            -LiteralPath $Path `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    $normalizedExpected =
        $ExpectedHash.ToLowerInvariant()

    if ($actualHash -ne $normalizedExpected) {
        throw (
            "$Description does not match build_manifest.json.`n" +
            "Expected: $normalizedExpected`n" +
            "Actual  : $actualHash`n" +
            "Re-run scripts/build.ps1 -Clean."
        )
    }
}

$root = Get-ProjectRoot

Push-Location $root

try {
    Require-Command "cuobjdump" | Out-Null
    Require-Command "nvdisasm" | Out-Null
    Require-Command "python" | Out-Null

    $buildDir = Join-Path $root "build"
    $resultBuildDir = Join-Path $root "results/build"
    $binaryDir = Join-Path $root "results/binary"

    Ensure-Directory $binaryDir

    $exePath =
        Join-Path $buildDir "probe_ffma.exe"

    # This remains a separately compiled comparison artifact.
    $referenceCubinPath =
        Join-Path $buildDir "probe_kernels_sm$Arch.cubin"

    # This should be generated separately by build.ps1.
    $standalonePtxPath =
        Join-Path $buildDir "probe_kernels_compute$Arch.ptx"

    $buildManifestPath =
        Join-Path $resultBuildDir "build_manifest.json"

    $analyzerPath =
        Join-Path $root "tools/analyze_sass.py"

    Assert-FileExists `
        -Path $exePath `
        -Description "Canonical runtime executable"

    Assert-FileExists `
        -Path $referenceCubinPath `
        -Description "Reference CUBIN"

    Assert-FileExists `
        -Path $analyzerPath `
        -Description "SASS analyzer"

    # ---------------------------------------------------------------------
    # Validate that analysis is being run against the latest build artifacts.
    # ---------------------------------------------------------------------

    if (Test-Path -LiteralPath $buildManifestPath -PathType Leaf) {
        $buildManifest =
            Get-Content `
                -LiteralPath $buildManifestPath `
                -Raw |
            ConvertFrom-Json

        Assert-HashMatches `
            -Path $exePath `
            -ExpectedHash $buildManifest.artifacts.executable.sha256 `
            -Description "Canonical runtime executable"

        Assert-HashMatches `
            -Path $referenceCubinPath `
            -ExpectedHash $buildManifest.artifacts.reference_cubin.sha256 `
            -Description "Reference CUBIN"
    }
    else {
        Write-Warning (
            "build_manifest.json was not found. " +
            "Stale build detection will be skipped: " +
            $buildManifestPath
        )
    }

    # ---------------------------------------------------------------------
    # Output paths
    # ---------------------------------------------------------------------

    $canonicalPtxOutput =
        Join-Path $binaryDir "probe_ffma.ptx.txt"

    $canonicalSassOutput =
        Join-Path $binaryDir "probe_ffma_full.sass.txt"

    $resourceUsageOutput =
        Join-Path $binaryDir "probe_ffma_resource_usage.txt"

    $lineInfoSassOutput =
        Join-Path $binaryDir "probe_ffma_lineinfo.sass.txt"

    $detailedSassOutput =
        Join-Path $binaryDir "probe_ffma_detailed.sass.txt"

    $elfListOutput =
        Join-Path $binaryDir "probe_ffma_runtime_elf_list.txt"

    $elfExtractConsoleOutput =
        Join-Path $binaryDir "probe_ffma_runtime_elf_extract_console.txt"

    $runtimeCubinPath =
        Join-Path $binaryDir "probe_ffma_runtime_sm$Arch.cubin"

    $referenceSassOutput =
        Join-Path $binaryDir "probe_ffma_reference_full.sass.txt"

    $canonicalAnalyzerConsole =
        Join-Path $binaryDir "sass_analyzer_console.txt"

    $referenceAnalysisDir =
        Join-Path $binaryDir "reference_analysis"

    $referenceAnalyzerConsole =
        Join-Path $referenceAnalysisDir "sass_analyzer_console.txt"

    Ensure-Directory $referenceAnalysisDir

    # ---------------------------------------------------------------------
    # Clean extracted-runtime directory to prevent stale CUBIN selection.
    # ---------------------------------------------------------------------

    $runtimeExtractDir =
        Join-Path $binaryDir "runtime_embedded"

    if (Test-Path -LiteralPath $runtimeExtractDir) {
        Remove-Item `
            -LiteralPath $runtimeExtractDir `
            -Force `
            -Recurse
    }

    Ensure-Directory $runtimeExtractDir

    # ---------------------------------------------------------------------
    # PTX
    # ---------------------------------------------------------------------
    #
    # Preferred path:
    #   Copy a separately generated PTX artifact.
    #
    # Fallback:
    #   Attempt to extract embedded PTX from the EXE. An sm-only executable
    #   may not contain PTX, so the result must be validated.

    if (Test-Path -LiteralPath $standalonePtxPath -PathType Leaf) {
        Copy-Item `
            -LiteralPath $standalonePtxPath `
            -Destination $canonicalPtxOutput `
            -Force
    }
    else {
        Write-Warning (
            "Standalone PTX was not found. " +
            "Attempting to extract PTX from the executable."
        )

        Invoke-NativeCapture `
            -Command "cuobjdump" `
            -Arguments @(
                "--dump-ptx",
                $exePath
            ) `
            -OutputPath $canonicalPtxOutput |
            Out-Null

        $containsPtxVersion =
            Select-String `
                -LiteralPath $canonicalPtxOutput `
                -Pattern "^\s*\.version" `
                -Quiet

        if (-not $containsPtxVersion) {
            throw (
                "No usable PTX was found in the executable.`n" +
                "Generate the following artifact in build.ps1:`n" +
                $standalonePtxPath
            )
        }
    }

    Assert-NonEmptyFile `
        -Path $canonicalPtxOutput `
        -Description "PTX output"

    # ---------------------------------------------------------------------
    # Canonical SASS and resource usage from the actual runtime executable.
    # ---------------------------------------------------------------------

    Invoke-NativeCapture `
        -Command "cuobjdump" `
        -Arguments @(
            "--dump-sass",
            "--gpu-architecture",
            "sm_$Arch",
            $exePath
        ) `
        -OutputPath $canonicalSassOutput |
        Out-Null

    Invoke-NativeCapture `
        -Command "cuobjdump" `
        -Arguments @(
            "--dump-resource-usage",
            "--gpu-architecture",
            "sm_$Arch",
            $exePath
        ) `
        -OutputPath $resourceUsageOutput |
        Out-Null

    Assert-NonEmptyFile `
        -Path $canonicalSassOutput `
        -Description "Canonical EXE SASS"

    Assert-NonEmptyFile `
        -Path $resourceUsageOutput `
        -Description "Runtime resource usage"

    # ---------------------------------------------------------------------
    # Extract the exact embedded runtime CUBIN from the executable.
    # ---------------------------------------------------------------------

    Invoke-NativeCapture `
        -Command "cuobjdump" `
        -Arguments @(
            "--list-elf",
            $exePath
        ) `
        -OutputPath $elfListOutput |
        Out-Null

    Push-Location $runtimeExtractDir

    try {
        Invoke-NativeCapture `
            -Command "cuobjdump" `
            -Arguments @(
                "--extract-elf",
                "all",
                $exePath
            ) `
            -OutputPath $elfExtractConsoleOutput |
            Out-Null
    }
    finally {
        Pop-Location
    }

    $extractedCandidates =
        @(
            Get-ChildItem `
                -LiteralPath $runtimeExtractDir `
                -File `
                -Force
        )

    if ($extractedCandidates.Count -eq 0) {
        throw (
            "No embedded ELF/CUBIN was extracted from the executable: " +
            $exePath
        )
    }

    $architecturePattern =
        [regex]::Escape("sm_$Arch")

    $architectureMatches =
        @(
            $extractedCandidates |
            Where-Object {
                $_.Name -match $architecturePattern
            }
        )

    if ($architectureMatches.Count -eq 0) {
        $candidateNames =
            $extractedCandidates.Name -join ", "

        throw (
            "No extracted runtime ELF matched sm_$Arch.`n" +
            "Candidates: $candidateNames"
        )
    }

    # ---------------------------------------------------------------------
    # Inspect every matching ELF and find the one containing all probe kernels.
    # ---------------------------------------------------------------------

    $requiredKernelNames = @(
        "probe_timer_only"
        "probe_dependent_ffma"
        "probe_independent_ffma_8"
    )

    $candidateInspectionDir =
        Join-Path $binaryDir "runtime_candidate_inspection"

    if (Test-Path -LiteralPath $candidateInspectionDir) {
        Remove-Item `
            -LiteralPath $candidateInspectionDir `
            -Force `
            -Recurse
    }

    Ensure-Directory $candidateInspectionDir

    $candidateRecords = @()

    foreach ($candidate in $architectureMatches) {
        $safeBaseName =
            [System.IO.Path]::GetFileNameWithoutExtension(
                $candidate.Name
            )

        $candidateSassPath =
            Join-Path `
                $candidateInspectionDir `
                "$safeBaseName.sass.txt"

        Invoke-NativeCapture `
            -Command "cuobjdump" `
            -Arguments @(
                "--dump-sass"
                $candidate.FullName
            ) `
            -OutputPath $candidateSassPath |
            Out-Null

        $candidateSassText = ""

        if (
            Test-Path `
                -LiteralPath $candidateSassPath `
                -PathType Leaf
        ) {
            $candidateSassText =
                Get-Content `
                    -LiteralPath $candidateSassPath `
                    -Raw
        }

        $foundKernelNames = @(
            foreach ($kernelName in $requiredKernelNames) {
                $escapedKernelName =
                    [regex]::Escape($kernelName)

                $functionPattern =
                    "(?m)^\s*Function\s*:\s*$escapedKernelName\s*$"

                if (
                    $candidateSassText -match $functionPattern
                ) {
                    $kernelName
                }
            }
        )

        $missingKernelNames = @(
            $requiredKernelNames |
            Where-Object {
                $_ -notin $foundKernelNames
            }
        )

        $containsAllRequiredKernels =
            $missingKernelNames.Count -eq 0

        # Preference is only a tie-breaker after kernel-content validation.
        #
        # A combined name such as main-probe_kernels.sm_86.cubin is preferred
        # because it commonly represents the executable-level linked image.
        $preferenceScore = 0

        if ($containsAllRequiredKernels) {
            $preferenceScore += 1000
        }

        if (
            $candidate.Name -eq
            "main-probe_kernels.sm_$Arch.cubin"
        ) {
            $preferenceScore += 100
        }
        elseif (
            $candidate.Name -match
            "(^|[-_])probe_kernels([._-]|$)"
        ) {
            $preferenceScore += 10
        }

        $candidateHash =
            Get-FileHash `
                -LiteralPath $candidate.FullName `
                -Algorithm SHA256

        $candidateRecords += [pscustomobject]@{
            name                         = $candidate.Name
            path                         = $candidate.FullName
            size_bytes                   = $candidate.Length
            sha256                       =
                $candidateHash.Hash.ToLowerInvariant()
            sass_path                    = $candidateSassPath
            found_kernel_names           = $foundKernelNames
            missing_kernel_names         = $missingKernelNames
            contains_all_required_kernels =
                $containsAllRequiredKernels
            preference_score             = $preferenceScore
        }
    }

    $validCandidates =
        @(
            $candidateRecords |
            Where-Object {
                $_.contains_all_required_kernels
            } |
            Sort-Object `
                -Property @(
                    @{
                        Expression = "preference_score"
                        Descending = $true
                    }
                    @{
                        Expression = "size_bytes"
                        Descending = $true
                    }
                    @{
                        Expression = "name"
                        Descending = $false
                    }
                )
        )

    if ($validCandidates.Count -eq 0) {
        $inspectionLines = @(
            foreach ($record in $candidateRecords) {
                $found =
                    if ($record.found_kernel_names.Count -gt 0) {
                        $record.found_kernel_names -join ", "
                    }
                    else {
                        "none"
                    }

                $missing =
                    if ($record.missing_kernel_names.Count -gt 0) {
                        $record.missing_kernel_names -join ", "
                    }
                    else {
                        "none"
                    }

                "  $($record.name): found=[$found], missing=[$missing]"
            }
        )

        throw (
            "No extracted sm_$Arch ELF contains all required probe kernels.`n" +
            ($inspectionLines -join "`n")
        )
    }

    $selectedRecord =
        $validCandidates[0]

    $selectedRuntimeElf =
        Get-Item `
            -LiteralPath $selectedRecord.path

    if ($validCandidates.Count -gt 1) {
        $validNames =
            $validCandidates.name -join ", "

        Write-Warning (
            "Multiple extracted ELFs contain all required probe kernels. " +
            "Selected '$($selectedRecord.name)' using the preference rule. " +
            "Valid candidates: $validNames"
        )
    }

    Copy-Item `
        -LiteralPath $selectedRuntimeElf.FullName `
        -Destination $runtimeCubinPath `
        -Force

    Assert-NonEmptyFile `
        -Path $runtimeCubinPath `
        -Description "Selected runtime CUBIN"

    # Preserve the candidate inspection and final selection.
    $candidateSelectionPath =
        Join-Path `
            $binaryDir `
            "runtime_cubin_selection.json"

    $candidateSelection = [ordered]@{
        schema_version = 1
        generated_at   = (Get-Date).ToString("o")
        architecture   = "sm_$Arch"

        required_kernels = $requiredKernelNames

        selected = [ordered]@{
            name             = $selectedRecord.name
            source_path      = $selectedRecord.path
            copied_path      = $runtimeCubinPath
            size_bytes       = $selectedRecord.size_bytes
            sha256           = $selectedRecord.sha256
            preference_score = $selectedRecord.preference_score
            sass_path        = $selectedRecord.sass_path
        }

        candidates = @(
            foreach ($record in $candidateRecords) {
                [ordered]@{
                    name             = $record.name
                    path             = $record.path
                    size_bytes       = $record.size_bytes
                    sha256           = $record.sha256
                    sass_path        = $record.sass_path

                    found_kernel_names =
                        @($record.found_kernel_names)

                    missing_kernel_names =
                        @($record.missing_kernel_names)

                    contains_all_required_kernels =
                        $record.contains_all_required_kernels

                    preference_score =
                        $record.preference_score
                }
            }
        )
    }

    $candidateSelection |
        ConvertTo-Json -Depth 8 |
        Set-Content `
            -LiteralPath $candidateSelectionPath `
            -Encoding UTF8

    Write-Host ""
    Write-Host "Runtime CUBIN selection:"
    Write-Host "  Selected candidate : $($selectedRecord.name)"
    Write-Host "  Required kernels   : $($requiredKernelNames -join ', ')"
    Write-Host "  Selection record   : $candidateSelectionPath"


    Assert-NonEmptyFile `
        -Path $runtimeCubinPath `
        -Description "Extracted runtime CUBIN"

    # ---------------------------------------------------------------------
    # Detailed disassembly of the exact runtime CUBIN.
    # ---------------------------------------------------------------------

    Invoke-NativeCapture `
        -Command "nvdisasm" `
        -Arguments @(
            "-c",
            "-g",
            "-sf",
            $runtimeCubinPath
        ) `
        -OutputPath $lineInfoSassOutput |
        Out-Null

    Invoke-NativeCapture `
        -Command "nvdisasm" `
        -Arguments @(
            "-c",
            "-g",
            "-hex",
            "-plr",
            "-sf",
            $runtimeCubinPath
        ) `
        -OutputPath $detailedSassOutput |
        Out-Null

    Assert-NonEmptyFile `
        -Path $lineInfoSassOutput `
        -Description "Runtime line-info SASS"

    Assert-NonEmptyFile `
        -Path $detailedSassOutput `
        -Description "Runtime detailed SASS"

    # ---------------------------------------------------------------------
    # Separately compiled reference CUBIN.
    # ---------------------------------------------------------------------
    #
    # This is not used as the canonical runtime disassembly. It is retained
    # so that the separately compiled CUBIN can later be compared against the
    # executable's embedded runtime CUBIN.

    Invoke-NativeCapture `
        -Command "cuobjdump" `
        -Arguments @(
            "--dump-sass",
            $referenceCubinPath
        ) `
        -OutputPath $referenceSassOutput |
        Out-Null

    Assert-NonEmptyFile `
        -Path $referenceSassOutput `
        -Description "Reference CUBIN SASS"

    # ---------------------------------------------------------------------
    # Verify that required kernels exist in the canonical runtime SASS.
    # ---------------------------------------------------------------------

    foreach ($kernelName in $requiredKernelNames) {
        $kernelFound =
            Select-String `
                -LiteralPath $canonicalSassOutput `
                -SimpleMatch `
                -Pattern $kernelName `
                -Quiet

        if (-not $kernelFound) {
            throw (
                "Kernel was not found in canonical runtime SASS: " +
                $kernelName
            )
        }
    }

    # ---------------------------------------------------------------------
    # Analyze canonical runtime SASS.
    # ---------------------------------------------------------------------

    Invoke-NativeCapture `
        -Command "python" `
        -Arguments @(
            $analyzerPath,
            "--input",
            $canonicalSassOutput,
            "--output-dir",
            $binaryDir
        ) `
        -OutputPath $canonicalAnalyzerConsole |
        Out-Null

    # Analyze the separately compiled reference CUBIN independently.
    # The next analyze_sass.py revision can compare the two JSON summaries.

    Invoke-NativeCapture `
        -Command "python" `
        -Arguments @(
            $analyzerPath,
            "--input",
            $referenceSassOutput,
            "--output-dir",
            $referenceAnalysisDir
        ) `
        -OutputPath $referenceAnalyzerConsole |
        Out-Null

    $requiredCanonicalOutputs = @(
        (Join-Path $binaryDir "probe_ffma_filtered.sass.txt"),
        (Join-Path $binaryDir "sass_summary.txt"),
        (Join-Path $binaryDir "sass_summary.json")
    )

    foreach ($requiredOutput in $requiredCanonicalOutputs) {
        Assert-NonEmptyFile `
            -Path $requiredOutput `
            -Description "Canonical SASS analysis output"
    }

    # ---------------------------------------------------------------------
    # Collection manifest
    # ---------------------------------------------------------------------

    $outputFiles = @(
        $canonicalPtxOutput,
        $canonicalSassOutput,
        $resourceUsageOutput,
        $runtimeCubinPath,
        $lineInfoSassOutput,
        $detailedSassOutput,
        $referenceSassOutput,
        (Join-Path $binaryDir "probe_ffma_filtered.sass.txt"),
        (Join-Path $binaryDir "sass_summary.txt"),
        (Join-Path $binaryDir "sass_summary.json")
    )

    $outputRecords =
        @(
            foreach ($outputFile in $outputFiles) {
                Get-FileRecord -Path $outputFile
            }
        )

    $collectionManifest = [ordered]@{
        schema_version = 1
        generated_at   = (Get-Date).ToString("o")
        architecture   = "sm_$Arch"

        canonical_runtime = [ordered]@{
            executable = Get-FileRecord -Path $exePath
            extracted_cubin =
                Get-FileRecord -Path $runtimeCubinPath
            sass_source =
                "cuobjdump output from probe_ffma.exe"
            detailed_disassembly_source =
                "CUBIN extracted from probe_ffma.exe"
        }

        reference_artifact = [ordered]@{
            cubin =
                Get-FileRecord -Path $referenceCubinPath
            runtime_identity = $false
        }

        outputs = $outputRecords
    }

    $collectionManifestPath =
        Join-Path $binaryDir "binary_collection_manifest.json"

    $collectionManifest |
        ConvertTo-Json -Depth 8 |
        Set-Content `
            -LiteralPath $collectionManifestPath `
            -Encoding UTF8

    Write-Host ""
    Write-Host (
        "Binary outputs collected successfully."
    ) -ForegroundColor Green

    Write-Host "  Architecture          : sm_$Arch"
    Write-Host "  Runtime executable    : $exePath"
    Write-Host "  Extracted runtime CUBIN: $runtimeCubinPath"
    Write-Host "  Canonical SASS        : $canonicalSassOutput"
    Write-Host "  Detailed runtime SASS : $detailedSassOutput"
    Write-Host "  Reference CUBIN SASS  : $referenceSassOutput"
    Write-Host "  Output directory      : $binaryDir"
    Write-Host "  Collection manifest   : $collectionManifestPath"
}
finally {
    Pop-Location
}