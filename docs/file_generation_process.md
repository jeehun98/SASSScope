# SASS Probe 파일 생성 표준 절차

## 1. 문서 목적

이 문서는 새로운 GPU 프로브 코드를 작성할 때마다 동일한 절차로 다음 결과를 생성하기 위한 기준 문서다.

```text
환경 정보
→ 실행 파일·CUBIN
→ PTX
→ 전체 SASS
→ 상세 SASS
→ 리소스 사용량
→ SASS 정적 분석
→ 반복 실행 결과
→ 실행 통계
→ Nsight Compute 보고서
→ NCU raw CSV
→ NCU SASS 출력
```

핵심 원칙은 다음과 같다.

> 새 프로브를 추가하더라도 코드 내용만 바꾸고, 빌드·출력 생성·검증·프로파일링 과정은 동일하게 유지한다.

이렇게 해야 서로 다른 명령어와 실험 결과를 같은 기준으로 비교할 수 있다.

---

# 2. 기준 프로젝트 구조

```text
SASSScope_sass_probe_example/
├─ build/
│  ├─ probe_ffma.exe
│  └─ probe_kernels_sm86.cubin
│
├─ docs/
│  ├─ error_checklist.md
│  ├─ process.md
│  └─ file_generation_process.md
│
├─ include/
│  └─ probe_kernels.cuh
│
├─ results/
│  ├─ binary/
│  ├─ build/
│  ├─ environment/
│  ├─ profiler/
│  └─ runtime/
│
├─ scripts/
│  ├─ build.ps1
│  ├─ check_tools.ps1
│  ├─ collect_binary_outputs.ps1
│  ├─ common.ps1
│  ├─ profile_ncu.ps1
│  ├─ run_all.ps1
│  └─ run_probe.ps1
│
├─ src/
│  ├─ main.cu
│  └─ probe_kernels.cu
│
├─ tools/
│  ├─ analyze_runtime.py
│  └─ analyze_sass.py
│
└─ README.md
```

---

# 3. 각 파일의 역할

## 3.1 소스 파일

### `include/probe_kernels.cuh`

다음 내용을 정의한다.

```text
반복 횟수
한 반복당 목표 명령어 수
전체 동적 명령어 수
프로브 커널 선언
```

예:

```cpp
inline constexpr int kOuterIterations = 4096;
inline constexpr int kInstructionsPerIteration = 32;
inline constexpr int kTotalInstructions =
    kOuterIterations * kInstructionsPerIteration;
```

새 프로브를 추가할 때 커널 선언과 반복 관련 상수를 먼저 이 파일에서 정리한다.

---

### `src/probe_kernels.cu`

실제 측정 대상 CUDA 커널을 구현한다.

예:

```text
probe_timer_only
probe_dependent_ffma
probe_independent_ffma_8
```

이 파일에서 통제해야 하는 요소는 다음과 같다.

```text
목표 명령어
레지스터 의존성
accumulator 수
반복 구조
clock64 측정 위치
결과 저장 위치
컴파일러 최적화 방지
```

---

### `src/main.cu`

다음을 담당한다.

```text
GPU 초기화
device memory 할당
warm-up
샘플 반복 실행
커널 실행 순서
cycle 수집
checksum 수집
runtime_raw.csv 생성
runtime_summary.txt 생성
metadata.json 생성
```

새 프로브를 추가하면 다음 부분을 수정한다.

```text
커널 launch 함수
CSV의 kernel 이름
통계 그룹
summary 출력
metadata 항목
```

---

## 3.2 분석 파일

### `tools/analyze_sass.py`

`cuobjdump --dump-sass` 결과를 읽고 다음 파일을 생성한다.

```text
probe_ffma_filtered.sass.txt
sass_summary.txt
sass_summary.json
```

검사 대상:

```text
필요한 커널 존재 여부
목표 opcode 개수
CS2R 개수
accumulator 레지스터 수
측정 구간 내 LD/ST
타이머 주변 명령어
예상하지 않은 setup 명령어
```

새 프로브를 추가하면 다음을 수정해야 한다.

```text
expected 함수 이름
목표 opcode
예상 정적 명령어 수
예상 accumulator 수
필터링할 opcode
```

---

### `tools/analyze_runtime.py`

`runtime_raw.csv`를 읽고 다음 파일을 생성한다.

```text
runtime_check.txt
```

검사 대상:

```text
필수 kernel 그룹 존재 여부
샘플 수
cycles/instruction 유효성
checksum 유한성
dependent와 independent 관계
```

새 프로브를 추가하면 커널 이름과 기대 관계를 수정한다.

---

# 4. 전체 실행 순서

표준 실행 순서는 다음과 같다.

```text
1. 프로젝트 위치 이동
2. 도구·환경 확인
3. EXE와 CUBIN 빌드
4. PTX·SASS·리소스 출력
5. SASS 자동 분석
6. 반복 실행
7. runtime 자동 분석
8. Nsight Compute 보고서 생성
9. NCU 보고서를 CSV와 SASS 텍스트로 변환
10. 결과 파일 최종 확인
```

---

# 5. 1단계: 프로젝트 위치로 이동

```powershell
cd C:\path\to\SASSScope_sass_probe_example
```

모든 스크립트는 프로젝트 루트를 기준으로 상대 경로를 계산하므로, 프로젝트 내부에서 실행하는 것이 안전하다.

---

# 6. 2단계: 도구와 환경 정보 생성

## 실행 명령

```powershell
powershell -ExecutionPolicy Bypass `
  -File scripts\check_tools.ps1
```

## 내부에서 확인하는 도구

```text
nvcc
cuobjdump
nvdisasm
python
cl.exe
nvidia-smi
ncu
```

필수 도구:

```text
nvcc
cuobjdump
nvdisasm
python
```

선택 도구:

```text
nvidia-smi
ncu
```

`cl.exe`가 PATH에 없으면 Windows에서 `nvcc`가 host compiler를 찾지 못할 수 있다. 이 경우 다음 환경에서 실행한다.

```text
x64 Native Tools Command Prompt for VS 2022
```

## 생성 파일

| 생성 파일 | 생성 명령 |
|---|---|
| `results/environment/nvcc_version.txt` | `nvcc --version` |
| `results/environment/cuobjdump_version.txt` | `cuobjdump --version` |
| `results/environment/nvdisasm_version.txt` | `nvdisasm --version` |
| `results/environment/python_version.txt` | `python --version` |
| `results/environment/gpu_environment.txt` | `nvidia-smi` |
| `results/environment/ncu_version.txt` | `ncu --version` |

## 확인 기준

```text
모든 필수 도구가 PATH에서 발견됨
GPU 정보가 정상 출력됨
대상 CUDA Toolkit 버전이 의도한 버전과 일치함
ncu 버전이 기록됨
```

---

# 7. 3단계: EXE와 CUBIN 빌드

## 실행 명령

RTX 3070과 같은 `sm_86` 대상:

```powershell
powershell -ExecutionPolicy Bypass `
  -File scripts\build.ps1 `
  -Arch 86 `
  -Clean
```

## EXE 빌드 명령

스크립트 내부에서는 개념적으로 다음 명령을 실행한다.

```powershell
nvcc `
  -std=c++17 `
  -O3 `
  -lineinfo `
  -Xptxas=-v `
  -arch=sm_86 `
  -I<project>\include `
  <project>\src\main.cu `
  <project>\src\probe_kernels.cu `
  -o <project>\build\probe_ffma.exe
```

## CUBIN 빌드 명령

```powershell
nvcc `
  -std=c++17 `
  -O3 `
  -lineinfo `
  -Xptxas=-v `
  -arch=sm_86 `
  -I<project>\include `
  --cubin `
  <project>\src\probe_kernels.cu `
  -o <project>\build\probe_kernels_sm86.cubin
```

`cuobjdump`는 host 실행 파일에 포함된 CUDA 코드와 PTX를 읽을 수 있고, `nvdisasm`은 standalone CUBIN을 입력으로 받아 더 풍부한 출력 옵션을 제공한다. 따라서 EXE와 CUBIN을 둘 다 생성한다. citeturn636529view1

## 생성 파일

| 생성 파일 | 목적 |
|---|---|
| `build/probe_ffma.exe` | 실제 GPU 실행과 `cuobjdump` 입력 |
| `build/probe_kernels_sm86.cubin` | `nvdisasm` 입력 |
| `results/build/probe_ffma_build.txt` | EXE 빌드 로그 |
| `results/build/probe_kernels_cubin_build.txt` | CUBIN 빌드 로그 |

## 빌드 로그 확인 항목

```text
Used N registers
N bytes stack frame
N bytes spill stores
N bytes spill loads
constant memory 사용량
```

프로브의 측정 구간을 순수하게 유지하려면 일반적으로 다음이 바람직하다.

```text
spill stores = 0
spill loads  = 0
```

spill이 발생하면 local memory load/store가 측정에 섞일 수 있다.

---

# 8. 4단계: PTX·SASS·리소스 파일 생성

## 실행 명령

```powershell
powershell -ExecutionPolicy Bypass `
  -File scripts\collect_binary_outputs.ps1 `
  -Arch 86
```

이 단계는 다음 순서로 진행된다.

```text
PTX 추출
→ 전체 SASS 추출
→ 리소스 사용량 추출
→ line info SASS 생성
→ 상세 SASS 생성
→ Python 정적 분석 실행
```

---

## 8.1 PTX 출력

### 실행 명령

```powershell
cuobjdump --dump-ptx build\probe_ffma.exe
```

### 생성 파일

```text
results/binary/probe_ffma.ptx.txt
```

### 확인 내용

```text
목표 PTX 명령 존재 여부
데이터 타입
반복 구조
예상하지 않은 변환
load/store 추가 여부
```

---

## 8.2 전체 SASS 출력

### 실행 명령

```powershell
cuobjdump --dump-sass build\probe_ffma.exe
```

### 생성 파일

```text
results/binary/probe_ffma_full.sass.txt
```

### 확인 내용

```text
목표 SASS opcode
커널 이름
레지스터 의존 관계
정적 명령어 수
CS2R 위치
BRA·ISETP·IADD3 루프 구조
측정 구간 내 LD/ST
```

`cuobjdump`는 host executable 안에 포함된 cubin과 PTX를 추출하고 디스어셈블할 수 있다. citeturn636529view1

---

## 8.3 리소스 사용량 출력

### 실행 명령

```powershell
cuobjdump --dump-resource-usage build\probe_ffma.exe
```

### 생성 파일

```text
results/binary/probe_ffma_resource_usage.txt
```

### 확인 내용

```text
커널별 register 수
shared memory
local memory
stack
constant memory
```

특히 다음 관계를 빌드 로그와 함께 확인한다.

```text
ptxas spill load/store
+
resource usage의 local memory
+
SASS 측정 구간의 LDL/STL
```

셋 중 하나라도 예상과 다르면 프로브가 메모리 접근에 의해 오염됐을 가능성이 있다.

---

## 8.4 소스 줄 정보가 포함된 SASS 출력

### 실행 명령

```powershell
nvdisasm `
  -c `
  -g `
  -sf `
  build\probe_kernels_sm86.cubin
```

### 생성 파일

```text
results/binary/probe_ffma_lineinfo.sass.txt
```

### 옵션 의미

```text
-c   코드 디스어셈블
-g   line information 출력
-sf  함수별 분리 출력
```

### 확인 내용

```text
CUDA 소스 줄과 SASS의 대응
inline PTX와 최종 명령의 대응
반복문이 어떤 SASS 구간으로 변환됐는지
```

---

## 8.5 명령 인코딩과 레지스터 생명주기가 포함된 SASS 출력

### 실행 명령

```powershell
nvdisasm `
  -c `
  -hex `
  -plr `
  -sf `
  build\probe_kernels_sm86.cubin
```

### 생성 파일

```text
results/binary/probe_ffma_detailed.sass.txt
```

### 옵션 의미

```text
-c    코드 디스어셈블
-hex  instruction encoding 표시
-plr  register life range 표시
-sf   함수별 분리 출력
```

`nvdisasm`은 standalone CUBIN을 대상으로 동작하고, `cuobjdump`보다 제어 흐름 및 상세 표시 기능이 풍부하다. citeturn636529view1

### 확인 내용

```text
accumulator 생명주기
임시 레지스터 수
명령어 인코딩
루프 전체에서 살아 있는 레지스터
```

---

# 9. 5단계: SASS 자동 분석 파일 생성

`collect_binary_outputs.ps1`의 마지막 단계에서 다음 명령을 실행한다.

```powershell
python tools\analyze_sass.py `
  --input results\binary\probe_ffma_full.sass.txt `
  --output-dir results\binary
```

## 생성 파일

| 생성 파일 | 내용 |
|---|---|
| `results/binary/sass_analyzer_console.txt` | Python 분석기 콘솔 출력 |
| `results/binary/probe_ffma_filtered.sass.txt` | 주요 opcode만 남긴 축약 SASS |
| `results/binary/sass_summary.txt` | 사람이 읽는 정적 분석 요약 |
| `results/binary/sass_summary.json` | 기계 판독용 정적 분석 결과 |

## `sass_summary.txt` 확인 항목

```text
목표 커널이 모두 존재하는가
정적 FFMA 수가 예상과 일치하는가
CS2R이 2개 존재하는가
의존 accumulator 수가 맞는가
독립 accumulator 수가 맞는가
측정 구간 안에 LD/ST가 없는가
시작 CS2R 뒤에 초기화 명령이 들어오지 않았는가
Overall warning count가 0인가
```

예상 형태:

```text
[probe_dependent_ffma]
Static FFMA count        : 32
CS2R count               : 2
Accumulator registers    : 1개
Measured-region LD/ST    : 0

[probe_independent_ffma_8]
Static FFMA count        : 32
CS2R count               : 2
Accumulator registers    : 8개
Measured-region LD/ST    : 0

Overall warning count: 0
```

---

# 10. 6단계: 반복 실행 파일 생성

## 실행 명령

```powershell
powershell -ExecutionPolicy Bypass `
  -File scripts\run_probe.ps1 `
  -Samples 100 `
  -Warmups 10
```

## 실행 파일에 전달되는 인수

스크립트는 개념적으로 다음처럼 실행한다.

```powershell
build\probe_ffma.exe `
  results\runtime `
  100 `
  10
```

인수:

```text
1번 인수: 결과 디렉터리
2번 인수: 측정 sample 수
3번 인수: warm-up 수
```

## 실행 순서

```text
GPU 초기화
→ memory 할당
→ dependent/independent warm-up
→ sample 반복
→ timer-only 측정
→ dependent와 independent 측정
→ 실행 순서 교대
→ CSV 저장
→ 통계 계산
→ metadata 저장
```

현재 예제는 열·클럭의 단조 변화가 한 커널에만 편향되는 것을 줄이기 위해 실행 순서를 교대한다.

```text
짝수 run:
dependent → independent

홀수 run:
independent → dependent
```

---

## 10.1 원시 실행 결과

### 생성 파일

```text
results/runtime/runtime_raw.csv
```

### 생성 주체

```text
build/probe_ffma.exe
```

### 형식

```csv
run,kernel,total_instructions,total_cycles,cycles_per_instruction,checksum
0,timer_only,0,20,,1.0001
0,dependent,131072,524610,4.002457,1.027639627
0,independent_8,131072,131401,1.002510,8.221864700
```

### 확인 내용

```text
run 번호가 연속적인가
각 run에 모든 kernel이 존재하는가
total_instructions가 예상값과 같은가
total_cycles가 양수인가
cycles_per_instruction이 유효한가
checksum이 NaN·Inf가 아닌가
```

---

## 10.2 실행 통계

### 생성 파일

```text
results/runtime/runtime_summary.txt
```

### 생성 주체

```text
build/probe_ffma.exe
```

### 포함 내용

```text
GPU 이름
compute capability
SM 수
warp size
reported clock
CUDA driver/runtime 버전
sample 수
warm-up 수
명령어 수
minimum
median
mean
maximum
standard deviation
dependent/independent ratio
checksum
```

### 핵심 확인 관계

```text
Dependent median cycles/instruction
>
Independent-8 median cycles/instruction
```

---

## 10.3 runtime metadata

### 생성 파일

```text
results/runtime/metadata.json
```

### 생성 주체

```text
build/probe_ffma.exe
```

### 포함 내용

```text
gpu_name
compute_capability
sm_count
warp_size
reported_clock_khz
cuda_driver_version
cuda_runtime_version
outer_iterations
instructions_per_iteration
total_instructions
samples
warmups
```

이 파일은 실험 결과를 다른 GPU나 다른 컴파일 환경과 비교할 때 사용한다.

---

## 10.4 runtime 자동 검사

`run_probe.ps1`은 실행이 끝난 뒤 다음 명령을 실행한다.

```powershell
python tools\analyze_runtime.py `
  --input results\runtime\runtime_raw.csv `
  --output results\runtime\runtime_check.txt
```

### 생성 파일

| 생성 파일 | 내용 |
|---|---|
| `results/runtime/runtime_console.txt` | 실행 파일 콘솔 출력 |
| `results/runtime/runtime_analyzer_console.txt` | Python 분석기 콘솔 출력 |
| `results/runtime/runtime_check.txt` | 자동 검사 결과 |

### 확인 내용

```text
필수 kernel 그룹 존재
샘플 수 일치
checksum 유한성
dependent median > independent median
CSV 파싱 오류 없음
```

---

# 11. 7단계: Nsight Compute 파일 생성

## 11.1 실행 명령

```powershell
powershell -ExecutionPolicy Bypass `
  -File scripts\profile_ncu.ps1
```

이 스크립트는 다음 세 단계를 수행한다.

```text
1. NCU 보고서 수집
2. 보고서를 raw CSV로 변환
3. 보고서를 SASS source 페이지로 변환
```

Nsight Compute CLI는 kernel filter, launch count, 수집 section/metric, report export를 지원한다. 보고서를 저장한 뒤 `--import`로 다시 읽어 `raw`·`source` 페이지를 출력할 수 있으며, `--csv`로 후처리 가능한 형식으로 변환할 수 있다. citeturn636529view0turn153720view0turn153720view2

---

## 11.2 NCU 전용 runtime 디렉터리 생성

스크립트가 먼저 생성한다.

```text
results/profiler/
results/profiler/runtime/
```

NCU 실행 중 프로브 프로그램이 만드는 runtime 파일은 일반 runtime 결과와 섞이지 않고 다음 위치에 저장된다.

```text
results/profiler/runtime/
```

---

## 11.3 NCU 보고서 수집

### 실제 명령 구조

```powershell
ncu `
  --set full `
  --export results\profiler\probe_ffma_profile `
  --force-overwrite `
  build\probe_ffma.exe `
  results\profiler\runtime `
  1 `
  0
```

인수 `1 0`의 의미:

```text
Samples = 1
Warmups = 0
```

NCU는 metric 수집을 위해 kernel을 여러 pass로 replay할 수 있으므로, 일반 runtime 측정처럼 100개 sample을 그대로 사용하지 않는다. 현재 스크립트는 NCU 분석용으로 sample을 1개만 실행한다. Nsight Compute는 기본적으로 `basic` set을 사용하며, `--set full`은 더 많은 section과 metric을 수집하므로 시간이 더 오래 걸리고 report 크기도 커질 수 있다. citeturn636529view0

### 옵션 의미

```text
--set full
→ full metric/section set 수집

--export <path>
→ .ncu-rep 보고서 저장

--force-overwrite
→ 기존 보고서 덮어쓰기
```

`--export`는 profile report의 출력 경로를 지정하며, `--force-overwrite`는 기존 출력 파일을 덮어쓰도록 한다. citeturn153720view0turn153720view1

### 생성 파일

```text
results/profiler/probe_ffma_profile.ncu-rep
results/profiler/ncu_collect_console.txt
```

`ncu_collect_console.txt`에는 NCU 수집 과정과 오류 메시지가 기록된다.

---

## 11.4 NCU raw CSV 생성

### 실행 명령

```powershell
ncu `
  --import results\profiler\probe_ffma_profile.ncu-rep `
  --page raw `
  --csv
```

### 생성 파일

```text
results/profiler/probe_ffma_ncu_raw.csv
```

### 옵션 의미

```text
--import
→ 기존 .ncu-rep 보고서 읽기

--page raw
→ kernel launch별 수집 metric 전체 출력

--csv
→ CSV 형태의 콘솔 출력
```

Nsight Compute의 `raw` 페이지는 kernel launch별 수집 metric을 보여주며 `--csv`는 출력을 후처리하기 쉬운 comma-separated 형식으로 만든다. citeturn636529view0turn153720view1

### 확인 내용

```text
대상 kernel 이름
launch ID
metric 이름
metric 단위
metric 값
device 속성
launch 설정
```

---

## 11.5 NCU SASS source 출력 생성

### 실행 명령

```powershell
ncu `
  --import results\profiler\probe_ffma_profile.ncu-rep `
  --page source `
  --print-source sass
```

### 생성 파일

```text
results/profiler/probe_ffma_ncu_sass.txt
```

### 옵션 의미

```text
--page source
→ source correlation 페이지 출력

--print-source sass
→ SASS instruction view 출력
```

`--page source --print-source sass`는 profile report에 저장된 SASS와 instruction-correlated metric을 텍스트로 확인할 때 사용한다. citeturn153720view2

### 확인 내용

```text
커널별 SASS
instruction address
opcode
instruction-correlated metric
특정 SASS 위치의 stall 또는 실행 지표
```

---

# 12. NCU 결과에서 우선 확인할 항목

`probe_ffma_ncu_raw.csv`와 `probe_ffma_ncu_sass.txt`에서 다음 범주를 먼저 확인한다.

```text
실행된 kernel 이름
실행 횟수
grid/block 크기
register 수
occupancy
SM 및 SMSP cycle
FP32/FMA pipeline 활동
warp scheduler 상태
dependency 관련 stall
실행된 SASS instruction 수
SM clock 관련 값
```

정확한 metric 이름은 GPU와 Nsight Compute 버전에 따라 달라질 수 있다. 따라서 처음에는 특정 metric 몇 개만 강제로 지정하기보다 `.ncu-rep`와 raw CSV 전체를 보관한다.

---

# 13. NCU 권한 오류

대표 오류:

```text
ERR_NVGPUCTRPERM
```

의미:

```text
현재 사용자가 NVIDIA GPU performance counter에 접근할 권한이 없음
```

NVIDIA의 공식 안내에 따르면 관리자가 performance counter 접근을 허용하거나, 제한 모드에서는 관리자 권한으로 대상 프로그램을 실행해야 한다. Windows에서는 관리자 권한 실행이 해결책 중 하나다. citeturn636529view2

확인 순서:

```text
1. PowerShell을 관리자 권한으로 실행
2. ncu --version 확인
3. NVIDIA performance counter 접근 정책 확인
4. profile_ncu.ps1 다시 실행
```

NCU가 실패해도 다음 단계는 계속 사용할 수 있다.

```text
PTX
SASS
resource usage
device clock64
runtime_raw.csv
runtime_summary.txt
```

---

# 14. 전체 과정을 한 번에 실행

## NCU 제외

```powershell
powershell -ExecutionPolicy Bypass `
  -File scripts\run_all.ps1 `
  -Arch 86 `
  -Samples 100 `
  -Warmups 10 `
  -Clean
```

실행 순서:

```text
check_tools.ps1
→ build.ps1
→ collect_binary_outputs.ps1
→ run_probe.ps1
```

---

## NCU 포함

```powershell
powershell -ExecutionPolicy Bypass `
  -File scripts\run_all.ps1 `
  -Arch 86 `
  -Samples 100 `
  -Warmups 10 `
  -Clean `
  -WithNcu
```

실행 순서:

```text
check_tools.ps1
→ build.ps1
→ collect_binary_outputs.ps1
→ run_probe.ps1
→ profile_ncu.ps1
```

---

# 15. 파일별 생성 명령 요약

| 파일 | 생성 주체 또는 명령 |
|---|---|
| `results/environment/nvcc_version.txt` | `nvcc --version` |
| `results/environment/cuobjdump_version.txt` | `cuobjdump --version` |
| `results/environment/nvdisasm_version.txt` | `nvdisasm --version` |
| `results/environment/python_version.txt` | `python --version` |
| `results/environment/gpu_environment.txt` | `nvidia-smi` |
| `results/environment/ncu_version.txt` | `ncu --version` |
| `build/probe_ffma.exe` | `nvcc main.cu probe_kernels.cu` |
| `build/probe_kernels_sm86.cubin` | `nvcc --cubin probe_kernels.cu` |
| `results/build/probe_ffma_build.txt` | EXE 빌드 콘솔 캡처 |
| `results/build/probe_kernels_cubin_build.txt` | CUBIN 빌드 콘솔 캡처 |
| `results/binary/probe_ffma.ptx.txt` | `cuobjdump --dump-ptx` |
| `results/binary/probe_ffma_full.sass.txt` | `cuobjdump --dump-sass` |
| `results/binary/probe_ffma_resource_usage.txt` | `cuobjdump --dump-resource-usage` |
| `results/binary/probe_ffma_lineinfo.sass.txt` | `nvdisasm -c -g -sf` |
| `results/binary/probe_ffma_detailed.sass.txt` | `nvdisasm -c -hex -plr -sf` |
| `results/binary/probe_ffma_filtered.sass.txt` | `analyze_sass.py` |
| `results/binary/sass_summary.txt` | `analyze_sass.py` |
| `results/binary/sass_summary.json` | `analyze_sass.py` |
| `results/binary/sass_analyzer_console.txt` | `analyze_sass.py` 콘솔 캡처 |
| `results/runtime/runtime_raw.csv` | `probe_ffma.exe` |
| `results/runtime/runtime_summary.txt` | `probe_ffma.exe` |
| `results/runtime/metadata.json` | `probe_ffma.exe` |
| `results/runtime/runtime_console.txt` | `probe_ffma.exe` 콘솔 캡처 |
| `results/runtime/runtime_check.txt` | `analyze_runtime.py` |
| `results/runtime/runtime_analyzer_console.txt` | `analyze_runtime.py` 콘솔 캡처 |
| `results/profiler/probe_ffma_profile.ncu-rep` | `ncu --set full --export` |
| `results/profiler/ncu_collect_console.txt` | NCU 수집 콘솔 캡처 |
| `results/profiler/probe_ffma_ncu_raw.csv` | `ncu --import --page raw --csv` |
| `results/profiler/probe_ffma_ncu_sass.txt` | `ncu --import --page source --print-source sass` |

---

# 16. 새 프로브 작성 시 반드시 수정할 부분

새로운 명령어 프로브를 작성할 때 다음 항목을 순서대로 수정한다.

## 16.1 헤더

```text
include/probe_kernels.cuh
```

수정:

```text
커널 선언
반복 횟수
정적 명령어 수
동적 명령어 수
```

---

## 16.2 커널

```text
src/probe_kernels.cu
```

수정:

```text
목표 PTX 또는 CUDA 연산
의존 사슬
독립 accumulator variants
clock64 경계
checksum
```

---

## 16.3 실행 harness

```text
src/main.cu
```

수정:

```text
launch 함수
warm-up
sample 실행
CSV kernel 이름
summary 그룹
metadata
```

---

## 16.4 SASS 분석기

```text
tools/analyze_sass.py
```

수정:

```text
expected 함수 목록
목표 opcode
예상 정적 opcode 수
예상 accumulator 수
필터 opcode
경고 조건
```

---

## 16.5 runtime 분석기

```text
tools/analyze_runtime.py
```

수정:

```text
필수 kernel 이름
비교 대상
PASS/FAIL 관계
checksum 조건
```

---

## 16.6 파일 이름

가능하면 프로브 이름을 통일한다.

예:

```text
probe_iadd3.exe
probe_iadd3_full.sass.txt
probe_iadd3_profile.ncu-rep
```

현재 스크립트가 `probe_ffma`를 고정해서 사용하므로, 프로브가 늘어나면 다음 중 하나를 선택한다.

```text
방법 A:
프로브별 프로젝트를 복사하고 이름 변경

방법 B:
scripts에 -ProbeName 파라미터를 추가해 공통화
```

장기적으로는 방법 B가 적합하다.

---

# 17. 단계별 중단 기준

각 단계는 다음 조건을 만족해야 다음으로 넘어간다.

## 환경 확인 통과

```text
nvcc, cuobjdump, nvdisasm, python 확인
```

## 빌드 통과

```text
EXE 존재
CUBIN 존재
spill이 예상 범위
```

## SASS 통과

```text
목표 kernel 존재
목표 opcode 존재
정적 opcode 수 일치
accumulator 수 일치
CS2R 위치 정상
측정 구간 LD/ST 없음
```

## runtime 통과

```text
모든 sample 존재
checksum 유한
통계 생성
기대 성능 관계 성립
```

## NCU 통과

```text
.ncu-rep 존재
raw CSV 존재
SASS source 출력 존재
ERR_NVGPUCTRPERM 없음
```

---

# 18. 최종 확인 체크리스트

```text
[ ] environment 파일이 모두 생성됐다.
[ ] EXE와 CUBIN이 생성됐다.
[ ] ptxas 로그에서 spill을 확인했다.
[ ] PTX 파일이 생성됐다.
[ ] 전체 SASS 파일이 생성됐다.
[ ] 상세 SASS 파일이 생성됐다.
[ ] resource usage 파일이 생성됐다.
[ ] sass_summary warning count가 0이다.
[ ] runtime_raw.csv의 sample 수가 맞다.
[ ] runtime_summary.txt의 통계가 정상이다.
[ ] runtime_check.txt가 PASS다.
[ ] probe_ffma_profile.ncu-rep가 생성됐다.
[ ] probe_ffma_ncu_raw.csv가 생성됐다.
[ ] probe_ffma_ncu_sass.txt가 생성됐다.
[ ] NCU 대상 kernel이 의도한 kernel과 일치한다.
[ ] 결과 파일을 별도 실험 폴더에 보존했다.
```

---

# 19. 표준 결론

새 프로브는 다음 세 종류의 결과가 모두 생성됐을 때 기본 실험 과정이 완료된 것으로 본다.

```text
정적 결과:
PTX
SASS
resource usage
SASS summary

동적 결과:
runtime raw samples
runtime statistics
runtime validation

프로파일러 결과:
NCU report
NCU raw metrics
NCU SASS correlation
```

이 세 결과를 함께 사용해야 다음을 구분할 수 있다.

```text
소스에서 의도한 연산
실제로 생성된 기계어
실제 하드웨어에서 관측된 실행 행동
프로파일러가 관측한 pipeline·stall·resource 지표
```

따라서 이후 모든 SASS Probe 코드는 이 문서의 순서대로 생성·실행·검증한다.
