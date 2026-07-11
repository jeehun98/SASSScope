# SASSScope SASS Probe Example

FFMA 의존 사슬과 8-way 독립 accumulator를 비교하는 최소 GPU 프로브다.

## 가장 빠른 실행

```powershell
powershell -ExecutionPolicy Bypass `
  -File scripts\run_all.ps1 `
  -Arch 86 `
  -Samples 100 `
  -Warmups 10 `
  -Clean
```

단계별 진행은 `docs/process.md`, 오류 점검은 `docs/error_checklist.md`를 참고한다.

## 주요 검증 파일

```text
results/build/probe_ffma_build.txt
results/binary/sass_summary.txt
results/binary/probe_ffma_full.sass.txt
results/binary/probe_ffma_resource_usage.txt
results/runtime/runtime_summary.txt
results/runtime/runtime_check.txt
```

## 현재 자동 검사

```text
목표 커널 3개 존재 여부
FFMA 정적 개수
CS2R 개수
accumulator 레지스터 수
측정 구간 내 LD/ST
시작 타이머 뒤 setup 명령 가능성
의존/독립 실행 cycle 관계
checksum 유한성
```
