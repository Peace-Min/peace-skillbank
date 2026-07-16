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

## 내부 구성

- `_internal/SparrowSyntaxFix`: Track A 코드 규칙 자동수정 엔진.
- `_internal/SparrowCommentFix`: Track B 주석/레이아웃 자동수정 엔진.
- `_internal/SparrowXlsExport`: Track C XLS 파서 CLI와 테스트용 도구.
- `_internal/SparrowXlsExport.Core`: Track C requests 생성 공용 라이브러리.

폐쇄망에서 GUI로 사용할 때는 `Run-SparrowRunnerGui.cmd`만 복사/실행한다는 전제로 유지합니다.
