# 중간 오류 점검표

## 1. `nvcc`를 찾지 못함

```text
Required command not found in PATH: nvcc
```

CUDA Toolkit의 `bin` 경로가 PATH에 있는지 확인한다.

예:

```text
C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.x\bin
```

## 2. `cl.exe`를 찾지 못함

대표 오류:

```text
nvcc fatal: Cannot find compiler 'cl.exe' in PATH
```

Visual Studio 2022의 C++ Desktop Development workload를 설치하고,
`x64 Native Tools Command Prompt for VS 2022`에서 PowerShell을 실행한다.

## 3. 아키텍처 값 오류

대표 오류:

```text
Unsupported gpu architecture 'compute_XX'
```

`-Arch 86`처럼 숫자만 전달한다. RTX 3070은 `86`이다.

## 4. inline PTX 컴파일 오류

`compiler_use`의 comment-only inline PTX가 특정 Toolkit에서 거부되면 다음 대체안을 사용한다.

```cpp
asm volatile("mov.b32 %0, %0;" : "+f"(value) : : "memory");
```

단, 이 대체안은 실제 `MOV` 명령을 만들 수 있으므로 타이머 위치와 측정 구간을
SASS에서 다시 확인해야 한다.

## 5. SASS 함수 이름을 찾지 못함

```text
ERROR: missing functions in SASS
```

다음을 확인한다.

```text
extern "C"가 커널 선언과 정의에 모두 존재하는가
cuobjdump 대상이 최신 probe_ffma.exe인가
sm_86 코드가 바이너리에 포함됐는가
```

## 6. 정적 FFMA 수가 32가 아님

컴파일러가 안쪽 루프를 예상과 다르게 전개했을 수 있다.

확인:

```text
#pragma unroll 32 또는 4가 유지됐는가
실제 SASS의 FFMA 수
빌드에 이전 object가 섞이지 않았는가
```

## 7. 시작 CS2R 뒤에 초기화 명령이 존재함

`sass_summary.txt`에 다음 경고가 나오면 측정 시작 뒤에 `MOV`, `FADD`, `LDC`
등이 배치됐을 가능성이 있다.

```text
Possible setup instructions appear after the starting clock read
```

이 경우 `Timer start window` 원문을 확인한다. 기존 단순 `clock64()` 구조에서는
컴파일러가 독립적인 accumulator 초기화를 타이머 뒤로 이동할 수 있다.

## 8. 측정 구간에 LD/ST가 존재함

다음 원인을 의심한다.

```text
register spill
kernel parameter load가 타이머 뒤로 이동
예상하지 않은 local/global memory 접근
```

`probe_ffma_build.txt`의 spill load/store와
`probe_ffma_resource_usage.txt`의 local memory를 함께 확인한다.

## 9. 의존 결과가 독립 결과보다 작거나 같음

```text
Dependent median <= Independent median
```

점검 순서:

```text
1. SASS accumulator 수
2. FFMA 정적 개수
3. CS2R 위치
4. 측정 구간의 load/store
5. register spill
6. GPU boost clock과 백그라운드 부하
7. 반복 횟수와 sample 수
```

## 10. Nsight Compute 권한 오류

대표 메시지:

```text
ERR_NVGPUCTRPERM
```

GPU performance counter 접근 권한이 차단된 상태다. Nsight Compute 없이도
PTX·SASS·device cycle 실험은 진행할 수 있으므로, 우선 나머지 출력을 완료한다.
