#requires -Version 5.0
<#
 dmp-triage : master CLI for offline Windows process dump (.dmp) analysis
 ---------------------------------------------------------------------------
 Designed for air-gapped machines. Two engines:
   1) Pure-PowerShell pre-triage : parses the minidump header, stream
      directory, threads, modules and memory tables directly. Zero
      dependencies. Answers instantly: standard-or-not, hang-or-crash,
      contexts present, OS build, thread/module inventory.
   2) cdb engine (Debugging Tools for Windows, xcopy-portable) : full
      native analysis (!analyze -hang, !uniqstack, !locks) plus managed
      .NET analysis via SOS (!threads, !syncblk, ~*e !clrstack).
 Output: a compact report.md an LLM can read, plus raw logs for deep dives.

 USAGE
   .\dmp-triage.ps1 check   [-Dump <file>]
   .\dmp-triage.ps1 analyze -Dump <file> [-OutDir <dir>] [-Symbols <dir>]
                            [-SupportFiles <dir>] [-CdbPath <cdb.exe>]
                            [-Deep] [-NativeOnly] [-ManagedOnly]
                            [-TimeoutSec <n, default 3600 per pass>]
   .\dmp-triage.ps1 package [-OutZip <zip>]

 EXIT CODES: 0 full success | 1 completed but degraded (non-standard dump,
             cdb missing, pass failed/timed out) | 2 fatal error
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('analyze', 'check', 'package', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$DumpPositional,

    [string]$Dump,
    [string]$OutDir,
    [string]$Symbols,       # local symbol store / pdb folder (never network)
    [string]$SupportFiles,  # folder with source-machine exe/pdb/mscordacwks
    [string]$CdbPath,
    [switch]$Deep,
    [switch]$NativeOnly,
    [switch]$ManagedOnly,
    [int]$TimeoutSec = 3600,
    [string]$OutZip
)

$ErrorActionPreference = 'Stop'
$script:ToolVersion = '0.4.0'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Dump -and $DumpPositional) { $Dump = $DumpPositional }

function Write-Info([string]$m) { Write-Host "[dmp-triage] $m" }
function Write-Warn([string]$m) { Write-Host "[dmp-triage] WARNING: $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------- cdb lookup
function Find-Cdb {
    param([string]$Override)
    if ($Override) {
        if (Test-Path -LiteralPath $Override -PathType Leaf) { return (Resolve-Path -LiteralPath $Override).Path }
        Write-Warn "-CdbPath '$Override' not found (or not a file) - falling back to auto-detection"
    }
    # Environment contract (like JAVA_HOME/DOTNET_ROOT, and cdb's own _NT_* vars):
    # DMP_TRIAGE_CDB pins one exe; DMP_TRIAGE_HOME points at an install root.
    # Both are validated, so a stale value falls through to the path search below
    # instead of failing the run.
    if ($env:DMP_TRIAGE_CDB -and (Test-Path -LiteralPath $env:DMP_TRIAGE_CDB -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $env:DMP_TRIAGE_CDB).Path
    }
    if ($env:DMP_TRIAGE_HOME) {
        foreach ($rel in @('bin\debuggers\cdb.exe', 'bin\debuggers\x64\cdb.exe')) {
            $c = Join-Path $env:DMP_TRIAGE_HOME $rel
            if (Test-Path -LiteralPath $c -PathType Leaf) { return (Resolve-Path -LiteralPath $c).Path }
        }
    }
    $candidates = @()
    $parentDir = Split-Path -Parent $script:Root
    # The debuggers are staged into ONE skill folder, but this CLI legitimately
    # exists in more than one place (personal skill + plugin cache). Look next to
    # this script first, then at the canonical install location, so a plugin-cache
    # copy still finds a staging done by the offline installer.
    $canonical = Join-Path $env:USERPROFILE '.claude\skills\dmp-triage\bin\debuggers'
    $candidates += @(
        (Join-Path $script:Root 'bin\debuggers\cdb.exe'),
        (Join-Path $script:Root 'bin\debuggers\x64\cdb.exe'),
        (Join-Path $parentDir 'bin\debuggers\cdb.exe'),
        (Join-Path $parentDir 'bin\debuggers\x64\cdb.exe'),
        (Join-Path $canonical 'cdb.exe'),
        (Join-Path $canonical 'x64\cdb.exe'),
        'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe',
        'C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe',
        'C:\Program Files (x86)\Windows Kits\8.1\Debuggers\x64\cdb.exe'
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c -PathType Leaf)) { return (Resolve-Path $c).Path } }
    $cmd = Get-Command cdb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # WinDbg store app ships cdb.exe under WindowsApps
    try {
        $pkg = Get-AppxPackage -Name Microsoft.WinDbg -ErrorAction SilentlyContinue
        if ($pkg) {
            $hit = Get-ChildItem -Path $pkg.InstallLocation -Filter cdb.exe -Recurse -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -match 'amd64' } | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    } catch { }
    return $null
}

# ------------------------------------------------------ pure-PS pre-triage
$script:StreamNames = @{
    0 = 'UnusedStream';            3 = 'ThreadListStream';       4 = 'ModuleListStream'
    5 = 'MemoryListStream';        6 = 'ExceptionStream';        7 = 'SystemInfoStream'
    8 = 'ThreadExListStream';      9 = 'Memory64ListStream';    10 = 'CommentStreamA'
    11 = 'CommentStreamW';        12 = 'HandleDataStream';      13 = 'FunctionTableStream'
    14 = 'UnloadedModuleListStream'; 15 = 'MiscInfoStream';     16 = 'MemoryInfoListStream'
    17 = 'ThreadInfoListStream';  18 = 'HandleOperationListStream'; 19 = 'TokenStream'
    20 = 'JavaScriptDataStream';  21 = 'SystemMemoryInfoStream'; 22 = 'ProcessVmCountersStream'
    23 = 'IptTraceStream';        24 = 'ThreadNamesStream'
}
$script:ArchNames = @{ 0 = 'x86'; 5 = 'ARM'; 6 = 'IA64'; 9 = 'x64'; 12 = 'ARM64' }
$script:TypeFlagNames = @{
    0x1 = 'WithDataSegs'; 0x2 = 'WithFullMemory'; 0x4 = 'WithHandleData'; 0x8 = 'FilterMemory'
    0x10 = 'ScanMemory'; 0x20 = 'WithUnloadedModules'; 0x40 = 'WithIndirectlyReferencedMemory'
    0x80 = 'FilterModulePaths'; 0x100 = 'WithProcessThreadData'; 0x200 = 'WithPrivateReadWriteMemory'
    0x400 = 'WithoutOptionalData'; 0x800 = 'WithFullMemoryInfo'; 0x1000 = 'WithThreadInfo'
    0x2000 = 'WithCodeSegs'; 0x4000 = 'WithoutAuxiliaryState'; 0x8000 = 'WithFullAuxiliaryState'
    0x10000 = 'WithPrivateWriteCopyMemory'; 0x20000 = 'IgnoreInaccessibleMemory'
    0x40000 = 'WithTokenInformation'; 0x80000 = 'WithModuleHeaders'; 0x100000 = 'FilterTriage'
    0x200000 = 'WithAvxXStateContext'; 0x400000 = 'WithIptTrace'
}

function Format-PeTimestamp([uint32]$ts) {
    if ($ts -eq 0) { return 'none' }
    try {
        $d = [DateTimeOffset]::FromUnixTimeSeconds($ts).UtcDateTime.ToString('yyyy-MM-dd')
        return ('0x{0:X8} ({1} UTC, or a reproducible-build hash)' -f $ts, $d)
    } catch { return ('0x{0:X8}' -f $ts) }
}

function Read-MinidumpString([System.IO.BinaryReader]$br, [long]$rva) {
    $br.BaseStream.Seek($rva, 'Begin') | Out-Null
    $len = $br.ReadUInt32()
    if ($len -gt 4096) { return '<bad string>' }
    return [System.Text.Encoding]::Unicode.GetString($br.ReadBytes([int]$len))
}

function Read-MinidumpPreTriage {
    param([string]$Path, [string]$ModuleCsvPath)

    $r = [ordered]@{
        Ok = $false; Lines = @(); FileSizeText = ''; IsStandard = $false
        Kind = 'unknown'; HasClrHints = $false; ThreadCount = 0
        FirstModule = ''; Notes = @()
    }
    $fi = Get-Item -LiteralPath $Path
    if ($fi.Length -ge 1GB) { $r.FileSizeText = '{0} GB' -f [math]::Round($fi.Length / 1GB, 2) }
    else { $r.FileSizeText = '{0} MB' -f [math]::Round($fi.Length / 1MB, 2) }
    $L = New-Object System.Collections.Generic.List[string]

    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
          [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        try {

        # -- MINIDUMP_HEADER
        $sig = $br.ReadUInt32(); $ver = $br.ReadUInt32(); $nStreams = $br.ReadUInt32()
        $dirRva = $br.ReadUInt32(); $null = $br.ReadUInt32(); $dumpTs = $br.ReadUInt32()
        $flags = $br.ReadUInt64()

        if ($sig -ne 0x504D444D) {
            $L.Add(('Signature      : 0x{0:X8} - NOT a minidump (MDMP signature missing).' -f $sig))
            $r.Lines = $L; return [pscustomobject]$r
        }
        $L.Add('Signature      : MDMP (valid minidump)')
        $lowWord = $ver -band 0xFFFF
        if ($lowWord -eq 0xA793) {
            $r.IsStandard = $true
            $L.Add(('Version        : 0x{0:X8} - STANDARD (low word 0xA793 is the spec value; high word is implementation-defined noise)' -f $ver))
        } else {
            $L.Add(('Version        : 0x{0:X8} - unexpected low word 0x{1:X4} (spec says 0xA793)' -f $ver, $lowWord))
        }
        $L.Add(('File size      : {0}' -f $r.FileSizeText))
        try {
            $L.Add(('Dump captured  : {0} UTC' -f [DateTimeOffset]::FromUnixTimeSeconds($dumpTs).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss')))
        } catch { }
        $setFlags = @()
        foreach ($k in ($script:TypeFlagNames.Keys | Sort-Object)) {
            if ($flags -band [uint64]$k) { $setFlags += $script:TypeFlagNames[$k] }
        }
        $L.Add(('Dump type      : 0x{0:X} [{1}]' -f $flags, ($setFlags -join ', ')))

        # -- stream directory (capped: a corrupt header may claim billions of streams)
        $streams = @{}
        $fs.Seek($dirRva, 'Begin') | Out-Null
        $fileLen = $fs.Length
        $truncated = $false
        $nStreamsSafe = [Math]::Min([int64]$nStreams, 4096)
        for ($i = 0; $i -lt $nStreamsSafe; $i++) {
            $t = $br.ReadUInt32(); $sz = $br.ReadUInt32(); $rva = $br.ReadUInt32()
            if (([int64]$rva + [int64]$sz) -gt $fileLen) { $truncated = $true }
            if ($t -ne 0 -and $t -le 0x7FFFFFFF) { $streams[[int]$t] = @{ Size = $sz; Rva = $rva } }
        }
        if ($nStreams -gt 4096) { $L.Add(('WARNING        : implausible stream count {0} - parsed the first 4096 entries only' -f $nStreams)) }
        if ($truncated) { $L.Add('WARNING        : stream data extends beyond end of file - dump appears TRUNCATED (partial copy?)') }
        $names = foreach ($e in ($streams.Keys | Sort-Object)) {
            $n = $script:StreamNames[[int]$e]; if (-not $n) { $n = "Stream#$e" }; $n
        }
        $L.Add(('Streams        : {0} total, {1} in use: {2}' -f $nStreams, $streams.Count, ($names -join ', ')))

        # -- hang vs crash
        if ($streams.ContainsKey(6)) {
            try {
                $s = $streams[6]; $fs.Seek($s.Rva, 'Begin') | Out-Null
                $excTid = $br.ReadUInt32(); $null = $br.ReadUInt32()
                $excCode = $br.ReadUInt32(); $null = $br.ReadUInt32(); $null = $br.ReadUInt64()
                $excAddr = $br.ReadUInt64()
                $excHex = '{0:X8}' -f $excCode
                if ($excHex -in @('80000003', '80000007')) {
                    # synthetic debugger break-in exception (cdb/procdump-style capture)
                    $r.Kind = 'hang'
                    $L.Add(('Verdict        : MANUAL dump via debugger break-in (synthetic exception 0x{0:X8} on thread {1}) - treated as HANG capture' -f $excCode, $excTid))
                } else {
                    $r.Kind = 'crash'
                    $L.Add(('Verdict        : CRASH dump - exception 0x{0:X8} at 0x{1:X} on thread {2}' -f $excCode, $excAddr, $excTid))
                }
            } catch {
                $L.Add('Verdict        : ExceptionStream present but unreadable (corrupt/truncated)')
            }
        } else {
            $r.Kind = 'hang'
            $L.Add('Verdict        : HANG / MANUAL dump (no ExceptionStream) - captured while alive, e.g. Task Manager')
        }

        # -- SystemInfoStream (7)
        if ($streams.ContainsKey(7)) {
            try {
                $s = $streams[7]; $fs.Seek($s.Rva, 'Begin') | Out-Null
                $arch = $br.ReadUInt16(); $null = $br.ReadUInt16(); $null = $br.ReadUInt16()
                $nCpu = $br.ReadByte(); $null = $br.ReadByte()
                $maj = $br.ReadUInt32(); $min = $br.ReadUInt32(); $build = $br.ReadUInt32()
                $archName = $script:ArchNames[[int]$arch]; if (-not $archName) { $archName = "arch#$arch" }
                $L.Add(('Source OS      : Windows {0}.{1} build {2}, {3}, {4} logical CPUs' -f $maj, $min, $build, $archName, $nCpu))
            } catch { $L.Add('Source OS      : <SystemInfoStream parse failed>') }
        }

        # -- MiscInfoStream (15): PID
        if ($streams.ContainsKey(15)) {
            try {
                $s = $streams[15]; $fs.Seek($s.Rva, 'Begin') | Out-Null
                $null = $br.ReadUInt32(); $f1 = $br.ReadUInt32(); $pid2 = $br.ReadUInt32()
                if ($f1 -band 1) { $L.Add(('Process id     : {0} (0x{0:X})' -f $pid2)) }
            } catch { }
        }

        # -- ThreadListStream (3): count + contexts present?
        if ($streams.ContainsKey(3)) {
            try {
                $s = $streams[3]; $fs.Seek($s.Rva, 'Begin') | Out-Null
                $nThreads = $br.ReadUInt32()
                $withCtx = 0
                $nThreadsSafe = [Math]::Min([int64]$nThreads, 100000)
                for ($i = 0; $i -lt $nThreadsSafe; $i++) {
                    $base = $s.Rva + 4 + ($i * 48)
                    $fs.Seek($base + 40, 'Begin') | Out-Null   # ThreadContext.DataSize
                    $ctxSize = $br.ReadUInt32()
                    if ($ctxSize -gt 0) { $withCtx++ }
                }
                $r.ThreadCount = $nThreads
                $L.Add(('Threads        : {0} - register CONTEXT stored for {1}/{0} threads' -f $nThreads, $withCtx))
                if ($withCtx -eq 0) { $r.Notes += 'No thread contexts: stack walking will rely on stack scanning.' }
            } catch { $L.Add('Threads        : <ThreadListStream parse failed>') }
        }

        # -- ModuleListStream (4)
        if ($streams.ContainsKey(4)) {
            try {
                $s = $streams[4]; $fs.Seek($s.Rva, 'Begin') | Out-Null
                $nMods = $br.ReadUInt32()
                $csv = New-Object System.Collections.Generic.List[string]
                $csv.Add('Index,BaseOfImage,SizeOfImage,TimeDateStamp,TimestampUtc,Name')
                $firstName = ''; $clr = $false
                $maxParse = [Math]::Min([int]$nMods, 2000)
                for ($i = 0; $i -lt $maxParse; $i++) {
                    $base = $s.Rva + 4 + ($i * 108)
                    $fs.Seek($base, 'Begin') | Out-Null
                    $imgBase = $br.ReadUInt64(); $imgSize = $br.ReadUInt32()
                    $null = $br.ReadUInt32(); $ts = $br.ReadUInt32(); $nameRva = $br.ReadUInt32()
                    $name = Read-MinidumpString $br $nameRva
                    if ($i -eq 0) { $firstName = $name }
                    $leaf = ($name -split '\\')[-1].ToLowerInvariant()
                    if ($leaf -in @('clr.dll', 'coreclr.dll', 'mscorwks.dll')) { $clr = $true }
                    $tsUtc = ''
                    try { $tsUtc = [DateTimeOffset]::FromUnixTimeSeconds($ts).UtcDateTime.ToString('yyyy-MM-dd') } catch { }
                    $csv.Add(('{0},0x{1:X},0x{2:X},0x{3:X8},{4},"{5}"' -f $i, $imgBase, $imgSize, $ts, $tsUtc, $name))
                }
                $r.FirstModule = $firstName
                $r.HasClrHints = $clr
                $L.Add(('Modules        : {0} - main image: {1}' -f $nMods, $firstName))
                if ($clr) { $L.Add('Runtime        : .NET CLR loaded -> managed stacks recoverable WITHOUT PDBs (SOS !clrstack)') }
                if ($ModuleCsvPath) {
                    Set-Content -Path $ModuleCsvPath -Value $csv -Encoding UTF8
                    $L.Add(('Module list    : saved to {0}' -f $ModuleCsvPath))
                }
            } catch { $L.Add('Modules        : <ModuleListStream parse failed>') }
        }

        # -- Memory64ListStream (9) / MemoryListStream (5)
        if ($streams.ContainsKey(9)) {
            try {
                $s = $streams[9]; $fs.Seek($s.Rva, 'Begin') | Out-Null
                $nRanges = $br.ReadUInt64(); $baseRva = $br.ReadUInt64()
                $total = [uint64]0
                $maxRanges = [Math]::Min([long]$nRanges, 200000)
                for ($i = 0; $i -lt $maxRanges; $i++) {
                    $null = $br.ReadUInt64(); $sz = $br.ReadUInt64(); $total += $sz
                }
                $L.Add(('Memory64List   : {0} regions, {1} GB captured, payload starts at file offset 0x{2:X} (regions stored back-to-back per spec)' -f $nRanges, [math]::Round($total / 1GB, 2), $baseRva))
            } catch { $L.Add('Memory64List   : <parse failed>') }
        } elseif ($streams.ContainsKey(5)) {
            $L.Add('MemoryList     : 32-bit RVA memory list present (partial-memory dump)')
        }

        $r.Ok = $true
        $r.Lines = @($L)
        return [pscustomobject]$r

        } catch {
            # degenerate input (0-byte, tiny, corrupt header/directory) must not
            # kill the run - report what we know and let cdb have a try
            $L.Add(('PARSE ABORTED  : {0}' -f $_.Exception.Message))
            $L.Add('                 file is truncated, too small, or not a minidump. Continuing - cdb may still read it.')
            $r.Lines = @($L)
            return [pscustomobject]$r
        }
    } finally {
        $fs.Dispose()
    }
}

# --------------------------------------------------------------- cdb runner
function Invoke-CdbPass {
    param(
        [string]$CdbExe, [string]$DumpPath, [string]$ScriptText,
        [string]$ScriptPath, [string]$LogPath, [string]$SymPath,
        [string]$ImgPath, [int]$Timeout
    )
    Set-Content -Path $ScriptPath -Value $ScriptText -Encoding ASCII

    $args = @('-z', ('"{0}"' -f $DumpPath), '-netsyms:no', '-lines')
    if ($SymPath) { $args += @('-y', ('"{0}"' -f $SymPath)) }
    if ($ImgPath) { $args += @('-i', ('"{0}"' -f $ImgPath)) }
    $args += @('-cf', ('"{0}"' -f $ScriptPath))
    $argString = $args -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $CdbExe
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try {
        # decode cdb's OEM-codepage output correctly (Korean paths etc.)
        $psi.StandardOutputEncoding = [Console]::OutputEncoding
        $psi.StandardErrorEncoding = [Console]::OutputEncoding
    } catch { }

    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $p.WaitForExit($Timeout * 1000)) {
        $timedOut = $true
        try { $p.Kill() } catch { }
    }
    $text = $outTask.Result
    $errText = $errTask.Result
    if ($errText) { $text += "`r`n===STDERR===`r`n$errText" }
    if ($timedOut) { $text += "`r`n===DMPTRIAGE:TIMEOUT after $Timeout s===" }
    Set-Content -Path $LogPath -Value $text -Encoding UTF8
    return @{ Text = $text; TimedOut = $timedOut; ExitCode = $(if ($timedOut) { -1 } else { $p.ExitCode }) }
}

function Split-CdbSections([string]$Text) {
    $sections = @{}
    $parts = [regex]::Split($Text, '===SECTION:([A-Za-z0-9_]+)===')
    # parts: [preamble, name1, body1, name2, body2, ...]
    for ($i = 1; $i -lt $parts.Count - 1; $i += 2) {
        $body = ($parts[$i + 1] -split '===DMPTRIAGE:END===')[0]
        $body = ($body -split "\r?\n" | Where-Object { $_ -notmatch '^\d+:\d+> \.echo\s*$' }) -join "`r`n"
        $sections[$parts[$i]] = $body.Trim()
    }
    return $sections
}

function Limit-Lines([string]$Text, [int]$Max) {
    if (-not $Text) { return '' }
    $lines = $Text -split "\r?\n"
    if ($lines.Count -le $Max) { return $Text }
    $kept = $lines[0..($Max - 1)] -join "`r`n"
    return "$kept`r`n... [truncated: $($lines.Count - $Max) more lines in raw log]"
}

# ------------------------------------------------- managed stack grouping
# ------------------------------------------ lock contention (auto-resolved)
# SOS encodes MonitorHeld as 1 (owned) + 2 per waiting thread. So 1 = owned with
# NO waiters (healthy); >= 3 means at least one thread is actually blocked.
function Get-LockContention([string]$SyncBlkText) {
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not $SyncBlkText) { return $rows }
    foreach ($line in ($SyncBlkText -split "\r?\n")) {
        if ($line -match '^\s*(\d+)\s+[0-9a-fA-F]+\s+(\d+)\s+\d+\s+[0-9a-fA-F]+\s+([0-9a-fA-F]+)\s') {
            $held = [int]$Matches[2]
            if ($held -ge 3) {
                $rows.Add(@{
                    Index    = $Matches[1]
                    Held     = $held
                    Waiters  = [int](($held - 1) / 2)
                    OwnerTid = $Matches[3].ToLowerInvariant()
                })
            }
        }
    }
    return $rows
}

# first frame that names real code, skipping SOS bookkeeping frames
function Get-TopManagedFrame($Group) {
    foreach ($f in $Group.Frames) {
        if ($f -notmatch '^\[(GCFrame|HelperMethodFrame|DebuggerU2M|InlinedCallFrame|ContextTransitionFrame)') { return $f }
    }
    foreach ($f in $Group.Frames) {
        if ($f -match '^\[[A-Za-z0-9_]+[^\]]*\]\s+(\S.+)$') { return $Matches[1] }
    }
    return '<no resolvable managed frame>'
}

function Find-GroupForTid($Groups, [string]$Tid) {
    foreach ($g in $Groups) {
        foreach ($t in $g.Value.Tids) { if ($t.ToLowerInvariant() -eq $Tid) { return $g } }
    }
    return $null
}

function Get-ManagedStackGroups([string]$ClrStackText) {
    $threads = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($line in ($ClrStackText -split "\r?\n")) {
        # header style A (SOS): "OS Thread Id: 0x347c (0)"
        if ($line -match '^OS Thread Id:\s*0x([0-9a-f]+)') {
            if ($cur) { $threads.Add($cur) }
            $cur = @{ Tid = $Matches[1]; Frames = New-Object System.Collections.Generic.List[string]; Unwalkable = $false }
            continue
        }
        # header style B (cdb ~*e echo): "   3  Id: 486c.35d8 Suspend: ..."
        if ($line -match '^[\s.#]*\d+\s+Id:\s*[0-9a-f]+\.([0-9a-f]+)\s') {
            if ($cur) { $threads.Add($cur) }
            $cur = @{ Tid = $Matches[1]; Frames = New-Object System.Collections.Generic.List[string]; Unwalkable = $false }
            continue
        }
        if ($null -eq $cur) { continue }
        if ($line -match 'Unable to walk the managed stack') { $cur.Unwalkable = $true; continue }
        if ($line -match '^[0-9a-fA-F`]{8,18}\s+[0-9a-fA-F`]{8,18}\s+(\S.*)$') {
            $cur.Frames.Add($Matches[1].Trim())
        }
    }
    if ($cur) { $threads.Add($cur) }

    $groups = @{}
    foreach ($t in $threads) {
        # Label is set ONLY for our own sentinels - never derived from frame text,
        # because SOS emits literal '<unknown>' call sites that are real frames
        $label = $null
        if ($t.Unwalkable) {
            $key = '<not a managed thread (native-only); see native stacks in section 5>'
            $label = $key
        } elseif ($t.Frames.Count -eq 0) {
            $key = '<no managed frames>'
            $label = $key
        } else {
            $norm = foreach ($f in $t.Frames) { $f -replace '\[([A-Za-z0-9_]+):\s*[0-9a-fA-F`]+\]', '[$1]' }
            $key = 'S|' + ($norm -join '|')
        }
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = @{ Frames = $t.Frames; Tids = New-Object System.Collections.Generic.List[string]; Label = $label }
        }
        $groups[$key].Tids.Add($t.Tid)
    }
    return $groups.GetEnumerator() | Sort-Object { -$_.Value.Tids.Count }
}

# --------------------------------------------------------- analyze command
function Invoke-Analyze {
    if (-not $Dump) { throw 'analyze requires -Dump <file>' }
    if (-not (Test-Path -LiteralPath $Dump -PathType Leaf)) { throw "dump not found (or not a file): $Dump" }
    $Dump = (Resolve-Path -LiteralPath $Dump).Path
    # a trailing backslash inside a quoted arg escapes the closing quote and
    # destroys the cdb command line (silent hang until timeout)
    if ($Symbols) { $Symbols = $Symbols.TrimEnd('\') }
    if ($SupportFiles) { $SupportFiles = $SupportFiles.TrimEnd('\') }
    $dumpName = [System.IO.Path]::GetFileNameWithoutExtension($Dump)

    if (-not $OutDir) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $OutDir = Join-Path (Get-Location).Path ("dmp-triage-out\{0}-{1}" -f $dumpName, $stamp)
    }
    $rawDir = Join-Path $OutDir 'raw'
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Write-Info "output: $OutDir"

    # ---- 1. pre-triage (pure PS, no dependencies)
    Write-Info 'pre-triage: parsing minidump structures...'
    $modCsv = Join-Path $OutDir 'modules.csv'
    $pre = Read-MinidumpPreTriage -Path $Dump -ModuleCsvPath $modCsv
    foreach ($l in $pre.Lines) { Write-Host "    $l" }

    $script:SlimFindings = New-Object System.Collections.Generic.List[string]
    $script:SlimGroups = New-Object System.Collections.Generic.List[string]
    $report = New-Object System.Collections.Generic.List[string]
    $report.Add('# DMP Triage Report')
    $report.Add('')
    $report.Add("- Dump: ``$Dump`` ($($pre.FileSizeText))")
    $report.Add("- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by dmp-triage v$script:ToolVersion")
    $report.Add('')
    $report.Add('## 1. Pre-triage (parsed directly from the dump, no debugger)')
    $report.Add('')
    $report.Add('```')
    foreach ($l in $pre.Lines) { $report.Add($l) }
    $report.Add('```')
    $report.Add('')

    if (-not $pre.Ok -or -not $pre.IsStandard) {
        $report.Add('> NOTE: file did not parse as a standard minidump; cdb may still recognize it. Continuing.')
        $report.Add('')
        $script:RunStatus = 1
    }

    # ---- 2. locate cdb
    $cdb = Find-Cdb -Override $CdbPath
    if (-not $cdb) {
        Write-Warn 'cdb.exe not found - report will contain pre-triage only.'
        $script:RunStatus = 1
        $report.Add('## 2. Debugger passes: SKIPPED (cdb.exe not found)')
        $report.Add('')
        $report.Add('Install/copy Debugging Tools for Windows and re-run. Options:')
        $report.Add(('- Stage the debuggers into: {0}' -f (Join-Path $env:USERPROFILE '.claude\skills\dmp-triage\bin\debuggers')))
        $report.Add('  The offline installer''s setup.cmd does exactly this. Any copy of this CLI')
        $report.Add('  (personal skill or plugin cache) looks there, so one staging serves all.')
        $report.Add('- Or set the DMP_TRIAGE_CDB environment variable to a cdb.exe, or pass -CdbPath.')
        $report.Add('- On an internet-connected machine: `tools\get-debuggers.ps1`.')
        $reportPath = Join-Path $OutDir 'report.md'
        Set-Content -Path $reportPath -Value $report -Encoding UTF8
        Write-Info "report (pre-triage only): $reportPath"
        return
    }
    Write-Info "cdb: $cdb"
    New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

    $symArg = $null
    $symParts = @()
    if ($Symbols) { $symParts += $Symbols }
    if ($SupportFiles) { $symParts += $SupportFiles }
    if ($symParts.Count -gt 0) { $symArg = $symParts -join ';' }
    $imgArg = $null
    if ($SupportFiles) { $imgArg = $SupportFiles }

    # ---- 3. native pass
    $nativeSections = @{}
    if (-not $ManagedOnly) {
        Write-Info 'native pass: !analyze / !uniqstack / !runaway / !locks ...'
        $analyzeCmd = '!analyze -v -hang'
        $crashExtra = ''
        if ($pre.Kind -eq 'crash') {
            $analyzeCmd = '!analyze -v'
            $crashExtra = ".echo ===SECTION:crash_context===`r`n.ecxr`r`nkvn 40`r`n"
        }
        $deepNative = ''
        if ($Deep) {
            $deepNative = ".echo ===SECTION:allstacks===`r`n~*kvn 40`r`n.echo ===SECTION:handles===`r`n!handle 0 1`r`n"
        }
        $nativeScript = @"
.echo ===DMPTRIAGE:BEGIN===
.echo ===SECTION:target===
vertarget
|
.echo ===SECTION:time===
.time
.echo ===SECTION:analyze===
$analyzeCmd
$crashExtra.echo ===SECTION:runaway===
!runaway 7
.echo ===SECTION:uniqstack===
!uniqstack
.echo ===SECTION:locks===
!locks
$deepNative.echo ===SECTION:modules===
lm
.echo ===DMPTRIAGE:END===
q
"@
        try {
            $res = Invoke-CdbPass -CdbExe $cdb -DumpPath $Dump -ScriptText $nativeScript `
                -ScriptPath (Join-Path $rawDir 'native-script.txt') `
                -LogPath (Join-Path $rawDir 'native.log') `
                -SymPath $symArg -ImgPath $imgArg -Timeout $TimeoutSec
            if ($res.TimedOut) { Write-Warn "native pass timed out after $TimeoutSec s (partial log kept)"; $script:RunStatus = 1 }
            $nativeSections = Split-CdbSections $res.Text
        } catch {
            Write-Warn "native pass failed: $($_.Exception.Message) - continuing with what we have"
            $script:RunStatus = 1
        }
    }

    # ---- 4. managed pass
    $managedSections = @{}
    $managedRan = $false
    if (-not $NativeOnly) {
        Write-Info 'managed pass: SOS !threads / !syncblk / ~*e !clrstack ...'
        $deepManaged = ''
        if ($Deep) {
            $deepManaged = ".echo ===SECTION:eeheap===`r`n!eeheap -gc`r`n.echo ===SECTION:dumpheap===`r`n!dumpheap -stat`r`n"
        }
        $managedScript = @"
.echo ===DMPTRIAGE:BEGIN===
.echo ===SECTION:managed_setup===
.cordll -ve -u -l
.loadby sos clr
.loadby sos coreclr
.chain
.echo ===SECTION:threads===
!threads
.echo ===SECTION:syncblk===
!syncblk
.echo ===SECTION:clrstack===
~*e !clrstack
$deepManaged.echo ===DMPTRIAGE:END===
q
"@
        try {
            $res2 = Invoke-CdbPass -CdbExe $cdb -DumpPath $Dump -ScriptText $managedScript `
                -ScriptPath (Join-Path $rawDir 'managed-script.txt') `
                -LogPath (Join-Path $rawDir 'managed.log') `
                -SymPath $symArg -ImgPath $imgArg -Timeout $TimeoutSec
            if ($res2.TimedOut) { Write-Warn "managed pass timed out after $TimeoutSec s (partial log kept)"; $script:RunStatus = 1 }
            $managedSections = Split-CdbSections $res2.Text
            $managedRan = $true
        } catch {
            Write-Warn "managed pass failed: $($_.Exception.Message) - continuing with what we have"
            $script:RunStatus = 1
        }
    }

    # ---- 5. build report
    Write-Info 'building report.md ...'
    if ($ManagedOnly) {
        $report.Add('_Native sections (2-6) skipped due to -ManagedOnly. Run without it for native stacks._')
        $report.Add('')
    } else {
    $report.Add('## 2. Target / capture info (cdb)')
    $report.Add('')
    $report.Add('```')
    $report.Add((Limit-Lines $nativeSections['target'] 30))
    $report.Add((Limit-Lines $nativeSections['time'] 10))
    $report.Add('```')
    $report.Add('')

    $report.Add('## 3. Automated analysis (!analyze)')
    $report.Add('')
    $an = $nativeSections['analyze']
    if ($an -and ($an -match 'WRONG_SYMBOLS')) {
        $report.Add('> NOTE: OS symbols (PDBs) are not available, so !analyze bucketing below is')
        $report.Add('> unreliable noise (WRONG_SYMBOLS). The REAL signal is in sections 5 (native')
        $report.Add('> stacks via export symbols) and 7 (managed stacks, which need no PDBs).')
        $report.Add('')
    }
    if ($an) {
        $anLines = $an -split "\r?\n"
        $keyPat = '^(SYMBOL_NAME|MODULE_NAME|IMAGE_NAME|PROCESS_NAME|FAILURE_BUCKET_ID|FAILURE_ID_HASH|PRIMARY_PROBLEM_CLASS|DEFAULT_BUCKET_ID|ERROR_CODE|EXCEPTION_CODE_STR|EXCEPTION_STR|BLOCKED_THREAD|DERIVED_WAIT_CHAIN|BUGCHECK_STR)'
        $keys = $anLines | Where-Object { $_ -match $keyPat }
        $stackIdx = [array]::IndexOf($anLines, ($anLines | Where-Object { $_ -match '^STACK_TEXT:' } | Select-Object -First 1))
        $stackBlock = @()
        if ($stackIdx -ge 0) {
            for ($i = $stackIdx; $i -lt [Math]::Min($stackIdx + 45, $anLines.Count); $i++) {
                if ($i -gt $stackIdx -and $anLines[$i] -match '^[A-Z_]+:') { break }
                $stackBlock += $anLines[$i]
            }
        }
        $report.Add('Key fields:')
        $report.Add('```')
        foreach ($k in $keys) { $report.Add($k) }
        $report.Add('```')
        if ($stackBlock.Count -gt 0) {
            $report.Add('Faulting/interesting stack (from !analyze):')
            $report.Add('```')
            foreach ($sline in $stackBlock) { $report.Add($sline) }
            $report.Add('```')
        }
        $report.Add('(full !analyze output: raw/native.log)')
    } else {
        $report.Add('_no !analyze output captured_')
    }
    $report.Add('')

    if ($nativeSections.ContainsKey('crash_context')) {
        $report.Add('## 3b. Crash context stack (.ecxr)')
        $report.Add('```')
        $report.Add((Limit-Lines $nativeSections['crash_context'] 60))
        $report.Add('```')
        $report.Add('')
    }

    $report.Add('## 4. CPU time per thread (!runaway)')
    $report.Add('```')
    $report.Add((Limit-Lines $nativeSections['runaway'] 60))
    $report.Add('```')
    $report.Add('')

    $report.Add('## 5. Unique native stacks (!uniqstack)')
    $report.Add('```')
    $report.Add((Limit-Lines $nativeSections['uniqstack'] 500))
    $report.Add('```')
    $report.Add('')

    $report.Add('## 6. Native lock analysis (!locks)')
    $lk = $nativeSections['locks']
    if ($lk -and ($lk -match 'Unable to resolve ntdll')) {
        $report.Add('_!locks needs the ntdll PDB, which is unavailable offline. Managed lock state')
        $report.Add('is fully covered by !syncblk in section 7.2. To enable !locks, obtain ntdll.pdb')
        $report.Add('once via a symbol-manifest round trip and pass -Symbols <store>._')
    } else {
        $report.Add('```')
        $report.Add((Limit-Lines $lk 120))
        $report.Add('```')
    }
    $report.Add('')
    }

    if ($managedRan) {
        $setup = $managedSections['managed_setup']
        $thr = $managedSections['threads']
        $noClr = $false
        if ($thr -and ($thr -match 'Failed to find runtime|Unable to find module|not a managed process|does not contain the CLR')) { $noClr = $true }
        if (-not $thr -and $setup -and ($setup -match 'Unable to find module')) { $noClr = $true }

        $report.Add('## 7. Managed (.NET) analysis - SOS')
        $report.Add('')
        if ($noClr) {
            $report.Add('_CLR not present in this dump (or SOS failed to load) - native-only process. See raw/managed.log._')
        } else {
            if ($setup -and ($setup -match 'Failed to load data access|mscordacwks|CLR DLL status: ERROR')) {
                $report.Add('> WARNING: DAC/SOS version mismatch detected. Copy mscordacwks.dll + sos.dll + clr.dll')
                $report.Add('> from the SOURCE machine (C:\Windows\Microsoft.NET\Framework64\v4.0.30319\) into a folder')
                $report.Add('> and re-run with -SupportFiles <folder>.')
                $report.Add('')
            }
            # -- 7.0 auto-resolved contention join (done in code, not by the LLM)
            $clrEarly = $managedSections['clrstack']
            $groupsEarly = @()
            if ($clrEarly) { $groupsEarly = @(Get-ManagedStackGroups $clrEarly) }
            $contention = Get-LockContention $managedSections['syncblk']

            $report.Add('### 7.0 Lock contention, auto-resolved (READ THIS FIRST)')
            $report.Add('')
            $report.Add('MonitorHeld encodes 1 (owned) + 2 per waiting thread, so only values >= 3 mean a')
            $report.Add('thread is actually blocked. Rows below are already joined to their stacks.')
            $report.Add('')
            $report.Add('```')
            if ($contention.Count -eq 0) {
                $report.Add('NO MANAGED LOCK CONTENTION (no SyncBlock with MonitorHeld >= 3).')
                $report.Add('If the process is hung, the cause is elsewhere: see section 5 (native stacks).')
                $script:SlimFindings.Add('NO MANAGED LOCK CONTENTION (no SyncBlock with MonitorHeld >= 3).')
            } else {
                $blockedOwners = 0
                foreach ($c in $contention) {
                    $g = Find-GroupForTid $groupsEarly $c.OwnerTid
                    $frame = if ($g) { Get-TopManagedFrame $g.Value } else { '<owner thread not found in managed stacks>' }
                    # the blocking API sits in a SOS bookkeeping frame, so scan every frame
                    $blockApi = ''
                    if ($g) {
                        foreach ($f in $g.Value.Frames) {
                            if ($f -match '(System\.Threading\.Monitor\.(?:Enter|Wait)|WaitHandle\.WaitOne|Thread\.Join)') {
                                $blockApi = $Matches[1]; break
                            }
                        }
                    }
                    if ($blockApi) { $blockedOwners++ }
                    $state = if ($blockApi) { "BLOCKED in $blockApi, inside $frame" } else { "running $frame" }
                    $line = ('CONTENDED SyncBlock {0}: MonitorHeld {1} ({2} waiter(s)) | owner OS tid {3} | owner is {4}' -f $c.Index, $c.Held, $c.Waiters, $c.OwnerTid, $state)
                    $report.Add($line)
                    $script:SlimFindings.Add($line)
                }
                if ($contention.Count -ge 2 -and $blockedOwners -ge 2) {
                    $verdict = ('DEADLOCK PATTERN: {0} lock owners are themselves blocked waiting on a lock -> cycle.' -f $blockedOwners)
                    $report.Add('')
                    $report.Add($verdict)
                    $script:SlimFindings.Add($verdict)
                }
            }
            $report.Add('```')
            $report.Add('')
            $report.Add('### 7.1 !threads')
            $report.Add('```')
            $report.Add((Limit-Lines $thr 140))
            $report.Add('```')
            $report.Add('')
            $report.Add('### 7.2 !syncblk (managed lock owners/waiters - deadlock evidence lives here)')
            $report.Add('```')
            $report.Add((Limit-Lines $managedSections['syncblk'] 80))
            $report.Add('```')
            $report.Add('')
            $report.Add('### 7.3 Managed stacks, deduplicated (~*e !clrstack)')
            $report.Add('')
            $clr = $managedSections['clrstack']
            if ($clr) {
                $groups = $groupsEarly
                if ($groups.Count -gt 0) {
                    $gi = 0
                    foreach ($g in $groups) {
                        $gi++
                        if ($gi -gt 25) { $report.Add("_... more groups in raw/managed.log_"); break }
                        $tids = $g.Value.Tids -join ', '
                        $report.Add("**Group $gi - $($g.Value.Tids.Count) thread(s)** (OS tid: $tids)")
                        if ($g.Value.Tids.Count -le 3 -and -not $g.Value.Label) {
                            $script:SlimGroups.Add("**Group $gi - $($g.Value.Tids.Count) thread(s)** (OS tid: $tids)")
                            $script:SlimGroups.Add('```')
                            $sfc = 0
                            foreach ($sf in $g.Value.Frames) {
                                $sfc++
                                if ($sfc -gt 12) { $script:SlimGroups.Add('    ...'); break }
                                $script:SlimGroups.Add("    $sf")
                            }
                            $script:SlimGroups.Add('```')
                            $script:SlimGroups.Add('')
                        }
                        if ($g.Value.Label) {
                            $report.Add("_$($g.Value.Label)_")
                        } else {
                            $report.Add('```')
                            $fcount = 0
                            foreach ($f in $g.Value.Frames) {
                                $fcount++
                                if ($fcount -gt 30) { $report.Add('    ...'); break }
                                $report.Add("    $f")
                            }
                            if ($g.Value.Frames.Count -eq 0) { $report.Add('    <no managed frames on this thread>') }
                            $report.Add('```')
                        }
                        $report.Add('')
                    }
                } else {
                    $report.Add('_could not parse clrstack output; raw dump below_')
                    $report.Add('```')
                    $report.Add((Limit-Lines $clr 400))
                    $report.Add('```')
                }
            } else {
                $report.Add('_no clrstack output captured_')
            }
        }
        $report.Add('')
    }

    if ($Deep -and $managedSections.ContainsKey('dumpheap')) {
        $report.Add('## 8. Heap statistics (top of !dumpheap -stat)')
        $report.Add('```')
        $dh = $managedSections['dumpheap'] -split "\r?\n"
        $tail = $dh | Select-Object -Last 60
        foreach ($l in $tail) { $report.Add($l) }
        $report.Add('```')
        $report.Add('')
    }

    $report.Add('---')
    $report.Add('Raw logs: `raw/native.log`, `raw/managed.log`. Full module inventory: `modules.csv`.')
    $report.Add('LLM: read section 1 and section 7.0 first (about 2 KB). Everything else only if those two')
    $report.Add('are inconclusive. A slim extract of exactly those parts is written to report-slim.md.')

    $reportPath = Join-Path $OutDir 'report.md'
    Set-Content -Path $reportPath -Value $report -Encoding UTF8

    # -- report-slim.md : the minimum set a small/offline model can hold in context
    $slim = New-Object System.Collections.Generic.List[string]
    $slim.Add('# DMP Triage - slim report (for small/offline models)')
    $slim.Add('')
    $slim.Add("- Dump: ``$Dump`` ($($pre.FileSizeText))")
    $slim.Add("- Full report with all sections: ``report.md`` in this same folder")
    $slim.Add('')
    $slim.Add('## 1. What this dump is')
    $slim.Add('```')
    foreach ($l in $pre.Lines) { $slim.Add($l) }
    $slim.Add('```')
    $slim.Add('')
    $slim.Add('## 2. Lock contention, already resolved for you')
    $slim.Add('```')
    if ($script:SlimFindings -and $script:SlimFindings.Count -gt 0) {
        foreach ($l in $script:SlimFindings) { $slim.Add($l) }
    } else {
        $slim.Add('Managed (.NET) analysis did not run for this dump - see report.md section 7.')
    }
    $slim.Add('```')
    $slim.Add('')
    $slim.Add('## 3. Small thread groups (1-3 threads: the interesting ones)')
    if ($script:SlimGroups -and $script:SlimGroups.Count -gt 0) {
        foreach ($l in $script:SlimGroups) { $slim.Add($l) }
    } else {
        $slim.Add('_none captured_')
    }
    $slimPath = Join-Path $OutDir 'report-slim.md'
    Set-Content -Path $slimPath -Value $slim -Encoding UTF8

    Write-Info "DONE. report: $reportPath"
    Write-Info "      slim (small models): $slimPath\"
}

# ----------------------------------------------------------- check command
function Invoke-Check {
    Write-Info "dmp-triage v$script:ToolVersion environment check"
    $cdb = Find-Cdb -Override $CdbPath
    if ($cdb) { Write-Info "cdb.exe        : $cdb" }
    else {
        $script:RunStatus = 1
        Write-Warn 'cdb.exe        : NOT FOUND (exit 1 - native/managed tracks unavailable)'
        Write-Info '  fix: copy a "Windows Kits\10\Debuggers\x64" folder to bin\debuggers\,'
        Write-Info '       or run tools\get-debuggers.ps1 (internet needed), or winget install Microsoft.WinDbg'
    }
    $sos = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\sos.dll'
    Write-Info (".NET Fx SOS    : {0}" -f $(if (Test-Path $sos) { 'present' } else { 'not found' }))
    Write-Info '                 (managed analysis is decided per dump: the debugger loads the SOS/DAC'
    Write-Info '                  matching that dump. .NET Core needs a matching mscordaccore.dll.)'
    Write-Info ("PowerShell     : {0}" -f $PSVersionTable.PSVersion)

    if ($Dump) {
        if (-not (Test-Path -LiteralPath $Dump -PathType Leaf)) { throw "dump not found (or not a file): $Dump" }
        Write-Info "pre-triage of: $Dump"
        $pre = Read-MinidumpPreTriage -Path (Resolve-Path -LiteralPath $Dump).Path -ModuleCsvPath $null
        foreach ($l in $pre.Lines) { Write-Host "    $l" }
        if (-not $pre.Ok -or -not $pre.IsStandard) { $script:RunStatus = 1 }
    }
}

# --------------------------------------------------------- package command
function Invoke-Package {
    # package root: the folder holding tools/ - supports both the standalone
    # layout (script at root) and the skill layout (script under scripts\)
    $pkgRoot = $script:Root
    $parent = Split-Path -Parent $pkgRoot
    if (-not (Test-Path (Join-Path $pkgRoot 'tools')) -and (Test-Path (Join-Path $parent 'tools'))) {
        $pkgRoot = $parent
    }
    if (-not $OutZip) {
        $OutZip = Join-Path $pkgRoot ("dmp-triage-package-{0}.zip" -f (Get-Date -Format 'yyyyMMdd'))
    }
    $items = @()
    foreach ($n in @('dmp-triage.ps1', 'README.md', 'PROMPT.md', 'SKILL.md', 'scripts', 'tools', 'references', 'bin')) {
        $p = Join-Path $pkgRoot $n
        if (Test-Path $p) { $items += $p }
    }
    $binCdb = Join-Path $pkgRoot 'bin\debuggers\cdb.exe'
    if (-not (Test-Path $binCdb)) {
        Write-Warn 'bin\debuggers\cdb.exe is missing - the target machine will need its own copy of the debuggers.'
    }
    if (Test-Path $OutZip) { Remove-Item $OutZip -Force }
    Write-Info "packaging -> $OutZip"
    Compress-Archive -Path $items -DestinationPath $OutZip -CompressionLevel Optimal
    $sz = [math]::Round((Get-Item $OutZip).Length / 1MB, 1)
    Write-Info "done ($sz MB). Carry this zip to the air-gapped machine and unzip anywhere."
}

# ------------------------------------------------------------------ help
function Show-Help {
    Write-Host @"
dmp-triage v$script:ToolVersion - offline .dmp analysis master CLI

  .\dmp-triage.ps1 check   [-Dump <file>]
      Environment check + instant dependency-free pre-triage of a dump
      (standard-or-not, hang-or-crash, OS build, threads/contexts, modules).

  .\dmp-triage.ps1 analyze -Dump <file> [options]
      Full pipeline: pre-triage -> cdb native pass -> cdb managed (SOS) pass
      -> compact report.md (+ raw logs, modules.csv).
      -OutDir <dir>        output folder (default .\dmp-triage-out\<name>-<stamp>)
      -Symbols <dir>       LOCAL symbol store (never touches network; -netsyms:no)
      -SupportFiles <dir>  folder with source-machine exe/pdb/clr/mscordacwks/sos
      -CdbPath <cdb.exe>   explicit cdb location
      -Deep                adds ~*kvn, !handle, !eeheap, !dumpheap -stat
      -NativeOnly / -ManagedOnly
      -TimeoutSec <n>      per-pass timeout (default 3600)

  .\dmp-triage.ps1 package [-OutZip <zip>]
      Builds the USB-portable zip (script + README + tools + bin\debuggers).

  Exit codes: 0 full success | 1 completed but degraded (non-standard dump,
  cdb missing, or a debugger pass failed/timed out) | 2 fatal error.
"@
}

# ------------------------------------------------------------- dispatch
# exit codes: 0 = full success, 1 = completed but degraded (non-standard dump,
# cdb missing, or a debugger pass failed/timed out), 2 = fatal error
$script:RunStatus = 0
try {
    switch ($Command) {
        'analyze' { Invoke-Analyze }
        'check'   { Invoke-Check }
        'package' { Invoke-Package }
        default   { Show-Help }
    }
} catch {
    Write-Host "[dmp-triage] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}
exit $script:RunStatus
