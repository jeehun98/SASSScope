# SASSScope Experiment 001

# 4-2-4 Linear Layer의 PTX/SASS 관찰 기록

## 1. 실험 목적

이번 실험의 목적은 고수준 신경망 연산이 실제 GPU 기계어 수준에서 어떤 형태로 붕괴되는지 확인하는 것이다.

관찰 대상은 단순한 `4 → 2 → 4` 구조의 MLP다.

고수준 표현은 다음과 같다.

```text
Input(4)
  ↓
Linear(4 → 2)
  ↓
ReLU
  ↓
Linear(2 → 4)
  ↓
Output(4)
```

이 구조는 프레임워크 수준에서는 두 개의 `Linear` 연산자와 하나의 `ReLU` 연산자로 보인다. 하지만 PTX/SASS 수준에서는 `Linear`, `Layer`, `Tensor` 같은 개념이 직접 존재하지 않는다. 실제로 남는 것은 load, FMA, max, store, register value, address calculation이다.

따라서 이번 실험의 핵심 질문은 다음이다.

> 고수준 연산자 경계가 SASS에서도 실제 실행 경계로 남는가?

특히 확인하고 싶은 부분은 다음이다.

```text
Linear(4 → 2)의 결과인 h0, h1이
진짜 global memory에 저장되는가,
아니면 register 값으로만 존재하다가 다음 Linear에 바로 소비되는가?
```

---

## 2. 실험 환경

실험 대상 GPU는 RTX 3080 Ti Laptop GPU이며, Ampere 계열 GPU다. CUDA 아키텍처 타깃은 `sm_86`으로 설정했다.

PTX dump에서도 다음과 같이 `sm_86` 대상 코드가 생성된 것을 확인할 수 있다.

```text
.version 8.5
.target sm_86
.address_size 64
```

또한 fatbin 정보에서도 `arch = sm_86`, `code version = [8,5]`, `host = windows`, `compile_size = 64bit`로 확인된다.

사용한 주요 조건은 다음과 같다.

```text
GPU: RTX 3080 Ti Laptop GPU
Architecture: Ampere
CUDA target: sm_86
CUDA Toolkit: 12.6 계열
OS: Windows
Build system: CMake + Ninja + MSVC
관찰 도구: cuobjdump --dump-ptx, cuobjdump --dump-sass
```

---

## 3. 실험 커널 구성

이번 실험에는 세 개의 CUDA 커널이 있다.

```text
linear_4_2_relu_f32
linear_2_4_f32
linear_4_2_4_fused_f32
```

첫 번째와 두 번째 커널은 split 실행을 의미한다.

```text
Kernel 1:
Linear(4 → 2) + ReLU

Kernel 2:
Linear(2 → 4)
```

세 번째 커널은 fused 실행을 의미한다.

```text
Kernel 3:
Linear(4 → 2) + ReLU + Linear(2 → 4)
```

즉, 같은 계산을 두 방식으로 구현했다.

```text
split version:
x → kernel1 → h → kernel2 → y

fused version:
x → single kernel → y
```

---

## 4. 수학적 계산량

입력 차원은 4, hidden 차원은 2, 출력 차원은 4다.

첫 번째 Linear는 다음 계산을 수행한다.

```text
h0 = ReLU(w00*x0 + w01*x1 + w02*x2 + w03*x3 + b0)
h1 = ReLU(w10*x0 + w11*x1 + w12*x2 + w13*x3 + b1)
```

따라서 첫 번째 Linear의 FMA 수는 다음과 같다.

```text
2 hidden units × 4 inputs = 8 FMA
```

두 번째 Linear는 다음 계산을 수행한다.

```text
y0 = v00*h0 + v01*h1 + c0
y1 = v10*h0 + v11*h1 + c1
y2 = v20*h0 + v21*h1 + c2
y3 = v30*h0 + v31*h1 + c3
```

따라서 두 번째 Linear의 FMA 수는 다음과 같다.

```text
4 outputs × 2 hidden values = 8 FMA
```

전체 계산량은 다음과 같다.

```text
총 FMA 수 = 8 + 8 = 16
ReLU 수 = 2
최종 output store 수 = 4
```

이 계산량 자체는 split과 fused에서 동일해야 한다. 차이는 계산량이 아니라 중간값 `h0`, `h1`이 메모리에 materialize되는지 여부다.

---

## 5. PTX 관찰 결과

PTX에서 세 커널은 각각 `.visible .entry` 형태로 나타난다. `linear_4_2_relu_f32`, `linear_2_4_f32`, `linear_4_2_4_fused_f32` 항목이 모두 확인된다.

### 5.1 split 첫 번째 커널: `linear_4_2_relu_f32`

이 커널은 다음을 수행한다.

```text
x load
W1 load
b1 load
FMA 8회
ReLU 2회
hidden h0, h1 store
```

PTX에서는 다음 명령 계열이 관찰된다.

```text
ld.global.nc.f32
fma.rn.ftz.f32
max.ftz.f32
st.global.f32
```

첫 번째 커널의 핵심은 마지막에 hidden 값 2개를 global memory에 저장한다는 점이다.

```text
st.global.f32 ... h0
st.global.f32 ... h1
```

즉, split version에서는 hidden layer가 실제 메모리 객체로 존재한다.

### 5.2 split 두 번째 커널: `linear_2_4_f32`

두 번째 커널은 첫 번째 커널이 저장한 hidden 값을 다시 읽는다.

```text
h0 load
h1 load
W2 load
b2 load
FMA 8회
output y0~y3 store
```

PTX에서 `linear_2_4_f32`는 hidden 값을 `ld.global.nc.f32`로 읽고, 네 개의 output을 각각 `st.global.f32`로 저장한다. 두 번째 커널의 출력 저장 구간에서 `st.global.f32`가 네 번 나타난다.

따라서 split 실행은 다음 구조를 갖는다.

```text
Kernel 1:
h0, h1 store

Kernel 2:
h0, h1 load
```

이것이 split version의 핵심 오버헤드다.

### 5.3 fused 커널: `linear_4_2_4_fused_f32`

fused 커널은 첫 번째 Linear와 ReLU 결과를 global memory에 저장하지 않는다.

PTX에서 fused 커널은 `linear_4_2_4_fused_f32` 항목으로 나타나며, `.reg .f32 %f<46>`처럼 split 커널보다 더 많은 가상 float register를 사용한다.

중요한 점은 fused 커널 내부에서 `max.ftz.f32`로 계산된 hidden 값이 바로 다음 `fma.rn.ftz.f32`의 입력으로 사용된다는 것이다.

즉, hidden 값은 다음과 같은 형태로 존재한다.

```text
memory tensor가 아니라
register value
```

fused 커널의 후반부에서는 output 4개를 계산한 뒤 각각 `st.global.f32`로 저장한다. hidden store는 없고, 최종 output store만 존재한다.

---

## 6. PTX 명령 수 비교

PTX 기준으로 관찰한 구조는 다음과 같이 정리할 수 있다.

| 실행 방식                    | global load | FMA | ReLU max | global store |
| ------------------------ | ----------: | --: | -------: | -----------: |
| `linear_4_2_relu_f32`    |          14 |   8 |        2 |            2 |
| `linear_2_4_f32`         |          14 |   8 |        0 |            4 |
| split 합계                 |          28 |  16 |        2 |            6 |
| `linear_4_2_4_fused_f32` |          26 |  16 |        2 |            4 |

따라서 fused version은 split version 대비 다음을 제거했다.

```text
hidden h0, h1 store 2개 제거
hidden h0, h1 load 2개 제거
```

계산량은 줄지 않았다.

```text
FMA 16개
ReLU 2개
```

이 값은 그대로 유지된다.

줄어든 것은 중간 tensor의 메모리 왕복이다.

---

## 7. SASS 관찰 결과

SASS에서도 PTX에서 관찰한 구조가 그대로 확인된다.

세 커널은 SASS에서 다음 함수로 나타난다.

```text
Function : linear_4_2_4_fused_f32
Function : linear_2_4_f32
Function : linear_4_2_relu_f32
```

SASS dump에서는 `code for sm_86` 아래에 각 커널의 실제 Ampere 명령어가 표시된다.

주요 명령은 다음이다.

```text
LDG.E.CONSTANT
FFMA.FTZ
FMNMX.FTZ
STG.E
ISETP
EXIT
IMAD.WIDE
SHF.L.U32
```

---

## 8. SASS 명령 수 비교

SASS 기준 핵심 명령 수는 다음과 같다.

| 실행 방식                    | LDG | FFMA | FMNMX | STG |
| ------------------------ | --: | ---: | ----: | --: |
| `linear_4_2_relu_f32`    |  14 |    8 |     2 |   2 |
| `linear_2_4_f32`         |  14 |    8 |     0 |   4 |
| split 합계                 |  28 |   16 |     2 |   6 |
| `linear_4_2_4_fused_f32` |  26 |   16 |     2 |   4 |

PTX에서 본 것과 동일한 결론이 SASS에서도 유지된다.

```text
split:
LDG 28개
STG 6개

fused:
LDG 26개
STG 4개
```

즉, fused 커널에서는 hidden 값의 global memory store/load가 사라졌다.

---

## 9. ReLU의 실제 SASS 표현

고수준 코드에서는 ReLU가 다음 의미를 갖는다.

```text
h = max(h, 0)
```

PTX에서는 다음처럼 나타난다.

```text
max.ftz.f32
```

SASS에서는 다음처럼 나타난다.

```text
FMNMX.FTZ R7,  RZ, R6,  !PT
FMNMX.FTZ R19, RZ, R19, !PT
```

`RZ`는 zero register다. 따라서 이는 실질적으로 다음 계산이다.

```text
max(0, h)
```

중요한 점은 ReLU가 branch로 구현되지 않았다는 것이다.

즉, 다음과 같은 분기 구조가 아니다.

```text
if h < 0:
    h = 0
```

실제 SASS에서는 `FMNMX.FTZ` 명령으로 처리된다. split 첫 번째 커널에서도 FFMA 후 FMNMX가 나타난다.

---

## 10. loop unrolling 확인

소스 코드의 두 번째 Linear 부분은 `for j in 0..3` 구조로 작성되어 있다.

하지만 PTX와 SASS에는 loop counter나 반복 branch가 남아 있지 않다.

출력 4개는 모두 전개되어 있다.

```text
y0 계산
y1 계산
y2 계산
y3 계산
```

SASS에서도 최종 output store가 다음처럼 네 번 직접 나타난다.

```text
STG.E [R2.64],     R5
STG.E [R2.64+0x4], R19
STG.E [R2.64+0x8], R29
STG.E [R2.64+0xc], R27
```

즉, 출력 loop는 완전히 unroll되었다. fused 커널 끝부분에서도 네 개의 output store가 연속적으로 확인된다.

---

## 11. 컴파일러의 명령 재배치

중요한 관찰은 SASS가 C++ 코드의 순서를 그대로 따르지 않는다는 점이다.

소스 코드 관점에서는 두 번째 Linear가 다음처럼 보인다.

```text
y0 = b0 + w00*h0 + w01*h1
y1 = b1 + w10*h0 + w11*h1
y2 = b2 + w20*h0 + w21*h1
y3 = b3 + w30*h0 + w31*h1
```

즉, 하나의 output을 완성한 뒤 다음 output으로 넘어가는 구조다.

하지만 fused SASS에서는 대략 다음처럼 재배치된다.

```text
h0가 y0에 주는 기여
h0가 y1에 주는 기여
h0가 y2에 주는 기여
h0가 y3에 주는 기여

h1이 y0에 주는 기여
h1이 y1에 주는 기여
h1이 y2에 주는 기여
h1이 y3에 주는 기여
```

실제 SASS에서는 다음처럼 `R4.reuse`, `R11.reuse`가 나타난다.

```text
FFMA.FTZ R20, R4.reuse,  R20, R17
FFMA.FTZ R28, R4.reuse,  R28, R15
FFMA.FTZ R29, R4.reuse,  R29, R16
FFMA.FTZ R27, R4,        R27, R24

FFMA.FTZ R5,  R11.reuse, R30, R20
FFMA.FTZ R19, R11.reuse, R19, R28
FFMA.FTZ R29, R11.reuse, R18, R29
FFMA.FTZ R27, R11,       R26, R27
```

여기서 `R4`는 ReLU 이후의 첫 번째 hidden 값, `R11`은 두 번째 hidden 값으로 볼 수 있다. fused 커널의 SASS 구간에서 이러한 FFMA 배치와 operand reuse가 확인된다.

이것은 단순 번역이 아니다.

컴파일러는 다음을 고려해 명령을 재배치했다.

```text
같은 hidden 값을 여러 output accumulator가 재사용
독립적인 output accumulator들을 동시에 유지
FMA dependency chain을 분산
instruction-level parallelism 확보
```

---

## 12. 첫 번째 Linear도 교차 스케줄링됨

첫 번째 Linear는 수학적으로 다음 두 값을 계산한다.

```text
h0 = W1[0] dot x + b1[0]
h1 = W1[1] dot x + b1[1]
```

단순하게 생각하면 `h0`를 완전히 계산한 뒤 `h1`을 계산할 것처럼 보인다.

하지만 SASS에서는 두 accumulator chain이 교차 배치된다.

```text
h0 FMA 1
h1 FMA 1
h0 FMA 2
h1 FMA 2
h0 FMA 3
h1 FMA 3
h0 FMA 4
h1 FMA 4
```

이 구조는 하나의 accumulator만 연속으로 계산할 때 생기는 dependency latency를 줄일 수 있다.

즉, SASS 관점에서 중요한 것은 `Linear`라는 이름이 아니라 다음이다.

```text
몇 개의 독립 accumulator chain이 있는가?
각 accumulator가 어떤 register value를 소비하는가?
같은 input value가 여러 accumulator에 재사용되는가?
```

---

## 13. bounds check와 분기

소스 코드에는 다음 조건이 있다.

```cpp
if (n >= batch) {
    return;
}
```

PTX에서는 다음처럼 나타난다.

```text
setp.ge.s32
@p bra
```

SASS에서는 다음처럼 나타난다.

```text
ISETP.GE.AND P0, PT, R7, batch, PT
@P0 EXIT
```

즉, 범위를 벗어난 thread는 바로 `EXIT`한다.

SASS 끝부분에 나타나는 다음 형태는 알고리즘 loop가 아니다.

```text
EXIT
BRA
NOP
NOP
...
```

`EXIT` 뒤의 `BRA`와 `NOP`들은 코드 패딩, 정렬, disassembly 출력 형식과 관련된 것으로 보이며, 실제 계산 반복 구조로 해석하면 안 된다.

---

## 14. 주소 계산

PTX에서는 주소 계산이 비교적 명시적으로 나타난다.

```text
shl
mul.wide
add
```

SASS에서는 일부 주소 계산이 다음 명령으로 결합된다.

```text
SHF.L.U32
IMAD.WIDE
```

예를 들어 다음 형태는 index와 stride, base pointer를 결합한 주소 계산이다.

```text
IMAD.WIDE R18, R7, R0, base
```

의미적으로는 다음과 같다.

```text
address = base + index * stride
```

즉, PTX는 가상 ISA라서 계산이 더 분리되어 보이고, SASS는 실제 Ampere 명령으로 lowering되면서 주소 계산이 더 압축된다.

---

## 15. 레지스터 사용 증가

PTX 가상 레지스터 선언을 보면 fused 커널이 split 개별 커널보다 더 많은 가상 float register를 사용한다.

```text
linear_4_2_relu_f32:
.reg .f32 %f<26>

linear_2_4_f32:
.reg .f32 %f<23>

linear_4_2_4_fused_f32:
.reg .f32 %f<46>
```

fused 커널은 hidden 값을 메모리에 저장하지 않고 register에 유지한 채 다음 계산까지 이어간다. 따라서 register pressure가 증가하는 것은 자연스럽다. fused 커널의 PTX 선언에서 `.reg .f32 %f<46>`이 확인된다.

다만 현재 SASS dump에서 local memory spill을 의미하는 명령은 관찰되지 않는다.

예를 들어 다음과 같은 명령이 보이지 않는다.

```text
LDL
STL
LD.LOCAL
ST.LOCAL
```

따라서 현재 크기의 fused 커널에서는 register 사용량 증가는 있지만, spill로 인한 local memory 왕복은 발생하지 않은 것으로 볼 수 있다.

정확한 실제 register 개수는 다음 명령으로 추가 확인하는 것이 좋다.

```bat
cuobjdump --dump-resource-usage build\sassscope.exe
```

또는 빌드 로그의 `ptxas info : Used XX registers`를 기록한다.

---

## 16. `LDG.E.CONSTANT` 해석 주의

SASS에서 많은 load가 다음처럼 나타난다.

```text
LDG.E.CONSTANT
```

이 표현만 보고 weight 배열이 CUDA의 `__constant__` memory에 들어갔다고 해석하면 안 된다.

PTX에서는 해당 load가 다음처럼 나타난다.

```text
ld.global.nc.f32
```

즉, 소스 포인터가 가리키는 global memory를 읽고 있다. PTX dump에서 `ld.global.nc.f32`가 사용되고, SASS dump에서는 이것이 `LDG.E.CONSTANT` 형태로 lowering되어 나타난다.
현재 실험에서는 모든 thread가 같은 weight 주소를 읽는다. 따라서 warp 단위에서는 uniform load 성격이 생길 수 있고, 캐시 또는 operand reuse의 이점을 받을 수 있다. 그러나 이것은 소스 수준에서 `__constant__` memory를 명시적으로 사용했다는 뜻은 아니다.

---

## 17. `FTZ` 의미

PTX와 SASS에서 다음 표시가 반복해서 나타난다.

```text
fma.rn.ftz.f32
max.ftz.f32
FFMA.FTZ
FMNMX.FTZ
```

`FTZ`는 flush-to-zero를 의미한다.

아주 작은 subnormal floating-point 값은 정밀하게 유지되지 않고 0으로 처리될 수 있다.

이는 빌드 옵션의 다음 설정과 관련된다.

```text
--use_fast_math
```

따라서 현재 커널의 floating-point 의미론은 엄밀한 IEEE FP32라기보다 빠른 FP32 실행에 가깝다.

신경망 계산에서는 일반적으로 큰 문제가 아닐 수 있지만, PTX/SASS 의미론을 관찰하는 프로젝트에서는 반드시 기록해야 한다.

---

## 18. 이번 실험의 핵심 발견

이번 실험에서 가장 중요한 결론은 다음이다.

> fused 커널에서는 hidden layer가 계산상으로는 존재하지만, 메모리 객체로는 존재하지 않는다.

split version에서는 `h0`, `h1`이 다음 형태로 존재한다.

```text
global memory에 저장되는 tensor element
```

fused version에서는 `h0`, `h1`이 다음 형태로 존재한다.

```text
일정 시간 동안 살아 있는 register value
```

즉, 고수준 표현에서는 동일하게 hidden layer가 존재하지만, 실제 기계어 수준에서는 완전히 다른 물리적 구조를 가진다.

split version:

```text
x load
W1 load
FMA
ReLU
h store

h load
W2 load
FMA
y store
```

fused version:

```text
x load
W1 load
FMA
ReLU
h register 유지
W2 load
FMA
y store
```

따라서 `Linear → ReLU → Linear`이라는 연산자 표현은 실행 구조의 본질을 완전히 설명하지 못한다.

실제 SASS에서 더 중요한 것은 다음이다.

```text
값이 어디서 load되는가
값이 register에 얼마나 오래 살아 있는가
값이 몇 개의 accumulator에 소비되는가
값이 global memory에 materialize되는가
최종적으로 어떤 값만 store되는가
```

---

## 19. 표현 관점에서의 해석

기존 프레임워크 관점은 다음과 같다.

```text
Operator 중심 표현
Tensor 중심 표현
Layer 중심 표현
```

이번 실험은 다른 관점을 제안한다.

```text
Value lifetime 중심 표현
Materialization 중심 표현
Data movement 중심 표현
Accumulator chain 중심 표현
```

고수준 연산자는 사람이 이해하기 좋지만, 실제 실행에서는 너무 큰 단위일 수 있다.

예를 들어 `Linear`라는 연산자는 SASS에서 다음으로 분해된다.

```text
input load
weight load
bias load
FFMA chain
optional nonlinear transform
store or register forwarding
```

그리고 fused 실행에서는 `Linear`의 출력 tensor가 사라진다.

따라서 앞으로의 IR 또는 compiler 표현은 다음 질문을 중심으로 설계할 수 있다.

```text
이 값은 반드시 tensor로 materialize되어야 하는가?
아니면 register value로 다음 계산에 바로 전달될 수 있는가?

이 연산자는 독립 operator인가?
아니면 accumulator chain의 일부인가?

layer boundary는 의미론적 경계인가?
아니면 단순한 작성상의 경계인가?
```

---

## 20. 다음 실험 방향

이번 실험은 `4 → 2 → 4` 구조에서 split과 fused의 차이를 확인했다.

다음 실험은 다음 순서로 진행하는 것이 좋다.

```text
Experiment 002:
4 → 2 Linear only
bias 없음 / bias 있음 비교

Experiment 003:
ReLU 유무 비교
max 명령이 어떻게 추가되는지 확인

Experiment 004:
manual unroll과 for loop 비교
#pragma unroll 제거 시 SASS 변화 확인

Experiment 005:
--use_fast_math 제거
FTZ 없는 PTX/SASS와 비교

Experiment 006:
float4 vector store 실험
STG.E 4개가 STG.128로 바뀌는지 확인

Experiment 007:
weight를 __constant__ memory로 이동
LDG.E.CONSTANT 표현과 실제 constant memory 사용 비교

Experiment 008:
FP16 / half2 버전 작성
HFMA, HMMA, vectorized half 연산 여부 확인

Experiment 009:
한 thread가 한 sample을 처리하는 방식과
한 warp가 한 sample을 처리하는 방식 비교

Experiment 010:
4 → 2 → 4를 16 → 8 → 16, 32 → 16 → 32로 확장
fusion이 register pressure와 occupancy에 미치는 영향 확인
```

---

## 21. 현재 결론

이번 실험은 작은 구조였지만 중요한 사실을 보여준다.

고수준에서는 다음과 같이 보인다.

```text
Linear
ReLU
Linear
```

PTX에서는 다음과 같이 보인다.

```text
global load
fma
max
global store
```

SASS에서는 다음과 같이 보인다.

```text
주소 계산
LDG
FFMA
FMNMX
register reuse
STG
EXIT
```

따라서 실제 실행의 본질은 연산자 이름이 아니라 값의 흐름이다.

최종 결론은 다음과 같다.

> hidden layer는 수학적으로 존재하지만, 반드시 tensor로 존재할 필요는 없다.
> fused SASS에서는 hidden layer가 global memory 객체가 아니라 register lifetime으로만 존재한다.

이 관찰은 앞으로의 SASSScope 프로젝트 방향을 정한다.

목표는 단순히 CUDA kernel을 빠르게 만드는 것이 아니다.

목표는 다음이다.

> 고수준 연산자를 먼저 정의하고 거기에 갇히는 대신,
> 실제 SASS에서 반복적으로 나타나는 value flow, accumulator chain, materialization pattern을 관찰하고,
> 그로부터 더 낮고 정확한 계산 표현을 역으로 정의하는 것.
