---
name: addsim-xml-report
description: Clone-time Claude Code entrypoint for AddSIM (Korean defense M&S) XML analysis. Runs the bundled deterministic PowerShell analyzer on BSM/Player/Component XML definition files and produces a fixed-format, self-contained HTML report with depth-tagged hierarchy, attribute tables, connection tables, verification stats, and a clearly-badged model-written interpretation as the final section. Requires Windows PowerShell 5.1+.
when_to_use: Use when the user asks to analyze AddSIM-related XML (BSM, 기본체계모델, 플레이어, 컴포넌트, 무기체계 모델 정의) or wants such files turned into a readable HTML report. Korean triggers - AddSIM xml 분석, BSM 분석, 플레이어 xml 정리, 컴포넌트 xml 구조, 뎁쓰별 분석, html 보고서. For XML unrelated to AddSIM use xml-report instead.
---

# AddSIM XML Report Entrypoint

This is the Claude Code project-skill entrypoint that makes `/addsim-xml-report` available
immediately after cloning this repository and starting Claude Code from the repo root.

Before acting, read and follow the canonical skill contract at:

```text
skills/addsim-xml-report/SKILL.md
```

Use the bundled analyzer from:

```text
skills/addsim-xml-report/scripts/Analyze-AddsimXml.ps1
```

Treat any user arguments passed to `/addsim-xml-report` as the XML file/folder path. Never analyze
the XML by hand: run the script (pass 1), write the interpretation summary from the generated
`*.data.json` digest only, then re-run with `-SummaryFile` (pass 2). Surface unmapped element
names to the user for `config/mapping.json` calibration. Never edit the generated HTML directly.
