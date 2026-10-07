@echo off
rem Fire-and-forget: the hook must return instantly and must never fail the
rem session, so the real work is detached and the exit code is always 0.
start "" /b powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%USERPROFILE%\.claude\hooks\ensure-cbm-daemon.ps1"
exit /b 0
