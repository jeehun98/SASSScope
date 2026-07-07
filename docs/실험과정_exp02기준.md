# SASSScope exp002 실험 과정 정리

## 1. 실험 목적

이 실험의 목적은 간단한 linear 계열 CUDA 커널들이 PTX/SASS 단계에서 어떻게 다른 명령 구조로 내려가는지 관찰하는 것이다.

특히 다음 변형들을 비교한다.

* `linear_4_2_nobias_f32`
* `linear_4_2_bias_f32`
* `linear_4_2_relu_f32`
* `linear_2_4_f32`
* `linear_4_2_4_fused_f32`

수학적으로는 모두 단순한 선형 계열 연산처럼 보일 수 있지만, 실제 GPU 명령 수준에서는 bias 추가, ReLU 적용, 중간 차원 변경, fusion 여부에 따라 레지스터 사용량, load/store 수, FFMA 체인, 분기/선택 명령이 달라진다.

---

## 2. 프로젝트 구조

현재 SASSScope는 루트 `src/main.cu`를 빌드하는 구조가 아니라, 실험별 폴더를 선택해서 빌드하는 구조다.

```txt
SASSScope
├─ CMakeLists.txt
├─ scripts
│  ├─ build.ps1
│  ├─ check_env.ps1
│  ├─ dump_ptx.ps1
│  ├─ dump_sass.ps1
│  ├─ dump_resource_usage.ps1
│  └─ run.ps1
└─ experiments
   └─ exp002_4_2_bias_relu_variants
      ├─ include
      │  └─ kernels.cuh
      ├─ src
      │  ├─ main.cu
      │  └─ kernels.cu
      └─ results
         ├─ ptx.txt
         ├─ sass.txt
         └─ resource_usage.txt
```

빌드 대상은 다음 경로의 파일들이다.

```txt
experiments/exp002_4_2_bias_relu_variants/src/main.cu
experiments/exp002_4_2_bias_relu_variants/src/kernels.cu
```

헤더는 다음 파일을 사용한다.

```txt
experiments/exp002_4_2_bias_relu_variants/include/kernels.cuh
```

따라서 `main.cu`, `kernels.cu`에서는 다음 include를 사용해야 한다.

```cpp
#include "kernels.cuh"
```

---

## 3. 빌드 방식

기본 빌드 명령은 다음과 같다.

```powershell
cd C:\Users\as042\OneDrive\Desktop\SASSScope

powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Clean
```

`build.ps1`은 내부적으로 다음 CMake 옵션을 사용한다.

```powershell
cmake -S . -B build -G Ninja `
  -DCMAKE_BUILD_TYPE=Release `
  -DCMAKE_CUDA_ARCHITECTURES=86 `
  -DSASSSCOPE_EXPERIMENT=exp002_4_2_bias_relu_variants
```

빌드 성공 시 실행 파일은 다음 위치에 생성된다.

```txt
build/experiments/exp002_4_2_bias_relu_variants/exp002_4_2_bias_relu_variants.exe
```

---

## 4. 실행 확인

빌드 후 실행 파일이 정상 동작하는지 확인한다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run.ps1
```

또는 직접 실행할 수 있다.

```powershell
.\build\experiments\exp002_4_2_bias_relu_variants\exp002_4_2_bias_relu_variants.exe 32
```

여기서 `32`는 테스트 입력 크기 또는 실행 인자로 사용된다.

---

## 5. PTX 추출

PTX는 CUDA 컴파일러가 생성한 중간 어셈블리 수준 표현이다.
SASS보다 하드웨어 의존성이 낮고, 커널 구조와 연산 흐름을 비교하기 좋다.

추출 명령은 다음과 같다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\dump_ptx.ps1
```

결과 파일:

```txt
experiments/exp002_4_2_bias_relu_variants/results/ptx.txt
```

직접 명령으로 실행할 경우:

```powershell
cuobjdump --dump-ptx build\experiments\exp002_4_2_bias_relu_variants\exp002_4_2_bias_relu_variants.exe > experiments\exp002_4_2_bias_relu_variants\results\ptx.txt
```

---

## 6. SASS 추출

SASS는 실제 NVIDIA GPU 아키텍처에 대응되는 저수준 명령이다.
이 실험에서는 SASS를 통해 실제 명령 수, FFMA 사용, load/store, register 사용량 등을 관찰한다.

추출 명령은 다음과 같다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\dump_sass.ps1
```

결과 파일:

```txt
experiments/exp002_4_2_bias_relu_variants/results/sass.txt
```

직접 명령으로 실행할 경우:

```powershell
cuobjdump --dump-sass build\experiments\exp002_4_2_bias_relu_variants\exp002_4_2_bias_relu_variants.exe > experiments\exp002_4_2_bias_relu_variants\results\sass.txt
```

---

## 7. Resource Usage 추출

resource usage는 커널별 register 사용량, shared memory 사용량, constant memory 사용량 등을 확인하기 위해 사용한다.

추출 명령은 다음과 같다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\dump_resource_usage.ps1
```

결과 파일:

```txt
experiments/exp002_4_2_bias_relu_variants/results/resource_usage.txt
```

직접 명령으로 실행할 경우:

```powershell
cuobjdump --dump-resource-usage build\experiments\exp002_4_2_bias_relu_variants\exp002_4_2_bias_relu_variants.exe > experiments\exp002_4_2_bias_relu_variants\results\resource_usage.txt
```

---

## 8. 관찰 대상

추출된 PTX/SASS에서 다음 커널을 중심으로 비교한다.

```txt
linear_4_2_nobias_f32
linear_4_2_bias_f32
linear_4_2_relu_f32
linear_2_4_f32
linear_4_2_4_fused_f32
```

PTX에서 커널 위치를 찾는 명령:

```powershell
Select-String -Path .\experiments\exp002_4_2_bias_relu_variants\results\ptx.txt `
  -Pattern "\.entry|linear_4_2|linear_2_4"
```

SASS에서 커널 위치를 찾는 명령:

```powershell
Select-String -Path .\experiments\exp002_4_2_bias_relu_variants\results\sass.txt `
  -Pattern "Function :|linear_4_2|linear_2_4"
```

---

## 9. 주요 비교 기준

각 커널은 다음 기준으로 비교한다.

### 1. Register 사용량

빌드 로그 또는 `resource_usage.txt`에서 커널별 register 사용량을 확인한다.

예상 관찰:

```txt
nobias  계열: register 사용량이 상대적으로 적음
bias    계열: bias load/add 때문에 register 사용량 증가 가능
relu    계열: 비교/선택 명령 때문에 추가 register 사용 가능
fused   계열: 중간 값을 메모리에 저장하지 않고 register에 유지하므로 register 사용량 증가 가능
```

### 2. 산술 명령

SASS에서 다음 명령을 중심으로 확인한다.

```txt
FFMA
FADD
FMUL
```

`FFMA`는 fused multiply-add 명령으로, linear 연산에서 핵심적으로 나타난다.

### 3. 메모리 접근 명령

다음 명령을 확인한다.

```txt
LDG
STG
```

bias가 추가되면 bias load가 증가할 수 있고, fusion 여부에 따라 중간 결과 저장이 줄어들 수 있다.

### 4. ReLU 처리 명령

ReLU가 포함된 커널에서는 비교 또는 선택 계열 명령이 나타날 수 있다.

```txt
FSETP
SEL
FSEL
```

즉 ReLU는 단순히 수학적으로 `max(0, x)`이지만, SASS 수준에서는 비교와 선택 명령으로 표현될 수 있다.

---

## 10. 해석 요약

이 실험은 “같은 linear 계열 연산”이라도 실제 GPU 명령 수준에서는 동일하지 않다는 점을 확인하기 위한 실험이다.

예상되는 차이는 다음과 같다.

```txt
linear_4_2_nobias_f32
→ 가장 단순한 형태. bias load/add 없음.

linear_4_2_bias_f32
→ bias 값을 읽고 더하는 명령이 추가됨.

linear_4_2_relu_f32
→ ReLU 처리를 위한 비교/선택 계열 명령이 추가될 수 있음.

linear_2_4_f32
→ 입력/출력 차원 구조가 달라져 FFMA 체인과 register 사용 패턴이 달라짐.

linear_4_2_4_fused_f32
→ 두 단계 연산을 하나의 커널에서 처리하므로 중간 저장은 줄어들 수 있지만, 중간 값을 register에 유지해야 해서 register 사용량은 증가할 수 있음.
```

따라서 이 실험의 핵심은 다음과 같다.

```txt
수학적 표현이 비슷해도,
컴파일 이후 GPU 명령 구조는 달라진다.

특히 bias, activation, fusion, 중간 차원 변화는
PTX/SASS 수준에서 register 사용량, FFMA 체인, load/store 패턴을 바꾼다.
```

---

## 11. 전체 실행 순서 요약

```powershell
cd C:\Users\as042\OneDrive\Desktop\SASSScope

powershell -ExecutionPolicy Bypass -File scripts\check_env.ps1

powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Clean

powershell -ExecutionPolicy Bypass -File scripts\run.ps1

powershell -ExecutionPolicy Bypass -File scripts\dump_ptx.ps1
powershell -ExecutionPolicy Bypass -File scripts\dump_sass.ps1
powershell -ExecutionPolicy Bypass -File scripts\dump_resource_usage.ps1
```

최종 결과 파일:

```txt
experiments/exp002_4_2_bias_relu_variants/results/ptx.txt
experiments/exp002_4_2_bias_relu_variants/results/sass.txt
experiments/exp002_4_2_bias_relu_variants/results/resource_usage.txt
```
