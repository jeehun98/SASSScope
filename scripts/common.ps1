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

    # 네이티브 실행 파일만 검색
    $commandInfo = Get-Command `
        $Command `
        -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($null -eq $commandInfo) {
        throw "Native command not found: $Command"
    }

    $resolvedCommand = $commandInfo.Path

    if ([string]::IsNullOrWhiteSpace($resolvedCommand)) {
        $resolvedCommand = $Command
    }

    if ($Arguments.Count -gt 0) {
        $displayCommand = "$resolvedCommand $($Arguments -join ' ')"
    }
    else {
        $displayCommand = $resolvedCommand
    }

    Write-Host "`n> $displayCommand" -ForegroundColor Cyan

    $lines = @()
    $exitCode = -1

    # 네이티브 프로그램의 stderr가 PowerShell 실행을 중단하지 않도록
    # 이 구간에서만 ErrorActionPreference를 Continue로 변경
    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        $lines = @(
            & $resolvedCommand @Arguments 2>&1 |
                ForEach-Object {
                    if ($_ -is [System.Management.Automation.ErrorRecord]) {
                        [string]$_.Exception.Message
                    }
                    else {
                        [string]$_
                    }
                }
        )

        # 반드시 네이티브 프로세스 실행 직후 저장
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    foreach ($line in $lines) {
        Write-Host $line
    }

    Write-Utf8Lines `
        -Path $OutputPath `
        -Lines $lines

    if (($exitCode -ne 0) -and (-not $AllowFailure)) {
        throw (
            "Command failed with exit code {0}. See: {1}" -f `
                $exitCode,
                $OutputPath
        )
    }

    return [PSCustomObject]@{
        Command         = $Command
        ResolvedCommand = $resolvedCommand
        Arguments       = $Arguments
        ExitCode        = $exitCode
        Lines           = $lines
        OutputPath      = $OutputPath
    }
}