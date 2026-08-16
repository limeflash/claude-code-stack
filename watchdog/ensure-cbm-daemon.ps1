<#
    Keep the codebase-memory-mcp permanent daemon alive.

    Why this runs as a Claude Code hook instead of a scheduled task: the daemon
    and the CLI find each other through a named pipe whose name is a hash of the
    launching context. A daemon started by Task Scheduler publishes a different
    pipe name than the one an interactive CLI looks for, so it runs happily and
    stays permanently invisible -- `daemon status` reports "not running" while
    the process is alive and holding the UI port. Started from inside a Claude
    Code session, the context matches and the daemon is found.

    It also means the daemon only ever starts when an agent is actually running,
    which is what we want: no client, no daemon, no idle background work.
#>

$ErrorActionPreference = 'SilentlyContinue'

$cbm = Join-Path $env:LOCALAPPDATA 'Programs\codebase-memory-mcp\codebase-memory-mcp.exe'
if (-not (Test-Path $cbm)) { exit 0 }

$log = Join-Path $env:USERPROFILE '.claude-mem-watchdog\watchdog.log'
function Note($m) {
    "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') [cbm-hook] $m" | Add-Content -Path $log -Encoding UTF8
}

# Only one of these at a time -- several sessions start at once, and racing
# `daemon start` calls are what wedges the rendezvous in the first place.
$mutex = New-Object System.Threading.Mutex($false, 'Global\cbm-daemon-ensure')
$got = $false
try { $got = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
if (-not $got) { exit 0 }

try {
    if ((& $cbm daemon status 2>$null | Out-String) -match 'daemon:\s*active') { exit 0 }

    # Clear daemons that are running but undiscoverable, otherwise `daemon start`
    # sees one already there and quietly does nothing. Only processes carrying
    # the daemon flag are touched; unflagged ones are stdio MCP servers owned by
    # live sessions.
    $stale = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'codebase-memory-mcp.exe' -and $_.CommandLine -like '*--cbm-daemon-internal*'
    }
    foreach ($s in $stale) { Stop-Process -Id $s.ProcessId -Force }
    if ($stale) { Start-Sleep -Seconds 2 }

    & $cbm daemon start 2>$null | Out-Null
    Start-Sleep -Seconds 5

    if ((& $cbm daemon status 2>$null | Out-String) -match 'daemon:\s*active') {
        Note 'daemon started'
    } else {
        Note 'daemon still not visible after start'
    }
}
finally {
    if ($got) { $mutex.ReleaseMutex() }
}
