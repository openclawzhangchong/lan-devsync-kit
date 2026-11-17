@echo off
rem devsync 入口：转发到同目录 devsync.ps1
setlocal
chcp 65001 >nul
set "PS_SCRIPT=%~dp0devsync.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
set "EC=%errorlevel%"
chcp 936 >nul
exit /b %EC%
