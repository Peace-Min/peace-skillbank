# Sparrow 공식 Rule 파일 (OSTES 신뢰성시험 대상 체커)

파수(Fasoo) Sparrow가 **체커별로 제공하는 공식 Rule 정의**를 사용자가 GUI에서 복사해 반입한 원문이다.
"무엇을 왜 검출하는가 + BadCase/GoodCase 예시"의 **그라운드 트루스**. 우리 도구/가이드가 이걸로 검증된다.

> ⚠️ **교훈(반복 확인됨)**: 체커 키 이름만으로 규칙을 추론하면 틀린다(Track B 실패 사례). 규칙 구현·가이드
> 작성 전 **반드시 이 원문의 GoodCase를 대조**할 것.

## 도구 매핑 (2026-07-14 6869 측정 기준)

| Rule 파일 | 처리 | 상태 |
|---|---|---|
| PRACTICE.OBVIOUS_VARIABLE_TYPE… | SparrowSyntaxFix `nullcast` + SparrowSyntaxFix var | ✅ 대량 소거(1385→48) |
| PRACTICE.OBJECT_INSTANTIATION… | SparrowSyntaxFix var(IDE0007) | ⚠️ 부분(1078→515), 레거시 미적용 잔존 |
| PRACTICE.LOOP_VARIABLE… | SparrowSyntaxFix var(IDE0008) | ⚠️ 부분(837→117) |
| MISSING_PARENTHESIS(파일 없음) | SparrowSyntaxFix `parens` | ✅ **완전 소거(741→0)** |
| FORMATTING.COMMENT.MISSING_SPACE | SparrowCommentFix `space` | ❌ 동일경로 미소거(블록주석 미지원) |
| FORMATTING.COMMENT.MISSING_PERIOD | SparrowCommentFix `period` | ❌ 동일경로 미소거(`/** */` 미지원) |
| FORMATTING.COMMENT.LOWERCASE_FIRST_LETTER | — | ❌ 미커버(한글/기호 결정론불가) |
| FORMATTING.COMMENT.BLOCK_OF_ASTERISK | — | ❌ 미커버(보류) |
| FORMATTING.BETWEEN_MEMBER_DEFINITION.MISSING_BLANK_LINE | — | ❌ 미커버 |
| FORMATTING.CONTINUATION_LINE.BAD_INDENTATION | — | ❌ 미커버 |
| USE_ONE_STATEMENT_PER_LINE | — | ❌ 미커버 |
| EMPTY_CATCH_BLOCK / OVERLY_BROAD_CATCH | Track C(사람/LLM) | 판단 필요 |

전체 측정·진단은 [`../RESULTS-6869-analysis.md`](../RESULTS-6869-analysis.md) 참조.
