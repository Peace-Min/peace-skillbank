# FORWARD_NULL @ Foo.cs:88

| 필드 | 값 |
|---|---|
| ID | 5001 |
| 유형 | 코딩 실무 |
| 위험도 | 매우위험 |
| 언어 | C# |
| 체커 타입 | SEMANTIC |
| 체커 키 | FORWARD_NULL |
| 체커명 | 널 값 역참조 |
| 라인 | 88 |
| 파일명 | Foo.cs |
| 함수 | Process |
| 이슈 상태 | 미확인 |

## 체커 설명
널 값 역참조 체커는 널 상수나 널이 할당된 변수를 역참조하는 경우를 검출합니다.

## 수정 대상
- 파일: `Foo.cs`
- 라인: `88`
- 지시: **이 라인과 이 라인에서 직접 드러난 결함만 수정한다. 주변 문맥은 판단용이며 임의 수정 금지.**
- 대상 코드: `  88: Process(node.Value);`

## 소스 코드
> ⚠️ **수정 대상 = 라인 88** (아래 소스의 `TARGET LINE` 표시). 그 라인만 고치고, 표시 없는 다른 라인은 임의로 수정하지 마라.

```text
  86: var node = list.FirstOrDefault(n => n.Id == id);
  87: // no guard here
  88: Process(node.Value);    <<< TARGET LINE 88 - FIX THIS LINE >>>
```
