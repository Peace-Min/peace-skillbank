---
description: Analyze AddSIM (BSM/Player/Component) XML into a fixed-format self-contained HTML report.
argument-hint: "<xml-file-or-folder> [extra context, e.g. what to focus on]"
---

Use the `addsim-xml-report` skill to analyze the following input:

```text
$ARGUMENTS
```

Treat this command as a terse entry point:

1. Parse the arguments for an XML file/folder path plus any context. If no usable path is
   present, ask for it.
2. Follow the skill contract (`skills/addsim-xml-report/SKILL.md`): run
   `scripts/Analyze-AddsimXml.ps1` (pass 1), write the interpretation summary from the
   generated `*.data.json` digest only, then re-run with `-SummaryFile` (pass 2). NEVER
   analyze the XML structure by hand and never edit the generated HTML directly.
3. Report back: report path, verification stats (element count / max depth / count match),
   and any unmapped element names for `config/mapping.json` calibration.
4. Do not edit source code or the original XML in this command.

If both this command and the namespaced plugin skill are available, this command is only a short
alias for the skill.
