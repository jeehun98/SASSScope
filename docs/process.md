# SASS Probe 실행 과정

## 1. 목적

동일한 동적 FFMA 수와 동일한 반복 구조를 갖는 다음 두 커널을 생성하고 비교한다.

```text
probe_dependent_ffma
  단일 accumulator에 연속적으로 의존하는 FFMA chain

probe_independent_ffma_8
  8개의 독립 accumulator를 round-robin으로 갱신하는 FFMA chain
```

실제 실행 파일에 포함된 machine code를 기준으로 다음 정보를 연결한다.

```text
CUDA source
→ PTX lowering
→ SASS instruction
→ register dependency graph
→ resource usage
→ elapsed SM cycles
→ Nsight Compute 실행 지표
```

이 실험의 주된 목적은 다음과 같다.

> 동일한 FFMA 수와 반복 제어 구조에서 accumulator 의존 깊이가 GPU 실행 cycle에 미치는 영향을 관찰한다.

현재 측정값에는 FFMA뿐 아니라 outer-loop 제어 명령과 최초 진입 시의 일부 setup 비용이 포함된다. 따라서 이 실험을 순수 FFMA latency 또는 일반적인 instruction CPI 측정이라고 해석하지 않는다.

---

## 2. 현재 실험 조건

기본 설정은 `include/probe_kernels.cuh`에 정의되어 있다.

```text
Outer iterations              : 4096
Static FFMA per outer body    : 32
Dynamic FFMA per probe        : 4096 × 32
                               = 131072

Independent accumulators      : 8
FFMA per accumulator/body     : 32 / 8
                               = 4
```

실행 configuration은 다음과 같다.

```text
gridDim.x     = 1
blockDim.x    = 1
active thread = 1
resident warp = 1
active lane   = 1
```

현재 프로브는 다음 형태다.

```text
single-thread
single-active-lane
FFMA dependency probe
```

`1 block × 32 threads`를 사용하는 full-warp probe는 별도의 후속 실험으로 구분한다.

---

## 3. 전체 검증 흐름

```text
실험 조건 고정
→ 도구 및 GPU 환경 확인
→ EXE·reference CUBIN·PTX 빌드
→ 빌드 artifact와 hash 기록
→ 실제 실행 EXE에서 canonical SASS 추출
→ EXE 내부 runtime CUBIN 추출
→ PTX·SASS·리소스 출력
→ measured region과 의존 그래프 정적 검사
→ GPU 반복 실행
→ cycles/FFMA 통계 및 출력값 검사
→ 선택적으로 Nsight Compute 구조 검증
→ 정적·동적 결과 통합
```

---

# 4. 프로젝트 위치로 이동

```powershell
cd C:\path\to\SASSScope
```

예시:

```powershell
cd C:\Users\owner\Desktop\SASSScope
```

---

# 5. 도구 확인

```powershell
powershell -ExecutionPolicy Bypass `
    -File scripts\check_tools.ps1
```

확인 대상:

```text
nvcc
cuobjdump
nvdisasm
python
cl.exe 또는 Visual Studio host compiler 환경
nvidia-smi    선택
ncu           선택
```

필수 도구가 없으면 이후 단계를 진행하지 않는다.

---

# 6. 빌드

RTX 3070 등 compute capability 8.6 장치에서는 다음을 실행한다.

```powershell
powershell -ExecutionPolicy Bypass `
    -File scripts\build.ps1 `
    -Arch 86 `
    -Clean
```

## 6.1 생성 artifact

```text
build/probe_ffma.exe
build/probe_kernels_sm86.cubin
build/probe_kernels_compute86.ptx
```

각 artifact의 역할은 다음과 같다.

### `probe_ffma.exe`

```text
실제로 실행되는 canonical runtime artifact
runtime cycle 측정 대상
최종 SASS 판정 기준
```

실행 코드에 대한 정적 결론은 이 EXE에서 추출한 SASS를 기준으로 한다.

### `probe_kernels_sm86.cubin`

```text
별도로 컴파일한 reference CUBIN
독립 빌드 결과 비교용
EXE 내부 runtime CUBIN과 동일하다고 가정하지 않음
```

### `probe_kernels_compute86.ptx`

```text
CUDA source에서 PTX로의 lowering 분석용
실제 실행 machine code 자체는 아님
```

## 6.2 생성 로그와 manifest

```text
results/build/probe_ffma_build.txt
results/build/probe_kernels_cubin_build.txt
results/build/probe_kernels_ptx_build.txt
results/build/build_manifest.json
```

`build_manifest.json`에는 다음 정보가 저장된다.

```text
대상 architecture
전체 nvcc argument
source file SHA-256
EXE SHA-256
reference CUBIN SHA-256
reference PTX SHA-256
빌드 로그 경로
빌드 시각
```

## 6.3 빌드 로그 확인

각 커널에서 다음 항목을 확인한다.

```text
Used N registers
stack frame
spill stores
spill loads
barriers
constant-memory resource
```

FFMA 프로브의 필수 조건:

```text
stack frame  = 0 bytes
spill stores = 0 bytes
spill loads  = 0 bytes
barriers     = 0
```

현재 기준 예상 리소스:

```text
probe_timer_only
  registers    : 12
  stack frame  : 0
  spill stores : 0
  spill loads  : 0

probe_dependent_ffma
  registers    : 12
  stack frame  : 0
  spill stores : 0
  spill loads  : 0

probe_independent_ffma_8
  registers    : 15
  stack frame  : 0
  spill stores : 0
  spill loads  : 0
```

Independent-8이 dependent보다 더 많은 register를 사용하는 것은 정상이다.

---

# 7. PTX·SASS·리소스 출력

```powershell
powershell -ExecutionPolicy Bypass     -File scripts\collect_binary_outputs.ps1     -Arch 86
```

## 7.1 생성 파일

### PTX

```text
results/binary/probe_ffma.ptx.txt
```

CUDA source가 PTX 수준에서 어떻게 표현됐는지 확인한다.

### Canonical SASS

```text
results/binary/probe_ffma_full.sass.txt
results/binary/probe_ffma_filtered.sass.txt
```

`probe_ffma_full.sass.txt`는 실제 실행 EXE에서 `cuobjdump`로 추출한 기준 SASS다.

### 리소스 정보

```text
results/binary/probe_ffma_resource_usage.txt
```

### 실제 runtime CUBIN

```text
results/binary/probe_ffma_runtime_sm86.cubin
```

실제 EXE 내부에서 추출한 CUBIN이다.

### Runtime CUBIN 상세 SASS

```text
results/binary/probe_ffma_lineinfo.sass.txt
results/binary/probe_ffma_detailed.sass.txt
```

`nvdisasm`을 사용해 실제 runtime CUBIN의 다음 정보를 확인한다.

```text
instruction address
source line information
instruction encoding
register lifetime
instruction control 정보
```

### Reference CUBIN 비교 자료

```text
results/binary/probe_ffma_reference_full.sass.txt
results/binary/reference_analysis/
```

별도로 컴파일한 reference CUBIN을 분석한 결과다.

### 분석 결과

```text
results/binary/sass_summary.txt
results/binary/sass_summary.json
```

### 추출 및 선택 기록

```text
results/binary/runtime_cubin_selection.json
results/binary/binary_collection_manifest.json
```

`runtime_cubin_selection.json`에는 EXE에서 추출된 여러 CUBIN 후보 중 실제 프로브 커널을 포함한 CUBIN을 선택한 과정이 기록된다.

---

# 8. Canonical SASS와 reference SASS 구분

정적 판정의 기준은 다음이다.

```text
probe_ffma.exe
→ cuobjdump --dump-sass
→ probe_ffma_full.sass.txt
→ canonical SASS
```

상세 `nvdisasm` 결과는 다음 경로로 생성한다.

```text
probe_ffma.exe
→ embedded runtime CUBIN 추출
→ probe_ffma_runtime_sm86.cubin
→ nvdisasm
→ probe_ffma_detailed.sass.txt
```

별도 CUBIN은 비교용이다.

```text
probe_kernels_sm86.cubin
→ probe_ffma_reference_full.sass.txt
```

다음 두 파일이 같다고 자동으로 가정하지 않는다.

```text
EXE 내부 runtime CUBIN
별도 reference CUBIN
```

---

# 9. SASS 정적 검사

정적 분석은 다음 파일을 기준으로 수행한다.

```text
results/binary/probe_ffma_full.sass.txt
```

분석기는 다음 구조를 검사한다.

```text
clock read 위치
measured region
FFMA 수
self-dependency
accumulator chain 수
chain 길이
accumulator reuse distance
round-robin 순서
cross-chain dependency
memory operation
timer 경계 내부 setup
```

---

## 9.1 `probe_timer_only`

필수 조건:

```text
clock-read CS2R count         = 2
measured-region instructions  = 0
measured-region FFMA          = 0
```

기대 SASS:

```text
CS2R ..., SR_CLOCKLO
CS2R ..., SR_CLOCKLO
```

두 clock read 사이에 instruction이 없어야 한다.

---

## 9.2 `probe_dependent_ffma`

필수 조건:

```text
measured-region FFMA          = 32
self-dependent FFMA           = 32
dependency chain count        = 1
static chain length           = 32
accumulator reuse distance    = 1
cross-chain dependencies      = 0
accumulator setup after CS2R  = 0
```

기대 형태:

```text
FFMA R9, R9, multiplier, addend
FFMA R9, R9, multiplier, addend
FFMA R9, R9, multiplier, addend
...
```

수학적 recurrence:

[
x_{n+1}=x_n m+a
]

각 FFMA가 직전 FFMA의 결과를 즉시 사용하므로 accumulator reuse distance는 1이다.

---

## 9.3 `probe_independent_ffma_8`

필수 조건:

```text
measured-region FFMA          = 32
self-dependent FFMA           = 32
dependency chain count        = 8
static chain lengths          = 4,4,4,4,4,4,4,4
round-robin pattern           = true
accumulator reuse distance    = 8
cross-chain dependencies      = 0
accumulator setup after CS2R  = 0
```

기대 정규화 pattern:

```text
0 1 2 3 4 5 6 7
0 1 2 3 4 5 6 7
0 1 2 3 4 5 6 7
0 1 2 3 4 5 6 7
```

각 accumulator는 다음 독립 recurrence를 수행한다.

[
x_{n+1}^{(k)}
=============

x_n^{(k)}m+a
\qquad
k=0,\ldots,7
]

한 accumulator가 다시 사용되기까지 8개의 FFMA 간격이 존재한다.

---

# 10. Memory operation 판정

다음 항목이 measured region 안에 존재하면 구조 오류로 판단한다.

```text
global memory operation
local memory operation
shared memory operation
atomic 또는 기타 data-memory operation
```

예:

```text
LDG / STG
LDL / STL
LDS / STS
ATOM / RED
```

필수 조건:

```text
global memory ops = 0
local memory ops  = 0
shared memory ops = 0
other memory ops  = 0
```

---

## 10.1 Constant/uniform load

다음은 hard memory error로 처리하지 않는다.

```text
LDC
ULDC
constant-memory operand
```

예:

```text
ULDC.64 UR4, c[0x0][0x118]
FFMA R9, R9, R0, c[0x0][0x178]
```

Constant/uniform load는 spill이 아니지만 측정 cycle에 고정 setup 비용을 추가하므로 `WARN`으로 기록한다.

다음 두 조건은 구분해야 한다.

```text
resource usage의 cmem 사용
≠
measured region 내부의 constant load instruction
```

---

# 11. SASS 분석 상태 해석

분석기는 다음 상태를 출력한다.

```text
PASS
WARN
FAIL
```

## PASS

```text
구조 오류 없음
추가 경고 없음
```

## WARN

```text
필수 dependency 구조는 정상
hard memory operation 없음
spill 없음
다만 constant load 또는 setup overhead가 measured region에 포함됨
```

현재 프로브의 정상 예상 결과는 다음과 같다.

```text
Overall status : WARN
Error count    : 0
Warning count  : 4
```

Dependent와 independent에서 각각 다음 경고가 발생한다.

```text
uniform/constant-memory setup이 measured region에 포함됨
첫 FFMA 이전에 loop setup instruction이 포함됨
```

`WARN`은 구조 검증 실패가 아니다.

실행 진행 기준:

```text
Error count = 0
```

## FAIL

다음과 같은 경우 runtime 측정으로 진행하지 않는다.

```text
clock boundary 탐색 실패
FFMA 수 불일치
dependent chain 구조 불일치
independent chain 수 불일치
chain length 불일치
round-robin 불일치
cross-chain dependency 발생
accumulator setup이 timer 내부에 포함됨
global/local/shared memory operation 발생
```

---

# 12. 현재 measured region 구조

## 12.1 Dependent

현재 SASS에서 measured region은 대략 다음 구조다.

```text
CS2R start

MOV loop_counter, zero
ULDC uniform value
MOV multiplier
IADD3 loop_counter

FFMA × 32
ISETP loop condition
BRA loop

CS2R end
```

## 12.2 Independent-8

```text
CS2R start

MOV loop_counter, zero
ULDC uniform value
IADD3 loop_counter
MOV multiplier
ISETP loop condition

FFMA × 32
BRA loop

CS2R end
```

두 커널 모두 정적 measured-region instruction 수는 38개다.

```text
Dependent measured-region instructions   = 38
Independent measured-region instructions = 38
```

동적 FFMA 수와 loop-control 명령 수도 동일하다.

핵심 차이는 다음이다.

```text
Dependent
  chain count    = 1
  reuse distance = 1

Independent-8
  chain count    = 8
  reuse distance = 8
```

---

# 13. GPU 반복 실행

```powershell
powershell -ExecutionPolicy Bypass     -File scripts\run_probe.ps1     -Samples 10     -Warmups 3
powershell -ExecutionPolicy Bypass     -File scripts\run_probe.ps1     -Samples 100     -Warmups 10
```

## 13.1 생성 파일

```text
results/runtime/runtime_raw.csv
results/runtime/runtime_summary.txt
results/runtime/runtime_check.txt
results/runtime/metadata.json
```

## 13.2 CSV 주요 열

```text
run
kernel
dynamic_ffma_count
total_cycles
cycles_per_ffma
checksum
```

`dynamic_ffma_count`는 두 커널 모두 다음과 같다.

[
4096\times32=131072
]

## 13.3 cycles/FFMA 의미

계산식:

[
\text{cycles/FFMA}
==================

\frac{\text{elapsed SM cycles}}
{\text{dynamic FFMA count}}
]

이 값은 일반적인 의미의 CPI가 아니다.

측정 구간에는 다음 비용이 포함된다.

```text
FFMA execution
outer-loop counter
loop comparison
branch
최초 진입 setup
uniform/constant load
```

따라서 결과는 다음처럼 해석한다.

> 동일한 반복 구조에서 FFMA 의존 구조에 따라 관측된 elapsed cycles를 동적 FFMA 수로 정규화한 값

---

# 14. Runtime 기본 판정

기본 기대 관계:

```text
Dependent median cycles/FFMA
>
Independent-8 median cycles/FFMA
```

의존형은 하나의 accumulator 결과가 다음 FFMA의 입력이므로 연속적인 RAW dependency를 갖는다.

Independent-8은 8개의 accumulator 사이를 round-robin으로 이동하므로, 한 accumulator의 결과가 다시 필요해질 때까지 다른 독립 FFMA를 issue할 수 있다.

---

## 14.1 Runtime 오류 검사

각 실행에서 다음을 확인한다.

```text
kernel launch error 없음
cudaDeviceSynchronize error 없음
cycle count > 0
checksum이 NaN 또는 Inf가 아님
dependent와 independent의 동적 FFMA 수 동일
```

현재 timer-only 결과는 참고용이다.

```text
timer-only cycle은 dependent 또는 independent 결과에서 직접 차감하지 않음
```

Timer-only는 두 연속 `CS2R` 사이의 최소 관측 비용과 변동성을 확인하기 위한 진단값이다.

---

# 15. Runtime 결과가 기대와 다를 때 점검

```text
canonical EXE SASS를 분석했는지
reference CUBIN 결과와 혼동하지 않았는지
runtime CUBIN 선택이 올바른지
measured-region FFMA 수가 32인지
dependency chain 수와 길이가 올바른지
independent round-robin이 유지됐는지
reuse distance가 8인지
cross-chain dependency가 없는지
첫 번째와 마지막 CS2R 위치가 올바른지
accumulator 초기화가 첫 CS2R 전에 완료됐는지
global/local/shared memory operation이 없는지
spill load/store가 0인지
constant/uniform setup 비용이 양쪽에 대칭적인지
loop-control instruction 위치가 어떻게 다른지
GPU clock 또는 P-state가 변동했는지
컴파일 대상 architecture가 실제 GPU와 일치하는지
checksum이 finite인지
CUDA launch/synchronization 오류가 없는지
```

---

# 16. Nsight Compute 수집

Nsight Compute는 선택 단계다.

```powershell
powershell -ExecutionPolicy Bypass `
    -File scripts\profile_ncu.ps1
```

## 16.1 생성 파일

현재 기본 결과:

```text
results/profiler/probe_ffma_profile.ncu-rep
results/profiler/probe_ffma_ncu_raw.csv
results/profiler/probe_ffma_ncu_sass.txt
```

향후 source correlation 결과를 추가한다.

```text
results/profiler/probe_ffma_ncu_source_sass.txt
results/profiler/probe_ffma_ncu_source_sass.csv
```

## 16.2 NCU의 역할

일반 실행:

```text
elapsed cycle
cycles/FFMA
runtime 기준값 수집
```

Nsight Compute:

```text
실행된 FFMA 수
scheduler 상태
eligible warp 상태
dependency 관련 stall
source/SASS correlation
register 사용량
occupancy
launch configuration
```

NCU는 metric 수집 과정에서 kernel replay를 수행할 수 있다.

따라서 다음 원칙을 따른다.

```text
NCU 실행 중 측정된 cycle
≠
일반 runtime 실행의 기준 성능값
```

NCU 결과는 구조와 원인 검증용으로 사용한다.

---

## 16.3 Performance counter 권한 오류

오류가 발생하면 다음을 확인한다.

```text
Windows 관리자 권한
NVIDIA 제어판 개발자 설정
GPU performance counter 접근 정책
시스템 보안 정책
```

---

# 17. 전체 실행

## 17.1 Nsight Compute 제외

```powershell
powershell -ExecutionPolicy Bypass `
    -File scripts\run_all.ps1 `
    -Arch 86 `
    -Samples 100 `
    -Warmups 10 `
    -Clean
```

## 17.2 Nsight Compute 포함

```powershell
powershell -ExecutionPolicy Bypass `
    -File scripts\run_all.ps1 `
    -Arch 86 `
    -Samples 100 `
    -Warmups 10 `
    -Clean `
    -WithNcu
```

---

# 18. 전체 실행의 실패 정책

`run_all.ps1`은 다음 정책을 따르는 것이 목표다.

```text
도구 확인 실패
→ 즉시 중단

빌드 실패
→ 즉시 중단

artifact hash 불일치
→ 즉시 중단

canonical SASS 구조 ERROR
→ runtime 실행 중단

canonical SASS WARN
→ 경고 출력 후 runtime 진행

runtime CUDA 오류
→ 실패

cycle count 0
→ 실패

checksum NaN 또는 Inf
→ 실패

NCU 실패
→ runtime 결과는 보존
→ profiler 단계만 실패 또는 경고 처리
```

---

# 19. 결과 해석 원칙

현재 프로브에서 직접 검증할 수 있는 것은 다음이다.

```text
CUDA source의 FFMA recurrence
PTX의 fma.rn.f32
SASS의 FFMA
실제 accumulator register
dependency chain 수
chain 길이
reuse distance
constant operand 사용
loop-control 구조
resource 사용량
elapsed cycle 차이
```

현재 프로브만으로 직접 단정하지 않는 것은 다음이다.

```text
순수 FFMA hardware latency
모든 warp scheduler의 일반적 동작
full-warp throughput
전체 SM saturation throughput
다른 GPU architecture에서의 동일 결과
```

결과 표현 예시:

```text
동일한 동적 FFMA 수와 동일한 반복 구조에서,
단일 accumulator chain은 reuse distance 1의 연속 RAW dependency를 보였다.

8개 독립 accumulator 구조는 각각 4개의 정적 FFMA chain을 형성했고,
accumulator reuse distance 8의 round-robin SASS를 생성했다.

두 커널 모두 spill과 global/local/shared memory traffic이 없었으며,
차이는 주로 accumulator dependency 구조에서 발생했다.

Runtime의 cycles/FFMA 차이는 이 dependency 구조가 elapsed SM cycle에
미치는 영향을 나타낸다.
```

---

# 20. 다음 확장 단계

현재 정적 SASS 분석이 완료된 뒤 다음 순서로 확장한다.

```text
1. run_probe.ps1 검토
2. analyze_runtime.py 검토
3. cycles_per_ffma 기반 통계 확인
4. median·MAD·percentile 추가
5. 실제 100 samples 실행
6. dependent/independent runtime 결과 분석
7. profile_ncu.ps1 source correlation 추가
8. run_all.ps1 실패 정책 통합
9. 32·64·128·256 FFMA 길이별 측정
10. T(N) = alpha + beta N 회귀 분석
11. single-active-lane과 full-warp 결과 비교
```

여러 FFMA 길이를 사용할 경우 다음 모델로 고정 overhead와 FFMA 증가분을 분리한다.

[
T(N)=\alpha+\beta N
]

```text
alpha
  timer 및 고정 setup 비용

beta
  FFMA 수 증가에 따른 elapsed cycle 기울기
```

단일 `cycles/FFMA`보다 여러 길이의 회귀 기울기 비교가 타이머와 setup overhead에 덜 민감하다.
