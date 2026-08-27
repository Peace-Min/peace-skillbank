---
name: xml-report
description: Clone-time Claude Code entrypoint for schema-agnostic XML structure analysis. Runs the bundled deterministic PowerShell analyzer on any XML file/folder and produces a fixed-format, self-contained HTML report with depth-tagged hierarchy tree, per-depth summaries, attribute tables, connection tables, verification stats, and a clearly-badged model-written interpretation as the final section. Requires Windows PowerShell 5.1+.
when_to_use: Use when the user asks to analyze the structure of any XML file, summarize what an XML contains, organize it by depth/hierarchy, or turn XML into a human-readable HTML report. Korean triggers - xml 분석, xml 구조 뽑아줘, 계층 정리, 뎁쓰별 분석, xml을 html 보고서로. If the XML is AddSIM-related (BSM/Player/Component), prefer addsim-xml-report.
---

# XML Report Entrypoint

This is the Claude Code project-skill entrypoint that makes `/xml-report` available immediately
after cloning this repository and starting Claude Code from the repo root.

Before acting, read and follow the canonical skill contract at:

```text
skills/xml-report/SKILL.md
```

Use the bundled analyzer from:

```text
skills/xml-report/scripts/Analyze-Xml.ps1
```

Treat any user arguments passed to `/xml-report` as the XML file/folder path. Never analyze the
XML by hand: run the script (pass 1), write the interpretation summary from the generated
`*.data.json` digest only, then re-run with `-SummaryFile` (pass 2). For recurring domains,
offer a domain mapping file (labels/docTypes/connections/brand) via `-MappingPath`. Never edit
the generated HTML directly.
