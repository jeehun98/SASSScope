$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$exe = Join-Path $root "build\sassscope.exe"
$out = Join-Path $root "artifacts\sassscope.sass.txt"
cuobjdump --dump-sass $exe | Tee-Object -FilePath $out
Write-Host "`nSaved: $out"
