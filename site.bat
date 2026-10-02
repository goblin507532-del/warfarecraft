@echo off
rem Double-click to run the site locally and open it in the browser.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\serve-site.ps1" %*
pause
