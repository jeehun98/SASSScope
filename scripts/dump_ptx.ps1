$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$exe = Join-Path $root "build\sassscope.exe"
$out = Join-Path $root "artifacts\sassscope.ptx.txt"
cuobjdump --dump-ptx $exe | Tee-Object -FilePath $out
Write-Host "`nSaved: $out"
