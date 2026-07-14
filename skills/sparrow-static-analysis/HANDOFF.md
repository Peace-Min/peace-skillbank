# Sparrow 정적분석 처리 파이프라인 — HANDOFF (세션 인계 마스터)

> **다른 세션은 이 파일부터 읽으면 바로 착수 가능.** 목표·현재상태·결정·게이트를 담고, 남은 작업(Track B / Track C)은
> 각각 자기완결 브리프로 아래에 있음. 대화 히스토리 없이도 시작할 수 있게 작성.

## 0. 한 줄 요약
파수 **Sparrow(스패로우) 정적분석(신뢰성시험)** 결과 xls를 **사내 LLM + 결정론 도구**로 처리하는 파이프라인.
대상 코드 = **OSTES**(방산, .NET **Framework 4.7.2**, **레거시(non-SDK) .csproj**, 다중 프로젝트 솔루션).
환경 = **폐쇄망**(약한 로컬 모델 + 별도 머신의 프론티어). **Excel/COM 금지**(문서중앙화=클라우디움 개입) → **전부 CLI 기반**.

## 1. 사용자 확정 시퀀스 & 게이트
1) xls → **항목별 md** 분리(결정론) → 2) **체커별** 룰셋/해결방안 md → 3) **triage**(진성수정 / 위양성 사유서 / 보류;
룰셋 매칭은 **체커 키 사전조회**로 결정론화) → 4) **항목/체커별 개별 커밋**(사람 검수 단위).
**검증 게이트 4단**: G0 diff 스코프 → G1 빌드 통과 → G2 **Sparrow 재분석**(그 체커 검출 소멸 + 신규 0) → G3 사람 승인.
> **핵심 원칙**: 판단 없는 기계적 작업 = **결정론 툴**, 판단 필요 = **LLM/사람**. 약한 로컬 모델 노출 최소화.
> **검증의 진짜 기준은 도구 출력이 아니라 "Sparrow 재분석 후 건수 전/후"** (Roslyn 경계 ≠ Sparrow 경계).

## 2. 3-트랙 분할 (부담 7,170 → LLM은 ~370)
| 트랙 | 대상(체커) | 방법 | 상태 |
|---|---|---|---|
| **A 자동** | var·괄호·이니셜라이저 (~4,100) | **dotnet format + .editorconfig** (SDK 내장, 자작 아님) | ✅ **완료** |
| **B 결정론(자작)** | 주석·여백 (~2,700) | **SparrowCommentFix**(자작 Roslyn, 주석 trivia만) + `dotnet format whitespace` | 🟨 **SparrowCommentFix: space·period 적용(실물검증). capitalize/blankline은 실물 대조 결과 부적합으로 도구에서 제거(capitalize=한글/기호 결정론불가, blankline=반대타깃), asterisk 보류. 여백은 미착수** |
| **C 판단** | 보안·품질 (~370: 매우위험/높음/위험 + OVERLY_BROAD_CATCH) | **LLM/프론티어 triage**, 체커별 가이드 | ⬜ **미착수(브리프 §6)** |
전체 28체커의 트랙 배정·건수·심각도 = `references/checkers/_BACKLOG.md`.

## 3. 지금까지 완료 (커밋됨)
- **SparrowXlsExport** (xls→항목md, NPOI, Excel/COM 불사용): `tools/SparrowXlsExport/`. 반입 = `dotnet-gcdump-offline` 번들
  (`Install-SparrowXls.ps1`→`C:\tools\SparrowXlsExport`, `Create-SparrowItems.ps1`). 출력: `items/{ID}_{체커키}_{파일}_{라인}.md`
  + `index.csv`(BOM) + `checkers.md`(체커 워크리스트). **26체크 fixture**(validate `-IncludeSparrowE2E`). 실물 7,170행 검증.
- **Track A**: `references/{Run-TrackA.ps1, bucket1-autofix.editorconfig, track-a-autofix.md}`. dotnet format으로 IDE0007/8(var)·
  IDE0048(괄호)·IDE0017(이니셜라이저) 규칙별 적용+커밋. 콘솔=요약/로그=전체진단(실행지점). net472 레거시 더미 실증.
- **SparrowCommentFix** (Track B, 자작 Roslyn, 주석 trivia만): `tools/SparrowCommentFix/`. **활성 2종(`space`/`period`)**
  결정론 픽스 — 프로젝트 로드 없음, 문자열 속 `//` 무손상 보장, BOM/개행 보존, 원자적 재기록, 규칙당 1회 실행=체커별 커밋.
  **실물 대조(6827/6855.xls)로 스코프 축소**: `capitalize`·`blankline`은 부적합 판정 → **도구에서 제거**
  (capitalize=한글/기호 시작이 다수라 대문자화 결정론 불가+주석처리 코드 오변형 위험; blankline=실물은 트레일링/인라인 주석
  지적이라 반대 타깃·구조 재작성 위험 대비 실이익 ~10건), `asterisk`는 **보류**(Doxygen 별표블록 제거=스타일 판단). 이 3종은
  `--rules`에 주면 exit 2(사유 안내). **실물 per-rule ≈ space 0 / period 221 / capitalize 130(한글·기호 다수) /
  blankline 10(트레일링) / asterisk 45(Doxygen)**, 전체 주석 히트의 **~79%는 자동생성/백업 파일**(`obj\`·`*.g.cs`·
  `*.Designer.cs`·`AssemblyInfo`·`복사본`)이라 **Sparrow 스캔 시점에 운영자가 제외**(도구 역할 아님). fixture
  (validate `-IncludeCommentE2E`). 반입 = `dotnet-gcdump-offline` 번들(SparrowXlsExport와 동일 패턴).

## 4. 핵심 결정·제약·함정 (재도출 금지)
- **Excel/COM 금지** → xls는 NPOI로 직접 파싱(SparrowXlsExport). xls→xlsx 변환기는 순손해(같은 파싱+변질지점 추가)라 안 함.
- **레거시 실행 요령**: (1) `.csproj` 아니라 **`.sln`을 대상**으로(안 그러면 참조 프로젝트 전부 skip). (2) **먼저 솔루션 빌드**
  (참조 DLL 생성 → "메타데이터 참조 없음" 반쪽로드 해소). (3) 안 되면 **VS "코드 정리 / Fix All in Solution"**(같은 Roslyn 픽스).
- **dotnet format은 semantic** → `Foo c=null;`·`IFoo c=new Foo();`처럼 **타입 추론 불가/타입 변경 위험은 자동수정 안 함**(안전).
  그래서 **Sparrow가 잡아도 Roslyn이 안 고치는 잔여 존재** → 재분석 후 남는 var류는 대개 이런 케이스 = **수동/LLM(Track C)**.
- **자작 Roslyn은 Track B(주석)만**. Track A(var 등)는 semantic이라 **재구현 금지**(기성 dotnet format 사용 = ".gcdump 파서 자작 금지"와 같은 원칙).
- **커밋 단위 = 규칙/체커별**(7,000 커밋 아님). fix는 **OSTES의 fix 브랜치**에서 → 검토 → main 병합.
- **PS 5.1**: 한글 .ps1은 **UTF-8 BOM 필수**. native(git/dotnet) stderr + `2>&1` + `EAP=Stop` = throw(autocrlf 경고) → 루프는 `EAP=Continue`.

## 5. 남은 작업 브리프 — Track B (SparrowCommentFix, 자작 Roslyn)
**목적**: dotnet format이 **주석 *내용*을 안 건드림** → 주석 규칙을 결정론으로 소거. 대상 체커(_BACKLOG의 B):
`MISSING_SPACE_AFTER_DELIMITER`(`//x`→`// x`, **완료=space**)·`FORMATTING.COMMENT.MISSING_PERIOD`(마침표, **완료=period**)·
`LOWERCASE_FIRST_LETTER`(첫글자 대문자, **제거=capitalize**)·`MISSING_BLANK_LINE_BEFORE_COMMENT`(**제거=blankline**)·
`BLOCK_OF_ASTERISK`(**보류=asterisk**). 여백(`CONTINUATION.BAD_INDENTATION` 등)은 `dotnet format whitespace`로.
> **구현 상태**: 실물 대조 후 **활성 2종(space/period)** 확정·fixture 게이트 통과. capitalize/blankline은 실물 부적합으로
> **도구에서 제거**(capitalize=한글/기호 대문자화 결정론 불가+주석처리 코드 오변형, blankline=실물은 트레일링 주석이라
> 반대 타깃), asterisk는 **보류**(Doxygen 블록=스타일 판단). 3종 모두 `--rules` 지정 시 exit 2. 클린 룰 레지스트리라
> 올바른 계약이 정의되면 각각 작은 diff로 재추가 가능.
**설계(dev-delegate로 구현)**:
- `tools/SparrowCommentFix/` net8 콘솔. **`Microsoft.CodeAnalysis.CSharp`(Roslyn)** 로 `CSharpSyntaxTree.ParseText(파일)` →
  **주석 trivia만** 수정 → 원자적 재기록. **프로젝트 로드 없음 → 레거시 무관**. 정규식 아님(문자열 속 `//` 오탐 방지 = 코드 무손상 보장).
- CLI: `SparrowCommentFix <files 또는 --files-from index.csv> --rules <space,period|all> [--dry-run]` (활성 2종; all=space+period).
  스코프 = SparrowXlsExport `index.csv`의 체커별 파일목록(=검출된 파일만, churn 최소).
- 안전: 주석은 런타임/안전 영향 0 → 자동 OK. 첫글자 대문자·마침표는 "글자/문장부호 없을 때만" 가드.
- **fixture 게이트**(SparrowXlsExport 패턴): 합성 .cs로 각 규칙 before/after + 멱등성 + 문자열 속 `//` 무손상 검증. validate에 `-IncludeCommentE2E` opt-in.
- 반입: `dotnet-gcdump-offline` 번들에 exe 동봉(SparrowXlsExport와 동일 패턴).
- **원콜 러너**: `tools/SparrowCommentFix/Run-SparrowCommentFix.ps1` 존재(Run-SparrowSyntaxFix 대응, **커밋 없음**).
  폴더/.sln/.csproj를 주면 러너가 `.cs` 재귀 수집 + **생성/백업 제외**(`\obj\`·`\bin\`·`*.g.cs`·`*.Designer.cs`·
  `AssemblyInfo.cs`·`복사본` 등) 후 임시 `--files-from` CSV로 툴에 넘겨 space+period 1회 실행(`-DryRun`/`-FilesFrom`/`-ExePath`).
- **커밋은 peace-skillbank에** (OSTES 아님). SparrowXlsExport 커밋 메시지 참고.

## 6. 남은 작업 브리프 — Track C (체커별 가이드 + LLM triage)
**목적**: 보안·품질 체커(~370, _BACKLOG의 C)를 LLM/프론티어가 **판단**해 처리. **체커별 가이드 md**가 그 근거.
**구축 순서**:
1. `references/checkers/<체커키>.md` 생성 — `_TEMPLATE.md` 형식. **크리티컬(매우위험/높음/위험) 먼저**, **검출된 체커만**(lazy).
   결정론 부분(체커키·건수·심각도·Sparrow 설명)은 `checkers.md`/`index.csv`에서 채우고, 판단 부분(CWE매핑·진성판별·위양성·수정패턴)은 작성.
2. **표준 매핑**: 판정 기준 룰셋 = **"무기체계 소프트웨어 보안약점 점검 목록"(187, 100% 적용)**. 이 문서가 있으면 무기체계 항목번호까지,
   없으면 **CWE 기준**(FORWARD_NULL→CWE-476, RESOURCE_LEAK→CWE-772, TOCTOU→CWE-367, EMPTY_CATCH→CWE-390 등). → **사용자에게 187 문서 유무 확인**.
3. **triage 계약(스킬 본체 or 워크플로)**: 항목 md + 체커 가이드(사전조회) → LLM 판단 → {진성수정+근거 / 위양성 사유서 / 보류}. 수정은 **G0~G3 게이트** 후 체커별 커밋.
4. 약한 로컬 모델이면 항목 md를 **frontier-handoff**로 상위 모델에 이관.

## 7. 파일 위치
- 스킬 루트: `skills/sparrow-static-analysis/`  (SKILL.md 없음 = 자동 트리거 스킬 아님, 참조 자산)
- 도구: `tools/SparrowXlsExport/`(완료), `tools/SparrowCommentFix/`(신설 예정)
- Track A: `references/{Run-TrackA.ps1, bucket1-autofix.editorconfig, track-a-autofix.md}`
- Track C: `references/checkers/{_BACKLOG.md, _TEMPLATE.md, <체커키>.md(생성 예정)}`
- 반입 번들: 별도 레포 `github.com/Peace-Min/dotnet-gcdump-offline`
- 메모리: `[[project-sparrow-static-analysis]]`, `[[reference-diagsession-netfx-capture]]`(같은 폐쇄망 반입 패턴)

## 8. 미결 질문 (착수 전 사용자 확인)
- **무기체계 187 항목 문서** 있나? (표준매핑 정밀도 결정 — 없으면 CWE로 진행)
- **Track B "처리" 정의**: 반드시 *코드 수정*인가, *위양성/예외 상태(사유서)* 도 인정되나? (스타일은 진성이라 대개 수정)
- **G2용 Sparrow CLI 재분석** 가능한가? (되면 항목당 즉시 게이트, GUI만이면 배치 라운드)
