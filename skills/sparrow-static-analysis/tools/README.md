# Sparrow Helper tools

일반 사용자는 이 폴더에서 아래 파일만 실행하면 됩니다.

```text
Run-SparrowRunnerGui.cmd
```

## 무엇을 써야 하나요?

- `Run-SparrowRunnerGui.cmd`: Track A/B/C를 한 화면에서 실행하는 권장 진입점입니다.
- `Run-SparrowAll.cmd`: GUI 없이 Track A/B만 순차 실행해야 할 때 쓰는 보조 진입점입니다.
- `SparrowRunner.Gui/`: 통합 GUI 프로젝트입니다.
- `_internal/`: GUI와 러너가 내부적으로 호출하는 엔진 프로젝트입니다. 일반 사용자가 직접 실행할 필요가 없습니다.

## 규칙별 커밋 전 컴파일 게이트 (`-VerifyCmd`, 한 줄)

`-Commit`으로 규칙별 자동 커밋을 돌릴 때, `-VerifyCmd '<빌드 명령>'`을 함께 주면 **각 규칙 edits 후·커밋 전**에 그
명령을 실행한다. 명령이 비정상 종료(exit≠0)하면 그 규칙의 미커밋 `*.cs` edits를 `git checkout -- *.cs`로 되돌리고
커밋을 건너뛴 뒤(`[GATE] rule <r> reverted` 로그) 다음 규칙으로 넘어간다 — **게이트를 통과한 규칙만 커밋**된다.
레거시 비-SDK x64 대상이라 규칙마다 전체 msbuild는 느리므로, 게이트는 선택(opt-in)이며 안 주면 예전과 동일하게
동작하되 `-Commit`일 때 "빌드 게이트 없음 — 커밋 후 반드시 전체 빌드로 확인" 안내가 1줄 출력된다.

```powershell
# 원큐(A→B) 모두에 게이트 적용
.\Run-SparrowAll.ps1 -Solution C:\Work\OSTES\OSTES.sln -Commit -VerifyCmd '"C:\...\msbuild.exe" C:\Work\OSTES\OSTES.sln /t:Build'
# 개별 러너에도 동일한 -VerifyCmd 지원
.\_internal\SparrowSyntaxFix\Run-SparrowSyntaxFix.ps1 -Solution ...\OSTES.sln -Commit -VerifyCmd '<빌드 명령>'
```

## 내부 구성

- `_internal/SparrowSyntaxFix`: Track A 코드 규칙 자동수정 엔진.
- `_internal/SparrowCommentFix`: Track B 주석/레이아웃 자동수정 엔진.
- `_internal/SparrowXlsExport`: Track C XLS 파서 CLI와 테스트용 도구.
- `_internal/SparrowXlsExport.Core`: Track C requests 생성 공용 라이브러리.

## 폐쇄망 반입(오프라인 배포)

폐쇄망(인터넷/`.NET SDK` 없는 PC)에서 쓰려면 `Run-SparrowRunnerGui.cmd` 하나만 복사해서는 안 됩니다.
GUI/러너는 컴파일된 도구 exe와 `references/`가 있어야 동작합니다. 올바른 최소 반입 단위는 다음과 같습니다.

1. 인터넷 + `.NET SDK`가 있는 PC에서 `tools\publish-airgap.ps1`을 한 번 실행해 도구 4종을 `publish\`로 발행합니다.
2. **`skills\sparrow-static-analysis` 폴더 트리 전체**(발행된 `publish\` 산출물 + `references\` 포함)를 폐쇄망 PC로 복사합니다.
3. 폐쇄망 PC에서 `Run-SparrowRunnerGui.cmd`를 실행하면 `SparrowRunner.Gui\publish\SparrowRunner.Gui.exe`를
   자동으로 사용하고, 러너는 `publish\SparrowSyntaxFix.exe` / `publish\SparrowCommentFix.exe`를 자동으로 집어 씁니다
   (`dotnet build`/NuGet 복원 불필요).

기본 발행은 self-contained라 대상 PC에 `.NET` 런타임이 필요 없습니다. 자세한 절차는
`docs/sparrow-static-analysis-usage.md`의 "폐쇄망 반입(오프라인 배포)" 절을 참고하세요.
