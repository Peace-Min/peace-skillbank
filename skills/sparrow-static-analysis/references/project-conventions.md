# OSTES 프로젝트 처리 규약 (Track C)

> 이 문서는 **OSTES 프로젝트 전용 오버라이드**다. 공용 체커 가이드(`references/checkers/*.md`)와
> 트리아지 프롬프트(`triage-prompt.md`)는 그대로 두고, 이 문서 + 각 요청에 삽입되는 정책 섹션으로만
> 프로젝트 정책을 강제한다. 이 정책은 기존 가이드의 "흔한 위양성 패턴"을
> **"이렇게 보여도 넘기지 말고 이렇게 고쳐라"**로 재해석한다.

## (공통) 처리 정책

- Policy A: Sparrow가 나온 항목은 **전건(全件) 수정 대상**이다.
- verdict에 **위양성 사용 금지** — 작업범위-스킵(false positive)으로 항목을 빼지 않는다.
- 고칠 수 있으면 `verdict=진성` + fix(before/after)를 작성해 실제로 수정한다.
- 소스/예외목록 등 문맥이 부족하면 `verdict=보류` + `needs_context=true`로 둔다. **단, 이는 "안 함"이 아니라
  "문맥 확보 후 반드시 수정"하는 대기 상태다.** missing_context에 필요한 파일/심볼/범위를 적는다.
- 스니펫만으로 **blind 수정 금지**: 반드시 실제 파일을 열어 전체 흐름을 확인한 뒤 수정한다.
- 커밋은 **체커 단위**로 묶는다.
- G1(빌드) / G2(재스캔) 게이트는 **사용자**가 수행한다.

## 프로젝트 규약

- 로깅: 예외/오류는 `LogUtil.Error(this, ex.ToString())`로 기록한다. `Console.WriteLine` 금지.
- 파일삭제: `SafeFileUtil.SafeDelete(path, out err)`를 사용한다. `File.Exists` 프리체크 금지(TOCTOU 유발).

## OVERLY_BROAD_CATCH

- `catch(Exception)` / `catch`(무형) **절대 금지** — 최상위 경계 핸들러도 예외 없음.
- try 본문에서 호출하는 각 API의 **문서화된 예외형을 전부 열거**해, 예외형마다 명시 catch 절을 작성한다.
- 빈 catch 금지 → `LogUtil.Error(this, ex.ToString())`로 기록.
- 예외 열거가 부족하면 skip이 아니다 → 예외목록/소스를 확보한 뒤 **반드시 수정**(보류+needs_context).
- 참고: `SafeFileUtil.SafeDelete`가 File 관련 예외를 전부 명시 catch로 잡는 모범 패턴이다.

## EMPTY_CATCH_BLOCK

- 빈 catch **금지** → `LogUtil.Error(this, ex.ToString())`로 예외 정보를 남긴다.
- `Console.WriteLine("Exception")`로 바꾸는 것은 **오답**이다(예외 정보 상실 + 빈 catch 성격 잔존).
- 정말로 무시해야 하는 예외라면 사유를 주석으로 남기되, 본문은 최소한 LogUtil.Error를 호출한다.

## LEAK.SYSTEM_INFORMATION

- catch에서 시스템정보를 외부로 출력하는 코드는 **삭제가 아니라 내부 `LogUtil.Error`로 리다이렉트**한다.
- 외부(사용자/응답)에는 일반화된 메시지 + 상관관계 ID만 노출한다.
- 출력을 그냥 삭제하면 빈 catch가 되어 **오답**이다(예외 정보 상실).

## TOCTOU_RACE_CONDITION

- 파일삭제 TOCTOU는 `SafeFileUtil.SafeDelete(path, out err)`로 대체한다.
- `File.Exists(p)` 프리체크 분기를 제거한다(검사-사용 사이 경합 제거).
- 삭제 실패는 out err로 받아 `LogUtil.Error`로 남긴다.
