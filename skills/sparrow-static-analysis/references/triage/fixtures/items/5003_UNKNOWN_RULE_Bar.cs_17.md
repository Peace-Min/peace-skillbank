# UNKNOWN_RULE @ Bar.cs:17

| 필드 | 값 |
|---|---|
| ID | 5003 |
| 위험도 | 보통 |
| 체커 키 | UNKNOWN_RULE |
| 체커명 | 미등록 체커 |
| 라인 | 17 |
| 파일명 | Bar.cs |
| 함수 | Execute |

## 체커 설명
이 체커는 references/checkers에 아직 전용 가이드가 없는 신규 Sparrow 체커입니다. XLS 설명과 소스 위치를 근거로 수정 방향을 판단해야 합니다.

## 수정 대상
- 파일: `Bar.cs`
- 라인: `17`
- 지시: **이 라인은 수정 기준점(anchor)이다. 결함 제거에 필요한 최소 인접 범위까지 수정하되, 무관한 주변 코드는 임의 수정하지 않는다.**
- 대상 코드: `  17: DoRiskyWork(input);`

## 소스 코드
> ⚠️ **수정 대상 = 라인 17** (아래 소스의 `TARGET LINE` 표시). 그 라인만 고치고, 표시 없는 다른 라인은 임의로 수정하지 마라.

```text
  15: var input = GetInput();
  16: // Sparrow checker guide is not registered yet.
  17: DoRiskyWork(input);    <<< TARGET LINE 17 - ANCHOR >>>
```
