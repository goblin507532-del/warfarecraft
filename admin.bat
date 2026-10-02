@echo off
rem Double-click: starts the local server (if it isn't running) and opens the admin page.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$busy = Get-NetTCPConnection -LocalPort 8123 -State Listen -ErrorAction SilentlyContinue; if (-not $busy) { Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','tools\serve-site.ps1','-NoBrowser' -WorkingDirectory (Get-Location); Start-Sleep -Seconds 4 }; Start-Process 'http://127.0.0.1:8123/admin.html'"
