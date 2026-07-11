Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# scripts/common.ps1 기준 한 단계 위를 프로젝트 루트로 사용
$script:ProjectRoot = (
    Resolve-Path (Join-Path $PSScriptRoot "..")
).Path


function Get-ProjectRoot {
    return $script:ProjectRoot
}


function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Directory path is null or empty."
    }

    [System.IO.Directory]::CreateDirectory($Path) | Out-Null
}


function Require-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [switch]$Optional
    )

    $commandInfo = Get-Command $Name -ErrorAction SilentlyContinue

    if ($null -eq $commandInfo) {
        if ($Optional) {
            return $null
        }

        throw "Required command not found in PATH: $Name"
    }

    return $commandInfo.Source
}


function Write-Utf8Lines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$Lines = @()
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Output path is null or empty."
    }

    $parentDirectory = Split-Path -Parent $Path

    if (-not [string]::IsNullOrWhiteSpace($parentDirectory)) {
        Ensure-Directory -Path $parentDirectory
    }

    $stringLines = @(
        $Lines | ForEach-Object {
            [string]$_
        }
    )

    $text = [string]::Join(
        [Environment]::NewLine,
        $stringLines
    )

    if ($stringLines.Count -gt 0) {
        $text += [Environment]::NewLine
    }

    $utf8WithoutBom = New-Object `
        -TypeName System.Text.UTF8Encoding `
        -ArgumentList $false

    [System.IO.File]::WriteAllText(
        $Path,
        $text,
        $utf8WithoutBom
    )
}


function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [switch]$AllowFailure
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        throw "Command is null or empty."
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        throw "Output path is null or empty."
    }

    $commandInfo = Get-Command $Command -ErrorAction SilentlyContinue

    if ($null -eq $commandInfo) {
        throw "Command not found: $Command"
    }

    if ($Arguments.Count -gt 0) {
        $displayCommand = "$Command $($Arguments -join ' ')"
    }
    else {
        $displayCommand = $Command
    }

    Write-Host "`n> $displayCommand" -ForegroundColor Cyan

    $lines = @(
        & $Command @Arguments 2>&1 |
            ForEach-Object {
                [string]$_
            }
    )

    $exitCode = $LASTEXITCODE

    foreach ($line in $lines) {
        Write-Host $line
    }

    Write-Utf8Lines `
        -Path $OutputPath `
        -Lines $lines

    if (($exitCode -ne 0) -and (-not $AllowFailure)) {
        throw "Command failed with exit code $exitCode. See: $OutputPath"
    }

    return [PSCustomObject]@{
        Command    = $Command
        Arguments  = $Arguments
        ExitCode   = $exitCode
        Lines      = $lines
        OutputPath = $OutputPath
    }
}