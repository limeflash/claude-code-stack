<#
    claude-mem watchdog.

    Recovers the failure that made Claude Code unusable on 2026-08-15: the
    worker died, its listening socket on :37777 survived (inherited by a child
    process), and the launcher then refused to spawn a replacement because the
    port looked occupied -- "Port already in use, refusing to start duplicate".
    Nothing answered health checks, so every session-init hook failed and every
    prompt was blocked.

    This script breaks that deadlock: unhealthy + port held by a process we own
    -> kill it and respawn. It never touches the user's Claude Code sessions,
    and it never resurrects the plugin if the user disabled it.
#>

$ErrorActionPreference = 'Stop'

$Port     = 37777
$Home_    = $env:USERPROFILE
$LogDir   = Join-Path $Home_ '.claude-mem-watchdog'
$Log      = Join-Path $LogDir 'watchdog.log'
$Settings = Join-Path $Home_ '.claude\settings.json'
$CacheDir = Join-Path $Home_ '.claude\plugins\cache\thedotmack\claude-mem'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') $msg" | Add-Content -Path $Log -Encoding UTF8
    # keep the log from growing without bound
    if ((Get-Item $Log -EA SilentlyContinue).Length -gt 512KB) {
        $keep = Get-Content $Log -Tail 500
        Set-Content -Path $Log -Value $keep -Encoding UTF8
    }
}

# 1. Respect the user's choice. A disabled plugin stays disabled.
try {
    $enabled = (Get-Content $Settings -Raw | ConvertFrom-Json).enabledPlugins.'claude-mem@thedotmack'
} catch { $enabled = $false }
if (-not $enabled) { exit 0 }

# 2. Healthy? Then there is nothing to do.
try {
    $r = Invoke-WebRequest "http://localhost:$Port" -TimeoutSec 5 -UseBasicParsing
    if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { exit 0 }
} catch { }

Write-Log "worker unhealthy on :$Port"

# 3. Who holds the port?
$owner = $null
try { $owner = (Get-NetTCPConnection -LocalPort $Port -State Listen -EA Stop | Select-Object -First 1).OwningProcess } catch { }

if ($owner) {
    $proc = Get-Process -Id $owner -EA SilentlyContinue
    if (-not $proc) {
        # The socket outlived its owner: a child inherited the handle. Observed
        # in practice, the inheritor is claude-mem's own Chroma stack
        # (chroma-mcp.exe plus its python workers), orphaned when the worker
        # died -- not a Claude Code session. Those are safe to kill, and doing
        # so releases the port without touching the user's editor.
        Write-Log "port held by dead PID $owner (orphaned socket); looking for orphaned claude-mem helpers"

        $orphans = Get-CimInstance Win32_Process -EA SilentlyContinue | Where-Object {
            $_.ProcessId -ne $PID -and (
                $_.Name -eq 'chroma-mcp.exe' -or
                ($_.Name -in @('python.exe', 'node.exe', 'bun.exe') -and
                 $_.CommandLine -like '*chroma*' -and
                 $_.CommandLine -notlike '*claude-mem-proxy*')
            )
        }
        foreach ($o in $orphans) {
            Write-Log "  killing orphaned helper PID $($o.ProcessId) ($($o.Name))"
            Stop-Process -Id $o.ProcessId -Force -EA SilentlyContinue
        }
        Start-Sleep -Seconds 3

        # Only a successful bind proves the port is actually reclaimed.
        $free = $false
        try {
            $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse('127.0.0.1'), $Port)
            $probe.Start(); $probe.Stop(); $free = $true
        } catch { }

        if (-not $free) {
            Write-Log "  port still held after cleanup -- leaving it rather than killing unknown processes"
            exit 0
        }
        Write-Log "  port reclaimed"
    }
    elseif ($proc.ProcessName -in @('bun', 'node')) {
        $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$owner" -EA SilentlyContinue).CommandLine
        if ($cl -like '*claude-mem*' -and $cl -notlike '*claude-mem-proxy*') {
            Write-Log "killing hung worker PID $owner ($($proc.ProcessName))"
            Stop-Process -Id $owner -Force -EA SilentlyContinue
            Start-Sleep -Seconds 2
        } else {
            Write-Log "port owned by PID $owner but it is not a claude-mem worker -- leaving it"
            exit 0
        }
    } else {
        Write-Log "port owned by $($proc.ProcessName) (PID $owner) -- not ours, leaving it"
        exit 0
    }
}

# 4. Locate the newest non-orphaned plugin version, same rule the hooks use.
$plugin = Get-ChildItem $CacheDir -Directory -EA SilentlyContinue |
    Where-Object { $_.Name -match '^\d' -and -not (Test-Path (Join-Path $_.FullName '.orphaned_at')) } |
    Where-Object { Test-Path (Join-Path $_.FullName 'scripts\worker-service.cjs') } |
    Sort-Object { try { [version]($_.Name -split '-')[0] } catch { [version]'0.0.0' } } |
    Select-Object -Last 1

if (-not $plugin) { Write-Log 'plugin scripts not found -- nothing to restart'; exit 1 }

# 5. Respawn, detached, so the watchdog does not hold the worker open.
$runner = Join-Path $plugin.FullName 'scripts\bun-runner.js'
$svc    = Join-Path $plugin.FullName 'scripts\worker-service.cjs'
Write-Log "respawning worker from $($plugin.Name)"
Start-Process -FilePath 'node' -ArgumentList @("`"$runner`"", "`"$svc`"", 'start') -WindowStyle Hidden

# 6. Confirm, so the log records the outcome rather than the intent.
Start-Sleep -Seconds 12
try {
    $r = Invoke-WebRequest "http://localhost:$Port" -TimeoutSec 5 -UseBasicParsing
    Write-Log "recovered: HTTP $($r.StatusCode)"
} catch {
    Write-Log "still down after respawn: $($_.Exception.Message)"
}
