# SASSScope Experiment 002

# 4→2 Linear의 Bias / ReLU 분리 관찰

## 1. 실험 목적

Experiment 001에서는 `4 → 2 → ReLU → 4` 구조에서 split 커널과 fused 커널을 비교했다. 그 결과 fused 커널에서는 hidden 값 `h0`, `h1`이 global memory에 저장되지 않고 register value로 유지된 뒤 다음 Linear 계산에 바로 소비되는 것을 확인했다.

Experiment 002의 목적은 더 작은 단위로 내려가서 `4 → 2 Linear` 하나 안에서 다음 요소들이 PTX/SASS에 어떻게 나타나는지 분리 관찰하는 것이다.

```text
1. bias가 없는 Linear
2. bias가 있는 Linear
3. bias + ReLU가 있는 Linear
```

핵심 질문은 다음이다.

> `Linear`라는 하나의 고수준 연산자 안에서 bias, FMA chain, ReLU는 실제 명령어 수준에서 어떤 독립 패턴으로 나타나는가?

---

## 2. 실험 환경

이번 실험은 `sm_86` 타깃으로 빌드되었다. PTX dump에서 다음 항목이 확인된다.

```text
arch = sm_86
code version = [9,1]
.version 9.1
.target sm_86
.address_size 64
```

이는 RTX 3080 Ti Laptop GPU의 Ampere 아키텍처에 맞는 코드 생성이다. 업로드된 PTX에는 `linear_4_2_nobias_f32`, `linear_4_2_bias_f32`, `linear_4_2_relu_f32` 커널이 모두 포함되어 있다.

실험 조건은 다음과 같다.

```text
GPU: RTX 3080 Ti Laptop GPU
Architecture: Ampere
CUDA target: sm_86
PTX version: 9.1
관찰 도구: cuobjdump --dump-ptx, cuobjdump --dump-sass
```

---

## 3. 실험 커널

이번 실험의 핵심 커널은 세 개다.

```text
linear_4_2_nobias_f32
linear_4_2_bias_f32
linear_4_2_relu_f32
```

각 커널의 의미는 다음과 같다.

| 커널                      | 의미                             |
| ----------------------- | ------------------------------ |
| `linear_4_2_nobias_f32` | bias 없는 `4 → 2` Linear         |
| `linear_4_2_bias_f32`   | bias 있는 `4 → 2` Linear         |
| `linear_4_2_relu_f32`   | bias + ReLU가 있는 `4 → 2` Linear |

수학적으로는 다음 세 형태를 비교한다.

```text
no bias:
h = W x

bias:
h = W x + b

bias + ReLU:
h = ReLU(W x + b)
```

---

## 4. 수학적 계산 구조

입력은 4차원이고 hidden은 2차원이다.

입력:

```text
x0, x1, x2, x3
```

출력 hidden:

```text
h0, h1
```

bias 없는 버전은 다음과 같다.

```text
h0 = w00*x0 + w01*x1 + w02*x2 + w03*x3
h1 = w10*x0 + w11*x1 + w12*x2 + w13*x3
```

bias 있는 버전은 다음과 같다.

```text
h0 = b0 + w00*x0 + w01*x1 + w02*x2 + w03*x3
h1 = b1 + w10*x0 + w11*x1 + w12*x2 + w13*x3
```

bias + ReLU 버전은 다음과 같다.

```text
h0 = max(0, b0 + w00*x0 + w01*x1 + w02*x2 + w03*x3)
h1 = max(0, b1 + w10*x0 + w11*x1 + w12*x2 + w13*x3)
```

수학적으로 dot product는 각 hidden unit마다 4개의 곱셈 항을 가진다.

```text
2 hidden units × 4 input values = 8 multiply-add 항
```

하지만 bias가 없을 때와 있을 때 accumulator를 시작하는 방식이 다르다. 이 차이가 실제 PTX/SASS 명령 차이로 드러난다.

---

## 5. PTX 관찰 결과

## 5.1 `linear_4_2_nobias_f32`

bias 없는 커널의 PTX 선언은 다음과 같은 형태다.

```text
.visible .entry linear_4_2_nobias_f32
.reg .f32 %f<21>
```

이 커널에서는 bias parameter가 없다. 따라서 accumulator를 bias 값으로 초기화할 수 없다.

실제 PTX에서는 각 hidden unit의 첫 항이 `mul.f32`로 시작한다.

```text
mul.f32
fma.rn.f32
fma.rn.f32
fma.rn.f32

mul.f32
fma.rn.f32
fma.rn.f32
fma.rn.f32
```

즉, no-bias 버전은 다음 구조로 내려간다.

```text
2 FMUL + 6 FMA
```

이는 각 hidden unit에 대해 다음 계산 구조가 만들어졌다는 뜻이다.

```text
첫 항:
acc = w0 * x0

나머지 항:
acc = fma(w1, x1, acc)
acc = fma(w2, x2, acc)
acc = fma(w3, x3, acc)
```

PTX에서 `mul.f32`와 `fma.rn.f32`가 모두 확인되며, 마지막에는 hidden 값 2개를 저장하는 `st.global.f32` 2개가 나타난다.

---

## 5.2 `linear_4_2_bias_f32`

bias 있는 커널의 PTX 선언은 다음과 같은 형태다.

```text
.visible .entry linear_4_2_bias_f32
.reg .f32 %f<23>
```

이 커널에서는 `b1[0]`, `b1[1]`이 추가로 load된다.

중요한 점은 bias가 별도의 add 명령으로 들어가지 않는다는 것이다.

소스 수준에서는 다음과 같다.

```cpp
float h0 = b1[0];
h0 = fmaf(w1[0], x0, h0);
```

PTX에서는 이것이 바로 다음 형태로 나타난다.

```text
fma.rn.f32 weight, input, bias
```

즉, bias는 별도의 `add`가 아니라 FMA의 세 번째 operand, 즉 accumulator seed로 들어간다.

따라서 bias 버전의 계산 구조는 다음과 같다.

```text
8 FMA
0 FMUL
0 FADD
```

bias가 있음에도 `FADD`가 따로 생기지 않는다는 점이 핵심이다. PTX에서 bias load 후 `fma.rn.f32` 체인으로 이어지는 구조가 확인된다.

---

## 5.3 `linear_4_2_relu_f32`

bias + ReLU 커널의 PTX 선언은 다음과 같다.

```text
.visible .entry linear_4_2_relu_f32
.reg .f32 %f<26>
```

이 커널은 bias 버전과 거의 같지만, hidden 값 2개에 대해 ReLU가 추가된다.

PTX에서는 ReLU가 다음 명령으로 나타난다.

```text
max.f32
max.f32
```

즉, `h0`, `h1` 각각에 대해 `max(0, h)`가 적용된다.

중요한 점은 ReLU가 branch로 나타나지 않는다는 것이다.

다음과 같은 구조가 아니다.

```text
if h < 0:
    h = 0
```

실제 PTX에서는 `max.f32` 명령 2개로 처리된다.

---

## 6. SASS 관찰 결과

SASS에서도 PTX에서 본 구조가 그대로 확인된다.

SASS dump에는 다음 함수들이 포함되어 있다.

```text
Function : linear_4_2_nobias_f32
Function : linear_4_2_bias_f32
Function : linear_4_2_relu_f32
```

각 커널은 `sm_86` 타깃의 실제 Ampere SASS 명령으로 변환되어 있다.

---

## 6.1 no-bias SASS

`linear_4_2_nobias_f32`의 핵심 명령 구조는 다음과 같다.

```text
FMUL
FMUL
FFMA × 6
STG × 2
```

실제 SASS에서는 첫 두 accumulator를 만들기 위해 `FMUL`이 2개 사용된다.

```text
FMUL R7, R7, R8
FMUL R8, R8, R15
```

이후 나머지 항들은 `FFMA` 체인으로 이어진다.

```text
FFMA ...
FFMA ...
FFMA ...
FFMA ...
FFMA ...
FFMA ...
```

마지막에는 hidden output 2개를 global memory에 저장한다.

```text
STG.E ...
STG.E ...
```

따라서 no-bias 버전은 SASS 기준으로도 다음 형태가 맞다.

```text
2 hidden units × (1 FMUL + 3 FFMA)
```

---

## 6.2 bias SASS

`linear_4_2_bias_f32`에서는 `FMUL`이 사라지고, 모든 곱-누산이 `FFMA`로 표현된다.

핵심 구조는 다음과 같다.

```text
FFMA × 8
STG × 2
```

bias가 없는 경우에는 첫 곱으로 accumulator를 만들어야 했지만, bias가 있는 경우에는 bias 값이 accumulator 초기값 역할을 한다.

즉, 다음 형태가 된다.

```text
acc = FFMA(weight, input, bias)
acc = FFMA(weight, input, acc)
acc = FFMA(weight, input, acc)
acc = FFMA(weight, input, acc)
```

SASS에서는 `FFMA` 8개와 hidden output을 저장하는 `STG.E` 2개가 확인된다.

---

## 6.3 bias + ReLU SASS

`linear_4_2_relu_f32`는 bias 버전에 ReLU가 추가된 형태다.

핵심 구조는 다음과 같다.

```text
FFMA × 8
FMNMX × 2
STG × 2
```

SASS에서 ReLU는 다음 형태로 나타난다.

```text
FMNMX R7,  RZ, R6,  !PT
FMNMX R19, RZ, R19, !PT
```

여기서 `RZ`는 zero register다. 따라서 의미적으로는 다음과 같다.

```text
h0 = max(0, h0)
h1 = max(0, h1)
```

즉, ReLU는 실제 분기 명령이 아니라 floating-point min/max 계열 명령으로 처리된다.

---

## 7. 명령 수 비교

이번 실험의 핵심 명령 수는 다음과 같다.

| 커널                      | Load | FMUL | FFMA | Max/FMNMX | Store |
| ----------------------- | ---: | ---: | ---: | --------: | ----: |
| `linear_4_2_nobias_f32` |   12 |    2 |    6 |         0 |     2 |
| `linear_4_2_bias_f32`   |   14 |    0 |    8 |         0 |     2 |
| `linear_4_2_relu_f32`   |   14 |    0 |    8 |         2 |     2 |

해석은 다음과 같다.

```text
no bias:
input 4개 + weight 8개 = load 12개
첫 항은 FMUL
나머지는 FFMA
hidden store 2개

bias:
input 4개 + weight 8개 + bias 2개 = load 14개
bias가 accumulator seed로 사용됨
전체 dot product가 FFMA chain이 됨
hidden store 2개

bias + ReLU:
bias 버전과 동일한 load/FMA 구조
ReLU에 해당하는 max/FMNMX 2개 추가
hidden store 2개
```

---

## 8. FTZ 차이

Experiment 001에서는 `--use_fast_math` 영향으로 PTX/SASS에 다음과 같은 형태가 나타났다.

```text
fma.rn.ftz.f32
FFMA.FTZ
FMNMX.FTZ
```

하지만 이번 Experiment 002 결과에서는 다음처럼 나타난다.

```text
fma.rn.f32
FFMA
FMNMX
```

즉, 이번 업로드 기준 exp002 빌드는 FTZ가 붙지 않은 일반 FP32 형태에 가깝다.

또한 PTX dump의 `ptxasOptions`에는 다음만 보인다.

```text
-v --generate-line-info
```

따라서 이번 결과는 `fast_math / FTZ`가 없는 상태의 instruction pattern으로 기록하는 것이 맞다.

이 차이는 앞으로 별도 실험으로 분리할 가치가 있다.

```text
Experiment 후보:
fast_math off vs fast_math on
```

관찰할 항목은 다음과 같다.

```text
fma.rn.f32 → fma.rn.ftz.f32
FFMA → FFMA.FTZ
FMNMX → FMNMX.FTZ
정확도 차이
subnormal 처리 차이
```

---

## 9. Register 관찰

PTX의 float 가상 register 수는 다음과 같이 증가한다.

```text
linear_4_2_nobias_f32:
.reg .f32 %f<21>

linear_4_2_bias_f32:
.reg .f32 %f<23>

linear_4_2_relu_f32:
.reg .f32 %f<26>
```

흐름은 자연스럽다.

```text
no bias
→ bias 추가
→ ReLU용 max 결과 추가
```

즉, 고수준 기능이 추가될수록 단순히 명령어 수만 증가하는 것이 아니라, register lifetime과 임시 값도 증가한다.

다만 이것은 PTX 가상 register 수다. 실제 물리 register 사용량은 다음 명령으로 별도 확인해야 한다.

```bat
cuobjdump --dump-resource-usage build\experiments\exp002_4_2_bias_relu_variants\exp002_4_2_bias_relu_variants.exe
```

---

## 10. Materialization 관점

이번 세 커널은 모두 `4 → 2` 결과를 최종 출력으로 저장한다.

따라서 세 커널 모두 hidden 값 2개를 global memory에 저장한다.

```text
STG × 2
```

Experiment 001의 fused 커널에서는 hidden 값이 다음 Linear에 바로 소비되었기 때문에 global memory에 materialize되지 않았다.

하지만 Experiment 002에서는 커널의 최종 산출물이 hidden 값 자체다.

따라서 `h0`, `h1`은 반드시 global memory에 저장된다.

이를 정리하면 다음과 같다.

```text
Experiment 001 fused:
hidden = register lifetime

Experiment 002:
hidden = materialized output tensor
```

즉, 같은 `h0`, `h1`이라도 커널 경계와 소비 위치에 따라 물리적 존재 방식이 달라진다.

---

## 11. 표현 관점에서의 해석

고수준에서는 세 커널이 모두 `Linear`의 변형처럼 보인다.

```text
Linear
Linear + bias
Linear + bias + ReLU
```

하지만 PTX/SASS 관점에서는 다음처럼 분리된다.

```text
no bias:
Accumulator를 FMUL로 생성

bias:
Bias load를 AccumulatorSeed로 사용

ReLU:
Accumulator 결과에 FMNMX transform 적용

공통:
최종 hidden 값을 STG로 materialize
```

즉, `Linear`라는 연산자보다 더 낮은 표현 단위는 다음에 가깝다.

```text
AccumulatorSeed
FMAChain
OptionalNonlinearTransform
Materialize
```

이를 더 직접적으로 쓰면 다음과 같다.

```text
Load input
Load weight
Load optional bias
Create accumulator
Run FMA chain
Apply optional nonlinear transform
Store result if materialization is required
```

이 관점은 operator 중심 IR보다 실제 SASS 구조에 더 가깝다.

---

## 12. 이번 실험의 핵심 결론

Experiment 002에서 확인한 핵심은 다음이다.

> bias는 별도 add 연산이 아니라 FMA accumulator의 초기값으로 흡수된다.

> bias가 없으면 각 output accumulator를 만들기 위해 첫 항이 `FMUL`로 시작한다.

> ReLU는 branch가 아니라 `max.f32` 또는 `FMNMX` 계열 명령으로 구현된다.

> `4 → 2` 단독 커널에서는 hidden 값이 최종 출력이므로 `STG`를 통해 materialize된다.

이를 한 줄로 정리하면 다음과 같다.

```text
Linear는 하나의 단일 연산이 아니라,
AccumulatorSeed + FMAChain + OptionalTransform + Materialization의 조합이다.
```

---

## 13. 다음 실험 방향

다음 실험은 loop unroll 여부를 보는 것이 좋다.

```text
Experiment 003:
loop vs manual unroll vs pragma unroll
```

비교 대상은 다음과 같이 둘 수 있다.

```text
A. #pragma unroll 유지
B. #pragma unroll 제거
C. 수동 완전 전개
D. runtime loop bound 사용
```

관찰할 질문은 다음이다.

```text
작은 고정 loop는 pragma 없이도 자동 unroll되는가?
runtime loop bound가 들어오면 실제 BRA loop가 남는가?
SASS에서 loop counter와 branch가 나타나는가?
unroll이 register pressure를 증가시키는가?
instruction-level parallelism은 어떻게 달라지는가?
```

Experiment 002의 결론이 accumulator 구성 방식이었다면, Experiment 003의 결론은 다음 질문이 될 것이다.

```text
반복 구조는 실제 실행에서도 반복으로 남는가,
아니면 명령어 수준에서 완전히 펼쳐지는가?
```
