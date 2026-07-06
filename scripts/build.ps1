$ErrorActionPreference = "Stop"
cmake -S . -B build -G Ninja `
  -DCMAKE_BUILD_TYPE=Release `
  -DCMAKE_CUDA_ARCHITECTURES=86
cmake --build build --config Release
