$ErrorActionPreference = "Stop"
$exe = Join-Path $PSScriptRoot "..\build\sassscope.exe"
& $exe 32
