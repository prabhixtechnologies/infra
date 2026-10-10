@echo off
setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\git-dashboard.ps1"
if errorlevel 1 pause
