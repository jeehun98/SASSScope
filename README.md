# SASSScope

작은 신경망 계산이 CUDA C++ → PTX → SASS로 내려가며 어떤 형태로 바뀌는지 관찰하는 실험 프로젝트다.

첫 실험은 `4 → 2 → 4` MLP다.

- 분리 실행: `Linear(4→2) + ReLU`, `Linear(2→4)`
- 융합 실행: 전체를 단일 커널로 실행
- CPU reference와 결과 비교
- PTX/SASS dump
- ptxas register 사용량 확인

## 원칙

- 범용 프레임워크를 만들지 않는다.
- 큰 연산자를 먼저 정의하지 않는다.
- 작은 고정 shape 계산을 먼저 관찰한다.
- PTX와 SASS를 실제 근거로 기록한다.
- 새로운 추상화는 관찰 후에 정의한다.

## 환경

- Windows 10/11
- RTX 3080 Ti Laptop GPU
- CUDA Toolkit 12.x
- Visual Studio 2022 Build Tools
- CMake 3.24+
- Ninja

RTX 3080 Ti Laptop GPU는 Ampere 계열이며 기본 CUDA architecture는 `86`이다.

## 환경 확인

Developer PowerShell for VS 2022에서:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_env.ps1
```

## 빌드

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build.ps1
```

빌드 로그의 `ptxas info`에서 커널별 register 사용량을 확인한다.

## 실행

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run.ps1
```

## PTX/SASS 추출

```powershell
powershell -ExecutionPolicy Bypass -File scripts/dump_ptx.ps1
powershell -ExecutionPolicy Bypass -File scripts/dump_sass.ps1
```

결과:

```text
artifacts/sassscope.ptx.txt
artifacts/sassscope.sass.txt
```

## 첫 관찰 항목

다음 커널을 비교한다.

```text
linear_4_2_relu_f32
linear_2_4_f32
linear_4_2_4_fused_f32
```

관찰 대상:

- `LDG`, `STG`, `FFMA` 개수
- ReLU가 `FMAX`, compare/select 중 무엇으로 내려가는지
- 출력 4개 loop가 완전 unroll되는지
- split 버전의 hidden store/load가 fused 버전에서 사라지는지
- fused 버전의 register 사용량 증가
