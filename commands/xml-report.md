---
description: Analyze any XML into a fixed-format self-contained HTML structure report (depth tree, tables, stats).
argument-hint: "<xml-file-or-folder> [extra context, e.g. what to focus on]"
---

Use the `xml-report` skill to analyze the following input:

```text
$ARGUMENTS
```

Treat this command as a terse entry point:

1. Parse the arguments for an XML file/folder path plus any context. If no usable path is
   present, ask for it.
2. Follow the skill contract (`skills/xml-report/SKILL.md`): run `scripts/Analyze-Xml.ps1`
   (pass 1), write the interpretation summary from the generated `*.data.json` digest only,
   then re-run with `-SummaryFile` (pass 2). NEVER analyze the XML structure by hand and never
   edit the generated HTML directly.
3. Report back: report path, verification stats (element count / max depth / count match),
   and any unmapped element names. For recurring domains, offer a domain mapping file via
   `-MappingPath`.
4. Do not edit source code or the original XML in this command. If the XML is AddSIM-related
   (BSM/Player/Component), prefer `/addsim-xml-report`.

If both this command and the namespaced plugin skill are available, this command is only a short
alias for the skill.
