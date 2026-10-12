@echo off
setlocal
if not exist "%~dp0WindowsUpdateControl.ps1" (
    echo WindowsUpdateControl.ps1 is missing. Extract all files first.
    pause
    exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0WindowsUpdateControl.ps1" -Action Restore
exit /b %errorlevel%
