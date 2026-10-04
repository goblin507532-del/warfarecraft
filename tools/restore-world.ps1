# Puts a backed-up world back.
#
# A backup you cannot restore is not a backup, and restoring one by hand at two in the morning is exactly when a
# folder gets deleted that should not have been. So: this refuses to run while the server is up, it NEVER deletes
# the world it is replacing (it renames it out of the way), and it says what it is about to do before doing it.
#
# Run:  powershell -ExecutionPolicy Bypass -File tools\restore-world.ps1              # lists what there is
#       powershell -ExecutionPolicy Bypass -File tools\restore-world.ps1 -Newest      # takes the newest clean one
#       powershell -ExecutionPolicy Bypass -File tools\restore-world.ps1 -Zip world_2026-10-04_05-00.zip
#
# NOTE: every message in this file stays Latin-only. Cyrillic inside a .ps1 is read as ANSI and turns to mojibake.
param(
  [string]$Server = 'C:\Mods\warfareserver',
  [string]$Out = 'C:\Mods\warfare-backups',
  [string]$Zip = '',
  [switch]$Newest,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$world = Join-Path $Server 'world'
if (-not (Test-Path $Out)) { throw "No backup folder at $Out" }

$all = Get-ChildItem (Join-Path $Out 'world_*.zip') | Sort-Object LastWriteTime -Descending
if ($all.Count -eq 0) { throw "No backups in $Out" }

# ---- with nothing chosen, just show what there is and stop
if (-not $Newest -and -not $Zip) {
  Write-Host ''
  Write-Host 'Backups, newest first:' -ForegroundColor Cyan
  foreach ($b in $all) {
    $live = ''
    if ($b.Name -like '*-live*') { $live = '   (taken while the server was running)' }
    Write-Host ("  {0,-34} {1,7:N0} MB   {2}{3}" -f $b.Name, ($b.Length / 1MB), $b.LastWriteTime, $live)
  }
  Write-Host ''
  Write-Host 'To restore one:' -ForegroundColor Cyan
  Write-Host "  powershell -ExecutionPolicy Bypass -File tools\restore-world.ps1 -Zip $($all[0].Name)"
  Write-Host '  powershell -ExecutionPolicy Bypass -File tools\restore-world.ps1 -Newest'
  Write-Host ''
  Write-Host 'The world is replaced whole: everything built, captured and earned after that backup is gone.' -ForegroundColor Yellow
  return
}

$pick = $null
if ($Newest) {
  # prefer one taken with the server stopped; those are the ones that are certainly consistent
  $pick = $all | Where-Object { $_.Name -notlike '*-live*' } | Select-Object -First 1
  if (-not $pick) { $pick = $all[0] }
} else {
  $pick = $all | Where-Object { $_.Name -eq $Zip } | Select-Object -First 1
  if (-not $pick) { throw "No such backup: $Zip" }
}

$running = Get-Process java -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\Mods\jdk-21*' }
if ($running) {
  throw "The server looks like it is running (PID $($running.Id -join ', ')). Type stop in its window first."
}

Write-Host ''
Write-Host "About to restore: $($pick.Name)  ($('{0:N0}' -f ($pick.Length / 1MB)) MB, $($pick.LastWriteTime))" -ForegroundColor Cyan
Write-Host "Into:             $world" -ForegroundColor Cyan
Write-Host 'The current world is NOT deleted - it is renamed to world_before_restore_<time>.' -ForegroundColor Yellow
Write-Host 'Everything built, captured and earned after that backup will be gone.' -ForegroundColor Yellow
if (-not $Force) {
  $answer = Read-Host 'Type RESTORE to go ahead'
  if ($answer -ne 'RESTORE') { Write-Host 'Nothing done.'; return }
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
if (Test-Path $world) {
  $aside = Join-Path $Server "world_before_restore_$stamp"
  Move-Item $world $aside
  Write-Host "current world moved aside: $aside"
}
New-Item -ItemType Directory -Force $world | Out-Null

Write-Host 'unpacking...'
$started = Get-Date
[System.IO.Compression.ZipFile]::ExtractToDirectory($pick.FullName, $world, $true)
$took = [int]((Get-Date) - $started).TotalSeconds

# a world that was zipped live keeps its session.lock; the server makes a new one, a stale one is harmless
Write-Host ("done in {0} s" -f $took) -ForegroundColor Green
Write-Host 'Start the server as usual (start.bat). If it looks wrong, the old world is still next to it.' -ForegroundColor Green
