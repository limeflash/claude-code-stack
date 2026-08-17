<#
    Watchdog for the two network services claude-mem depends on: the Ollama
    proxy on :11435 and the claude-mem worker on :37777.

    The codebase-memory-mcp daemon is NOT handled here -- see the note further
    down for why it cannot be, and where it is handled instead.

    Design rules, in order of importance:

    1. Do no harm. It only kills processes it can positively identify as part of
       a broken component. Anything it cannot name is left alone -- including
       the .claude-mem-proxy process, which a naive *claude-mem* filter matches
       and which must survive.

    2. Do nothing when nothing needs it. With no agent client running the script
       exits immediately: no probing, no spawning, no log noise. Same when the
       user has disabled the claude-mem plugin -- that is a decision, not a
       fault.

    3. Never race. One global mutex covers scheduled and manual runs alike; two
       copies of this script once fought, and one killed the healthy daemon the
       other had just started.

    4. Verify, never assume. A component counts as recovered only when a real
       check passes -- a socket actually bound, an HTTP response returned.
#>

$ErrorActionPreference = 'SilentlyContinue'

$Home_      = $env:USERPROFILE
$LogDir     = Join-Path $Home_ '.claude-mem-watchdog'
$Log        = Join-Path $LogDir 'watchdog.log'
$Settings   = Join-Path $Home_ '.claude\settings.json'
$CacheDir   = Join-Path $Home_ '.claude\plugins\cache\thedotmack\claude-mem'
$Cbm        = Join-Path $env:LOCALAPPDATA 'Programs\codebase-memory-mcp\codebase-memory-mcp.exe'
$WorkerPort = 37777
$ProxyPort  = 11435

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# Single instance, always. Two copies of this script racing is not a theoretical
# worry: the scheduled run overlapping a manual one had them fight, and one
# killed the healthy daemon the other had just started. The task's own
# IgnoreNew does not cover runs started by hand, so the lock lives here.
$mutex = New-Object System.Threading.Mutex($false, 'Global\claude-mem-watchdog')
$acquired = $false
try { $acquired = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] {
    # Previous run exited without releasing (we exit early in many places).
    # The lock is ours now; that is exactly what an abandoned mutex means.
    $acquired = $true
}
if (-not $acquired) { exit 0 }

function Write-Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') $msg" | Add-Content -Path $Log -Encoding UTF8
    if ((Get-Item $Log).Length -gt 512KB) {
        $keep = Get-Content $Log -Tail 500
        Set-Content -Path $Log -Value $keep -Encoding UTF8
    }
}

function Test-Port([int]$Port) {
    try { $null = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop; return $true } catch { return $false }
}

function Start-Detached([string]$CommandLine) {
    # Task Scheduler terminates the task's entire process tree once the action
    # exits, which would take every service we just started with it -- the
    # daemon came back up and then died seconds later, looking like a start that
    # never worked. Creating the process through WMI parents it to WmiPrvSE
    # instead, outside our job object, so it survives us.
    # ShowWindow = SW_HIDE, or WMI would pop a console the user could Ctrl+C --
    # the exact way the proxy died once already.
    $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly `
              -Property @{ ShowWindow = [uint16]0 } -ErrorAction SilentlyContinue
    $args = @{ CommandLine = $CommandLine }
    if ($si) { $args['ProcessStartupInformation'] = $si }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
             -Arguments $args -ErrorAction SilentlyContinue
    return ($r -and $r.ReturnValue -eq 0)
}

# ---------------------------------------------------------------- gate -------
# Nothing here serves anything unless an agent client is running. This is the
# whole point of the gate: with no client there is no consumer, so a restart
# would only burn CPU and write log lines nobody reads.
$clients = @('claude', 'opencode', 'cursor', 'code', 'codex') |
    ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue } |
    Measure-Object
if ($clients.Count -eq 0) { exit 0 }

# The codebase-memory-mcp daemon is deliberately NOT handled here. Its daemon
# and CLI find each other through a named pipe whose name is a hash of the
# launching context, and a daemon started by Task Scheduler publishes a
# different name than an interactive CLI looks for -- it runs, holds the UI
# port, and stays invisible forever. Keeping it alive therefore belongs to a
# Claude Code SessionStart hook, which runs in the right context:
#   ~/.claude/hooks/ensure-cbm-daemon.ps1
# ------------------------------------------------------------ claude-mem ----
# Everything below serves claude-mem. If the user disabled the plugin, that is a
# decision, not a fault: stop here rather than resurrecting it.
$enabled = $false
try { $enabled = (Get-Content $Settings -Raw | ConvertFrom-Json).enabledPlugins.'claude-mem@thedotmack' } catch { }
if (-not $enabled) { exit 0 }

# The proxy claude-mem generates through. Its own failure is quiet in the worst
# way: the worker keeps reporting healthy while every request dies against a
# closed port, so memory silently stops being written.
if (-not (Test-Port $ProxyPort)) {
    Write-Log "ollama proxy down on :$ProxyPort -- restarting"
    $starter = Join-Path $Home_ '.claude-mem-proxy\start-proxy.ps1'
    if (Test-Path $starter) {
        Start-Detached "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$starter`"" | Out-Null
        Start-Sleep -Seconds 5
        if (Test-Port $ProxyPort) { Write-Log '  proxy back up' } else { Write-Log '  proxy did not come up' }
    } else {
        Write-Log '  start-proxy.ps1 missing -- skipped'
    }
}

# The worker itself.
$workerOk = $false
try {
    $r = Invoke-WebRequest "http://localhost:$WorkerPort" -TimeoutSec 5 -UseBasicParsing
    if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { $workerOk = $true }
} catch { }
if ($workerOk) { exit 0 }

Write-Log "claude-mem worker unhealthy on :$WorkerPort"

if (Test-Port $WorkerPort) {
    $owner = (Get-NetTCPConnection -LocalPort $WorkerPort -State Listen | Select-Object -First 1).OwningProcess
    $proc  = Get-Process -Id $owner -ErrorAction SilentlyContinue

    if (-not $proc) {
        # Socket outlived its owner: a child inherited the handle. In practice
        # that child is claude-mem's own Chroma stack, orphaned when the worker
        # died -- safe to kill, and it releases the port without touching the
        # editor.
        Write-Log "  port held by dead PID $owner (orphaned socket); clearing orphaned claude-mem helpers"
        $orphans = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -eq 'chroma-mcp.exe' -or
            ($_.Name -in @('python.exe', 'node.exe', 'bun.exe') -and
             $_.CommandLine -like '*chroma*' -and $_.CommandLine -notlike '*claude-mem-proxy*')
        }
        foreach ($o in $orphans) {
            Write-Log "    killing $($o.ProcessId) ($($o.Name))"
            Stop-Process -Id $o.ProcessId -Force
        }
        Start-Sleep -Seconds 3

        # Only an actual bind proves the port is reclaimed; netstat keeps showing
        # the ghost until the last inherited handle closes.
        $free = $false
        try {
            $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse('127.0.0.1'), $WorkerPort)
            $probe.Start(); $probe.Stop(); $free = $true
        } catch { }
        if (-not $free) { Write-Log '  port still held -- not killing unknown processes'; exit 0 }
        Write-Log '  port reclaimed'
    }
    elseif ($proc.ProcessName -in @('bun', 'node')) {
        $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$owner").CommandLine
        if ($cl -like '*claude-mem*' -and $cl -notlike '*claude-mem-proxy*') {
            Write-Log "  killing hung worker PID $owner"
            Stop-Process -Id $owner -Force
            Start-Sleep -Seconds 2
        } else {
            Write-Log "  PID $owner is not a claude-mem worker -- leaving it"; exit 0
        }
    }
    else {
        Write-Log "  port owned by $($proc.ProcessName) -- not ours, leaving it"; exit 0
    }
}

# Newest non-orphaned plugin version, the same rule the hooks use.
$plugin = Get-ChildItem $CacheDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d' -and -not (Test-Path (Join-Path $_.FullName '.orphaned_at')) } |
    Where-Object { Test-Path (Join-Path $_.FullName 'scripts\worker-service.cjs') } |
    Sort-Object { try { [version]($_.Name -split '-')[0] } catch { [version]'0.0.0' } } |
    Select-Object -Last 1
if (-not $plugin) { Write-Log '  plugin scripts not found -- nothing to restart'; exit 1 }

Write-Log "  respawning worker from $($plugin.Name)"
$runner = Join-Path $plugin.FullName 'scripts\bun-runner.js'
$svc    = Join-Path $plugin.FullName 'scripts\worker-service.cjs'
Start-Detached "node `"$runner`" `"$svc`" start" | Out-Null

# Poll rather than sleep once. claude-mem's own cold-boot window is ~15s, so a
# single 12s check reported "still down" for a worker that came up fine moments
# later -- a wrong verdict about a correct repair is worse than no log line.
$deadline = (Get-Date).AddSeconds(45)
$up = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    try {
        $r = Invoke-WebRequest "http://localhost:$WorkerPort" -TimeoutSec 5 -UseBasicParsing
        if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { $up = $true; break }
    } catch { }
}
if ($up) { Write-Log '  worker recovered' } else { Write-Log '  worker still down after 45s' }
