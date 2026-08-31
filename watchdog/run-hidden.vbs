' Launch the watchdog with no console window at all.
'
' Task Scheduler running a console app in an interactive session flashes a
' window on every run -- every five minutes, on top of whatever the user is
' doing, including full-screen games. wscript has no console of its own, and
' Run(..., 0, False) starts the child hidden and does not wait for it.
Dim sh, cmd
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ _
    & sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\.claude-mem-watchdog\watchdog.ps1"""
sh.Run cmd, 0, False
