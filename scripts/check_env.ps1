$ErrorActionPreference = "Continue"
Write-Host "=== NVIDIA driver / GPU ==="
nvidia-smi
Write-Host "`n=== CUDA compiler ==="
nvcc --version
Write-Host "`n=== CMake ==="
cmake --version
Write-Host "`n=== Ninja ==="
ninja --version
Write-Host "`n=== Visual C++ compiler ==="
where.exe cl
