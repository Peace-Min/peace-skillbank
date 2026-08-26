# dmp-triage 사용 가이드

Windows 프로세스 덤프(`.dmp` — 작업관리자/procdump 캡처)를 **폐쇄망에서, 설치 없이** 분석해
LLM이 바로 읽을 수 있는 `report.md`로 압축하는 스킬.

핵심 원칙: **LLM에게 덤프 원본을 절대 주지 않는다.** 결정적 도구(cdb + CLI)가 수십 KB
리포트를 만들고, LLM은 그 텍스트만 해석한다. (실측: 21.9GB 덤프를 LLM이 직접 바이트 파싱
→ 5시간 소요 후 오판. 같은 덤프를 이 파이프라인으로 → 수 분.)

## 빠른 시작

```powershell
$skillDir = "C:\path\to\peace-skillbank\skills\dmp-triage"

# 1) 1초 사전판정 (cdb 없어도 동작): 표준 여부/행vs크래시/스레드/컨텍스트/모듈
powershell -NoProfile -ExecutionPolicy Bypass -File "$skillDir\scripts\dmp-triage.ps1" check -Dump C:\dumps\app.dmp

# 2) 본 분석 → report.md
powershell -NoProfile -ExecutionPolicy Bypass -File "$skillDir\scripts\dmp-triage.ps1" analyze -Dump C:\dumps\app.dmp
```

Claude Code에서는 `/peace-skillbank:dmp-triage C:\dumps\app.dmp` (plugin 설치 시,
namespaced) 또는 `commands/dmp-triage.md`를 `.claude/commands/`로 복사한 개인 command로 호출한다.

전체 옵션: `analyze -Dump <dmp> [-OutDir <폴더>] [-Symbols <로컬 심볼>] [-SupportFiles <원본머신 파일>]
[-CdbPath <cdb.exe>] [-Deep] [-NativeOnly] [-ManagedOnly] [-TimeoutSec <초, 패스당 기본 3600>]`
종료 코드: `0` 정상 / `1` 부분 성공(비표준 덤프, cdb 부재, 패스 실패·타임아웃) / `2` 치명 오류.

## 3단계 파이프라인

1. **사전 판정** (순수 PowerShell, 의존성 0) — minidump 헤더/스트림/스레드/모듈 테이블 직접
   파싱. 표준 여부(버전 하위워드 `0xA793`), 행 vs 크래시(ExceptionStream 유무), 원본 OS 빌드,
   스레드 수와 레지스터 컨텍스트 저장 여부, 메인 모듈, 캡처 메모리 총량.
2. **네이티브 트랙** (cdb) — `!analyze -v -hang`(크래시면 자동으로 `-v` + `.ecxr`),
   `!runaway`, `!uniqstack`(동일 스택 압축), `!locks`, `lm`.
3. **관리코드 트랙** (cdb + SOS) — `!threads`, `!syncblk`, `~*e !clrstack` 후 동일 스택
   자동 그룹핑. **.NET 관리 스택은 PDB 없이도** 덤프 안의 어셈블리 메타데이터로 메서드
   이름까지 전부 나온다 (WPF/WinForms 앱 행 분석의 핵심 경로).

## 출력물 (전부 커밋 금지 — gitignore 처리됨)

| 파일 | 용도 |
|---|---|
| `report.md` | LLM 입력. 이 파일 하나만 전달한다 |
| `modules.csv` | 모듈 인벤토리 (베이스/크기/타임스탬프/경로) |
| `raw\native.log`, `raw\managed.log` | cdb 원시 출력. `===SECTION:x===` 마커로 구분 — LLM이 특정 섹션을 요구할 때만 발췌 제공 |

## cdb 확보와 폐쇄망 반입

cdb 해석 순서: 스크립트 옆/스킬 루트의 `bin\debuggers\` → 설치된 Windows SDK Debuggers →
PATH → WinDbg 스토어 앱.

1. 인터넷 PC에서 1회: `tools\get-debuggers.ps1` (winget으로 WinDbg 설치 후 cdb 일체
   ~135MB를 `bin\debuggers\`에 스테이징)
2. `dmp-triage.ps1 package` → USB 반입용 zip (~57MB) 생성
3. 폐쇄망 PC: 압축 해제 → `analyze`. 설치·관리자 권한·네트워크 불필요
   (`-netsyms:no`로 심볼 서버 접근 원천 차단)

상세 절차와 문제해결(DAC 불일치, 네이티브 PDB 한계, .NET Core SOS)은
`skills/dmp-triage/references/air-gap-deployment.md` 참고.

## 폐쇄망 LLM 프롬프트

`skills/dmp-triage/references/model-agnostic-prompt.md`에 2종:

- **A. 에이전트형** (명령 실행 가능한 LLM): CLI 실행부터 결론 보고까지. 직접 파싱 금지
  철칙과 report.md 해석 가이드 포함.
- **B. 채팅형** (사람이 CLI를 돌리고 report.md만 붙여넣기): 해석 규칙 + 보고 형식.

## 자주 겪는 문제

- **DAC/SOS mismatch 경고**: 원본 머신의 `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\`
  에서 `mscordacwks.dll`, `sos.dll`, `clr.dll`을 한 폴더에 모아 `-SupportFiles <폴더>` 재실행.
- **앱 네이티브 코드 함수명 없음**: 빌드 일치 PDB가 필요. 원본 머신 exe+PDB를
  `-SupportFiles`로. OS DLL은 export 심볼로 `ntdll!NtWaitForSingleObject` 수준까지 나옴.
- **`!locks` 실패 / `!analyze` WRONG_SYMBOLS**: OS PDB 부재 시 정상. 리포트에 자동 노트가
  붙고, 진짜 신호는 섹션 5(고유 네이티브 스택)와 7(관리 스택)이다.

## 검증

```powershell
$tokens=$null; $errors=$null
[System.Management.Automation.Language.Parser]::ParseFile(
  "skills\dmp-triage\scripts\dmp-triage.ps1", [ref]$tokens, [ref]$errors)
$errors
```

end-to-end 검증은 실제 `.dmp` fixture로 `check` → `analyze` → `report.md` 생성까지 확인한다
(예: `skills/diagsession-memory-analysis/tools/_leaksample/after.dmp`).
