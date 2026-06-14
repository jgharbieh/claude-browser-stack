# ab.ps1 - traced wrapper around `agent-browser`.
#
# Drop-in replacement: use `ab.ps1 <same args as agent-browser>`. Every call is
# appended as a structured JSONL event to the durable transcript so a browser
# session is replayable and any failed verification is debuggable after the fact.
#
#   ab.ps1 --session wt1 open https://app.weatherops.ai
#   ab.ps1 --session wt1 click "button.save"
#
# Transcript:  <AB_TRACE_ROOT>\<session>\transcript-<yyyyMMdd>.jsonl   (default root D:\dev\sandbox)
# First line per file = an `env` header (git SHA, cwd, browser, agent-browser version).
# Each call      = an `action` event {ts, command, args, durationMs, exit, ok, output tail}.
#
# Keep ASCII-only (PowerShell 5.1 reads BOM-less files as ANSI).

$ErrorActionPreference = "Stop"
$argv = $args

if (-not $argv -or $argv.Count -eq 0) {
    Write-Host "Usage: ab.ps1 <agent-browser args>   (e.g. ab.ps1 --session wt1 open <url>)"
    exit 2
}

# Resolve session name from --session, else 'default'.
$session = "default"
for ($i = 0; $i -lt $argv.Count; $i++) {
    if ($argv[$i] -eq "--session" -and ($i + 1) -lt $argv.Count) { $session = $argv[$i + 1]; break }
}

$root = if ($env:AB_TRACE_ROOT) { $env:AB_TRACE_ROOT } else { "D:\dev\sandbox" }
$dir = Join-Path $root $session
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# If a run is active for this session (run.ps1 start), write the transcript into that
# run folder so every stream of the run lives together. Otherwise fall back to a per-day file.
$inRun = $false
$ptr = Join-Path $dir ".current-run"
if (Test-Path $ptr) {
    $rd = (Get-Content $ptr -Raw).Trim()
    if ($rd -and (Test-Path $rd)) { $file = Join-Path $rd "transcript.jsonl"; $inRun = $true }
}
if (-not $inRun) {
    $day = Get-Date -Format "yyyyMMdd"
    $file = Join-Path $dir "transcript-$day.jsonl"
}

# Env header once per per-day file (run folders already carry env.json from run.ps1).
if ((-not $inRun) -and (-not (Test-Path $file))) {
    $sha = ""
    try { $sha = (& git rev-parse --short HEAD 2>$null) } catch {}
    $abv = ""
    try { $abv = (& agent-browser --version 2>$null | Select-Object -First 1) } catch {}
    $hdr = [ordered]@{
        type    = "env"
        ts      = (Get-Date).ToString("o")
        session = $session
        cwd     = (Get-Location).Path
        gitSha  = "$sha".Trim()
        agentBrowser = "$abv".Trim()
        host    = $env:COMPUTERNAME
    }
    ($hdr | ConvertTo-Json -Compress) | Add-Content -Path $file -Encoding utf8
}

# First non-flag token = the command (open/click/type/...).
$command = ($argv | Where-Object { $_ -notlike "--*" } | Select-Object -First 1)

$start = Get-Date
$out = (& agent-browser @argv 2>&1 | Out-String)
$code = $LASTEXITCODE
$dur = [int]((Get-Date) - $start).TotalMilliseconds

$tail = ($out.Trim() -split "`n" | Select-Object -Last 6) -join " | "
$evt = [ordered]@{
    type       = "action"
    ts         = $start.ToString("o")
    session    = $session
    command    = $command
    args       = ($argv -join " ")
    durationMs = $dur
    exit       = $code
    ok         = ($code -eq 0)
    output     = $tail.Trim()
}
($evt | ConvertTo-Json -Compress) | Add-Content -Path $file -Encoding utf8

# Pass the real output + exit code straight through.
Write-Output $out
exit $code
