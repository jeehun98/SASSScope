# SASSScope Experiment 002
# 4 -> 2 Linear의 bias / ReLU 분리 관찰

## 목적

Experiment 001에서는 `4 -> 2 -> 4` 구조에서 split과 fused를 비교했다.

Experiment 002에서는 첫 번째 Linear만 더 작게 분해한다.

비교 대상은 다음 세 커널이다.

```text
linear_4_2_nobias_f32
linear_4_2_bias_f32
linear_4_2_relu_f32
```

## 관찰 질문

1. bias가 없으면 accumulator 초기화가 어떻게 나타나는가?
2. bias가 있으면 bias load가 FMA의 초기 accumulator로 들어가는가?
3. ReLU를 추가하면 PTX의 `max.ftz.f32`, SASS의 `FMNMX.FTZ`가 정확히 2개 추가되는가?
4. bias 없는 버전은 8 FMA인가, 아니면 첫 항이 FMUL로 분리되는가?
5. hidden output store 2개는 세 버전 모두 유지되는가?

## 예상 구조

| 커널 | input load | weight load | bias load | FMA/FMUL | ReLU | output store |
|---|---:|---:|---:|---:|---:|---:|
| no bias | 4 | 8 | 0 | 8 mul-add 계열 | 0 | 2 |
| bias | 4 | 8 | 2 | 8 FMA | 0 | 2 |
| bias + ReLU | 4 | 8 | 2 | 8 FMA | 2 | 2 |

주의할 점:

`no bias` 버전은 소스에서 첫 항을 `w*x`로 시작한다.
따라서 컴파일러가 이것을 어떻게 내리는지 확인해야 한다.

가능한 형태:

```text
FMUL + 3 FFMA per hidden
```

또는 최적화에 따라 다른 형태가 나올 수 있다.

## 실행

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build.ps1
powershell -ExecutionPolicy Bypass -File scripts/run.ps1
powershell -ExecutionPolicy Bypass -File scripts/dump_ptx.ps1
powershell -ExecutionPolicy Bypass -File scripts/dump_sass.ps1
```

## SASS에서 찾을 항목

```text
Function : linear_4_2_nobias_f32
Function : linear_4_2_bias_f32
Function : linear_4_2_relu_f32
```

명령 카운트:

```text
LDG
FFMA
FMUL
FMNMX
STG
```

## 핵심 비교

bias 없는 버전:

```text
h0 = w00*x0 + w01*x1 + w02*x2 + w03*x3
h1 = w10*x0 + w11*x1 + w12*x2 + w13*x3
```

bias 있는 버전:

```text
h0 = b0 + w00*x0 + w01*x1 + w02*x2 + w03*x3
h1 = b1 + w10*x0 + w11*x1 + w12*x2 + w13*x3
```

ReLU 버전:

```text
h0 = max(0, h0)
h1 = max(0, h1)
```

이 실험은 `bias`, `activation` 같은 고수준 의미가 실제 명령어 수준에서 어떤 작은 패턴으로 추가되는지 확인하기 위한 것이다.
