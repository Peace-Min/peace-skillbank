# RESOURCE_LEAK @ ConnFactory.cs:23

| 필드 | 값 |
|---|---|
| ID | 5002 |
| 유형 | 코딩 실무 |
| 위험도 | 매우위험 |
| 언어 | C# |
| 체커 타입 | SEMANTIC |
| 체커 키 | RESOURCE_LEAK |
| 체커명 | 자원 누수 |
| 라인 | 23 |
| 파일명 | ConnFactory.cs |
| 함수 | Create |
| 이슈 상태 | 미확인 |

## 체커 설명
리소스 누수 체커는 파일, 소켓 등 리소스를 할당한 후에 해제하지 않는 코드를 검출합니다.

## 수정 대상
- 파일: `ConnFactory.cs`
- 라인: `23`
- 지시: **이 라인은 수정 기준점(anchor)이다. 결함 제거에 필요한 최소 인접 범위까지 수정하되, 무관한 주변 코드는 임의 수정하지 않는다.**
- 대상 코드: `  23:     return conn;   // 소유권을 호출측에 이전`

## 소스 코드
> ⚠️ **수정 대상 = 라인 23** (아래 소스의 `TARGET LINE` 표시). 그 라인만 고치고, 표시 없는 다른 라인은 임의로 수정하지 마라.

```text
  21: public SqlConnection Create(string cs) {
  22:     var conn = new SqlConnection(cs);
  23:     return conn;   // 소유권을 호출측에 이전    <<< TARGET LINE 23 - ANCHOR >>>
  24: }
```
