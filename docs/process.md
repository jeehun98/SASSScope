# SASS Probe 실행 과정

## 목적

의존 FFMA와 8개 독립 accumulator FFMA를 같은 명령어 수로 생성한 뒤,
PTX·SASS·리소스 사용량·실행 cycle을 함께 확인한다.

핵심 검증 순서는 다음과 같다.

```text
도구 확인
→ 실행 파일과 CUBIN 빌드
→ PTX/SASS/리소스 출력
→ SASS 정적 검사
→ GPU 반복 실행
→ 통계 및 오류 검사
→ 선택적으로 Nsight Compute 수집
```

## 1. 프로젝트 위치로 이동

```powershell
cd C:\path\to\SASSScope_sass_probe_example
```

## 2. 도구 확인

```powershell
powershell -ExecutionPolicy Bypass -File scripts\check_tools.ps1
```

확인 대상:

```text
nvcc
cuobjdump
nvdisasm
python
nvidia-smi (선택)
ncu (선택)
cl.exe 또는 Visual Studio host compiler 환경
```

## 3. 빌드

RTX 3070 등 `sm_86` 장치:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Arch 86 -Clean
```

생성 파일:

```text
build/probe_ffma.exe
build/probe_kernels_sm86.cubin
results/build/probe_ffma_build.txt
results/build/probe_kernels_cubin_build.txt
```

빌드 로그에서 우선 확인할 항목:

```text
Used N registers
spill stores
spill loads
stack frame
```

FFMA 프로브에서는 spill load/store가 0이어야 한다.

## 4. PTX·SASS·리소스 출력

```powershell
powershell -ExecutionPolicy Bypass `
  -File scripts\collect_binary_outputs.ps1 `
  -Arch 86
```

생성 파일:

```text
results/binary/probe_ffma.ptx.txt
results/binary/probe_ffma_full.sass.txt
results/binary/probe_ffma_filtered.sass.txt
results/binary/probe_ffma_resource_usage.txt
results/binary/probe_ffma_lineinfo.sass.txt
results/binary/probe_ffma_detailed.sass.txt
results/binary/sass_summary.txt
results/binary/sass_summary.json
```

`sass_summary.txt`에서 확인할 조건:

```text
probe_dependent_ffma
  Static FFMA count: 32
  accumulator: 1개
  CS2R: 2개
  measured-region LD/ST: 0

probe_independent_ffma_8
  Static FFMA count: 32
  accumulator: 8개
  CS2R: 2개
  measured-region LD/ST: 0
```

또한 `Timer start window`를 확인해 accumulator 초기화 명령이 첫 `CS2R` 뒤에
들어가지 않았는지 확인한다.

## 5. 반복 실행

```powershell
powershell -ExecutionPolicy Bypass `
  -File scripts\run_probe.ps1 `
  -Samples 100 `
  -Warmups 10
```

생성 파일:

```text
results/runtime/runtime_raw.csv
results/runtime/runtime_summary.txt
results/runtime/runtime_check.txt
results/runtime/metadata.json
```

기본 확인 관계:

```text
Dependent median cycles/instruction
>
Independent-8 median cycles/instruction
```

이 관계가 나타나지 않으면 다음을 점검한다.

```text
SASS의 accumulator 의존 구조
첫 번째와 마지막 CS2R 위치
측정 구간 내 load/store
register spill
GPU clock 변동
컴파일 대상 아키텍처
```

## 6. Nsight Compute 수집(선택)

```powershell
powershell -ExecutionPolicy Bypass -File scripts\profile_ncu.ps1
```

생성 파일:

```text
results/profiler/probe_ffma_profile.ncu-rep
results/profiler/probe_ffma_ncu_raw.csv
results/profiler/probe_ffma_ncu_sass.txt
```

카운터 접근 권한 오류가 나면 Windows 관리자 권한, NVIDIA 제어판의 개발자 설정,
또는 시스템의 GPU performance counter 접근 정책을 확인한다.

## 7. 전체 실행

Nsight Compute 제외:

```powershell
powershell -ExecutionPolicy Bypass `
  -File scripts\run_all.ps1 `
  -Arch 86 `
  -Samples 100 `
  -Warmups 10 `
  -Clean
```

Nsight Compute 포함:

```powershell
powershell -ExecutionPolicy Bypass `
  -File scripts\run_all.ps1 `
  -Arch 86 `
  -Samples 100 `
  -Warmups 10 `
  -Clean `
  -WithNcu
```
