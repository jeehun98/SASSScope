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

function Get-ArtifactRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Artifact was not found: $Path"
    }

    $item = Get-Item -LiteralPath $Path

    if ($item.Length -eq 0) {
        throw "Artifact is empty: $Path"
    }

    $hash = Get-FileHash `
        -LiteralPath $Path `
        -Algorithm SHA256

    return [ordered]@{
        path       = $item.FullName
        size_bytes = $item.Length
        sha256     = $hash.Hash.ToLowerInvariant()
    }
}

function Get-SourceRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Source file was not found: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    $hash = Get-FileHash `
        -LiteralPath $Path `
        -Algorithm SHA256

    return [ordered]@{
        path   = $item.FullName
        sha256 = $hash.Hash.ToLowerInvariant()
    }
}

function Remove-FileIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item `
            -LiteralPath $Path `
            -Force
    }
}

$root = Get-ProjectRoot

Push-Location $root

try {
    Require-Command "nvcc" | Out-Null

    $buildDir = Join-Path $root "build"
    $resultBuildDir = Join-Path $root "results/build"

    Ensure-Directory $buildDir
    Ensure-Directory $resultBuildDir

    # -------------------------------------------------------------------------
    # Paths
    # -------------------------------------------------------------------------

    $exePath =
        Join-Path $buildDir "probe_ffma.exe"

    # Separately compiled comparison/reference CUBIN.
    #
    # The actual runtime SASS must be extracted from probe_ffma.exe.
    # This standalone CUBIN is retained for nvdisasm comparison and validation.
    $referenceCubinPath =
        Join-Path $buildDir "probe_kernels_sm$Arch.cubin"

    # Standalone PTX used for CUDA -> PTX lowering inspection.
    $referencePtxPath =
        Join-Path $buildDir "probe_kernels_compute$Arch.ptx"

    $includeDir =
        Join-Path $root "include"

    $headerPath =
        Join-Path $includeDir "probe_kernels.cuh"

    $mainSource =
        Join-Path $root "src/main.cu"

    $kernelSource =
        Join-Path $root "src/probe_kernels.cu"

    $exeBuildLog =
        Join-Path $resultBuildDir "probe_ffma_build.txt"

    $cubinBuildLog =
        Join-Path $resultBuildDir "probe_kernels_cubin_build.txt"

    $ptxBuildLog =
        Join-Path $resultBuildDir "probe_kernels_ptx_build.txt"

    $manifestPath =
        Join-Path $resultBuildDir "build_manifest.json"

    # -------------------------------------------------------------------------
    # Validate source layout
    # -------------------------------------------------------------------------

    foreach ($sourcePath in @(
        $headerPath,
        $mainSource,
        $kernelSource
    )) {
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Required source file was not found: $sourcePath"
        }
    }

    if (-not (Test-Path -LiteralPath $includeDir -PathType Container)) {
        throw "Include directory was not found: $includeDir"
    }

    # -------------------------------------------------------------------------
    # Clean
    # -------------------------------------------------------------------------

    if ($Clean) {
        Write-Host "Cleaning build directory: $buildDir"

        Get-ChildItem `
            -LiteralPath $buildDir `
            -Force `
            -ErrorAction SilentlyContinue |
            Remove-Item `
                -Force `
                -Recurse

        Ensure-Directory $buildDir
    }

    # Remove target artifacts before building so a failed build cannot leave
    # an older binary that appears to be the newly generated result.
    Remove-FileIfPresent -Path $exePath
    Remove-FileIfPresent -Path $referenceCubinPath
    Remove-FileIfPresent -Path $referencePtxPath
    Remove-FileIfPresent -Path $manifestPath

    # -------------------------------------------------------------------------
    # Common device compilation options
    # -------------------------------------------------------------------------

    $gpuCodeArgument =
        "-gencode=arch=compute_$Arch,code=sm_$Arch"

    # These arguments define the device-code policy shared by the runtime EXE
    # and standalone reference CUBIN.
    $deviceCommonArguments = @(
        "-std=c++17"
        "-O3"
        "-lineinfo"

        # Generate precompiled machine code for the selected architecture.
        $gpuCodeArgument

        # Print ptxas register, spill, stack-frame and memory usage.
        "-Xptxas=-v"

        # Make the floating-point contraction policy explicit.
        "--fmad=true"

        "-I$includeDir"
    )

    # Host-only compiler options are relevant to the executable build.
    $hostCompilerArguments = @(
        "-Xcompiler=/utf-8"
        "-Xcompiler=/EHsc"
    )

    # -------------------------------------------------------------------------
    # Canonical runtime executable
    # -------------------------------------------------------------------------
    #
    # This is the artifact actually executed by run_probe.ps1.
    #
    # Static conclusions about runtime machine code must ultimately use:
    #
    #   cuobjdump --dump-sass build/probe_ffma.exe
    #
    # or an ELF/CUBIN extracted from this executable.

    $exeArguments =
        $deviceCommonArguments +
        $hostCompilerArguments +
        @(
            $mainSource
            $kernelSource
            "-o"
            $exePath
        )

    Invoke-NativeCapture `
        -Command "nvcc" `
        -Arguments $exeArguments `
        -OutputPath $exeBuildLog |
        Out-Null

    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "Executable was not generated: $exePath"
    }

    # -------------------------------------------------------------------------
    # Reference standalone CUBIN
    # -------------------------------------------------------------------------
    #
    # This uses the same device compilation options as the EXE, but it is still
    # produced by a separate nvcc invocation. It must not automatically be
    # treated as identical to the CUBIN embedded in the runtime executable.

    $cubinArguments =
        $deviceCommonArguments +
        @(
            "--cubin"
            $kernelSource
            "-o"
            $referenceCubinPath
        )

    Invoke-NativeCapture `
        -Command "nvcc" `
        -Arguments $cubinArguments `
        -OutputPath $cubinBuildLog |
        Out-Null

    if (-not (
        Test-Path `
            -LiteralPath $referenceCubinPath `
            -PathType Leaf
    )) {
        throw "Reference CUBIN was not generated: $referenceCubinPath"
    }

    # -------------------------------------------------------------------------
    # Reference standalone PTX
    # -------------------------------------------------------------------------
    #
    # PTX generation does not invoke ptxas, so -Xptxas=-v and the sm_XX
    # gencode option are intentionally not included here.

    $ptxArguments = @(
        "-std=c++17"
        "-O3"
        "-lineinfo"
        "--fmad=true"

        "-arch=compute_$Arch"
        "-I$includeDir"

        "--ptx"
        $kernelSource
        "-o"
        $referencePtxPath
    )

    Invoke-NativeCapture `
        -Command "nvcc" `
        -Arguments $ptxArguments `
        -OutputPath $ptxBuildLog |
        Out-Null

    if (-not (
        Test-Path `
            -LiteralPath $referencePtxPath `
            -PathType Leaf
    )) {
        throw "Reference PTX was not generated: $referencePtxPath"
    }

    # -------------------------------------------------------------------------
    # Artifact records
    # -------------------------------------------------------------------------

    $exeRecord =
        Get-ArtifactRecord -Path $exePath

    $cubinRecord =
        Get-ArtifactRecord -Path $referenceCubinPath

    $ptxRecord =
        Get-ArtifactRecord -Path $referencePtxPath

    $sourceRecords = @(
        Get-SourceRecord -Path $headerPath
        Get-SourceRecord -Path $mainSource
        Get-SourceRecord -Path $kernelSource
    )

    # -------------------------------------------------------------------------
    # Build manifest
    # -------------------------------------------------------------------------

    $manifest = [ordered]@{
        schema_version = 2
        generated_at   = (Get-Date).ToString("o")

        architecture = [ordered]@{
            compute = "compute_$Arch"
            machine = "sm_$Arch"
        }

        artifact_policy = [ordered]@{
            canonical_runtime_artifact =
                "probe_ffma.exe"

            canonical_sass_source =
                "cuobjdump output or embedded CUBIN extracted from probe_ffma.exe"

            reference_cubin =
                "probe_kernels_sm$Arch.cubin"

            reference_ptx =
                "probe_kernels_compute$Arch.ptx"

            reference_cubin_is_runtime_identity =
                $false

            reference_ptx_is_runtime_identity =
                $false
        }

        sources = $sourceRecords

        nvcc_arguments = [ordered]@{
            device_common  = $deviceCommonArguments
            host_compiler  = $hostCompilerArguments
            executable     = $exeArguments
            reference_cubin = $cubinArguments
            reference_ptx   = $ptxArguments
        }

        artifacts = [ordered]@{
            executable = $exeRecord

            reference_cubin = $cubinRecord

            reference_ptx = $ptxRecord
        }

        logs = [ordered]@{
            executable_build =
                $exeBuildLog

            reference_cubin_build =
                $cubinBuildLog

            reference_ptx_build =
                $ptxBuildLog
        }
    }

    $manifest |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -LiteralPath $manifestPath `
            -Encoding UTF8

    # -------------------------------------------------------------------------
    # Console summary
    # -------------------------------------------------------------------------

    Write-Host "`nBuild completed." -ForegroundColor Green

    Write-Host "  Architecture       : sm_$Arch"

    Write-Host ""
    Write-Host "  Canonical EXE       : $exePath"
    Write-Host "  EXE size            : $($exeRecord.size_bytes) bytes"
    Write-Host "  EXE SHA-256         : $($exeRecord.sha256)"

    Write-Host ""
    Write-Host "  Reference CUBIN     : $referenceCubinPath"
    Write-Host "  CUBIN size          : $($cubinRecord.size_bytes) bytes"
    Write-Host "  CUBIN SHA-256       : $($cubinRecord.sha256)"

    Write-Host ""
    Write-Host "  Reference PTX       : $referencePtxPath"
    Write-Host "  PTX size            : $($ptxRecord.size_bytes) bytes"
    Write-Host "  PTX SHA-256         : $($ptxRecord.sha256)"

    Write-Host ""
    Write-Host "  Build logs          : $resultBuildDir"
    Write-Host "  Build manifest      : $manifestPath"

    Write-Host ""
    Write-Host (
        "Static runtime conclusions must use SASS extracted from the EXE."
    ) -ForegroundColor Yellow

    Write-Host (
        "The standalone CUBIN is a separately compiled comparison artifact."
    ) -ForegroundColor Yellow

    Write-Host (
        "The standalone PTX is used for CUDA-to-PTX lowering inspection."
    ) -ForegroundColor Yellow
}
finally {
    Pop-Location
}