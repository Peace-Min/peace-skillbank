# 체커 백로그 — 실물 검출 28종 (issues_OSTES_6827.xls, 7,170건)

트랙 배정: **A**=dotnet format 자동(완료) · **B**=SparrowCommentFix/whitespace 결정론 · **C**=LLM/사람 판단.
Track C 가이드 md(`<체커키>.md`)는 **C 항목 우선**, 검출된 것만 lazy 생성. 건수는 이 xls 기준(코드 바뀌면 재추출).

| 체커 키 | 건수 | 심각도 | 트랙 | 비고 |
|---|---|---|---|---|
| PRACTICE.OBVIOUS_VARIABLE_TYPE.NOT_USED_IMPLICIT_TYPING | 1385 | 낮음 | **A** | var (IDE0007/8) |
| PRACTICE.OBJECT_INSTANTIATION.NOT_USED_IMPLICIT_TYPING | 1078 | 낮음 | **A** | var |
| FORMATTING.COMMENT.MISSING_PERIOD | 855 | 낮음 | **B** | 주석 마침표 (자작) |
| PRACTICE.LOOP_VARIABLE.NOT_USED_IMPLICIT_TYPING | 837 | 보통 | **A** | var(루프) |
| MISSING_PARENTHESIS_IN_EXPRESSION | 741 | 낮음 | **A** | 괄호 (IDE0048) |
| FORMATTING.BETWEEN_MEMBER_DEFINITION.MISSING_BLANK_LINE | 616 | 낮음 | **B** | 여백(멤버간 빈줄) |
| FORMATTING.COMMENT.LOWERCASE_FIRST_LETTER | 562 | 낮음 | **B** | 주석 첫글자 대문자 |
| FORMATTING.COMMENT.MISSING_SPACE_AFTER_DELIMITER | 457 | 낮음 | **B** | `//x`→`// x` |
| OVERLY_BROAD_CATCH | 139 | 보통 | **C** | catch(Exception) 좁히기=판단 |
| EMPTY_CATCH_BLOCK | 89 | 높음 | **C** | 빈 catch (CWE-390) |
| USE_ONE_STATEMENT_PER_LINE | 66 | 낮음 | **B** | 여백/레이아웃 |
| PRACTICE.OBJECT_INITIALIZATION.NOT_USED_INITIALIZER | 64 | 낮음 | **A** | 이니셜라이저 (IDE0017) |
| FORMATTING.CONTINUATION_LINE.BAD_INDENTATION | 51 | 낮음 | **B** | 여백(들여쓰기, whitespace) |
| FORWARD_NULL | 47 | 매우위험 | **C** | null 역참조 (CWE-476) |
| FORMATTING.COMMENT.BLOCK_OF_ASTERISK | 45 | 낮음 | **B** | 주석 별표블록 |
| UNCHECKED_NULL | 34 | 매우위험 | **C** | null 미검사 (CWE-476) |
| MISSING_BLANK_LINE_BEFORE_COMMENT | 31 | 낮음 | **B** | 주석 앞 빈줄 |
| NULL_RETURN | 18 | 매우위험 | **C** | null 반환 (CWE-476 경로) |
| RESOURCE_LEAK | 14 | 매우위험 | **C** | 자원 누수 (CWE-772). Dispose/using |
| PUBLIC_DATA_ASSIGNED_TO_PRIVATE_ARRAY | 9 | 위험 | **C** | 배열 참조 노출 (CWE-496) |
| USE_ONE_DECLARATION_PER_LINE | 9 | 낮음 | **B** | 여백/레이아웃 |
| NULL_RETURN_STD | 6 | 매우위험 | **C** | null 반환 |
| PRIVATE_COLLECTION | 5 | 위험 | **C** | 컬렉션 참조 노출 |
| LEAK.SYSTEM_INFORMATION | 4 | 높음 | **C** | 시스템 정보 노출 (CWE-200) |
| TOCTOU_RACE_CONDITION | 4 | 위험 | **C** | 검사-사용 경합 (CWE-367) |
| PRACTICE.FINALLY_BLOCK.RESOURCE_DISPOSITION_ONLY | 2 | 보통 | **C** | finally 자원해제 (검토) |
| FORMATTING.LINQ.QUERY_CLAUSE_ALIGNMENT | 1 | 낮음 | **B** | 여백(whitespace) |
| PRACTICE.ARRAY_DECLARATION.COMPLICATED_SYNTAX | 1 | 낮음 | **C** | 소량, 수동 |

## 집계
- **A (자동, dotnet format)**: 4종, **~4,105건** — 완료(Run-TrackA).
- **B (결정론 자작/whitespace)**: 11종, **~2,700건** — 주석 5종(~1,950)=SparrowCommentFix, 여백 6종(~750)=`dotnet format whitespace`.
- **C (LLM/사람 판단)**: 13종, **~370건** — 매우위험 119 + 높음 93 + 위험 18 + OVERLY_BROAD_CATCH 139 + 소량.

## 주의
- 건수는 **Track A 적용 *전*** 기준. A/B 적용 후 **Sparrow 재분석**하면 줄어든 새 xls가 나오고, 그걸 SparrowXlsExport로 재분리하면
  **"자동으로 안 지워진 잔여"** 만 남음 → 그 잔여가 진짜 C(수동/LLM) 대상. (Roslyn 경계 ≠ Sparrow 경계로 A/B에서 안 지워진 var류 포함)
