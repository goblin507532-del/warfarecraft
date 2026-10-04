# Zips the server world, keeps the last few and throws the oldest away.
#
# Why: the world is the one thing here that cannot be rebuilt. The mods come from the pack, the configs come from
# the pack, the ranks are small text files - but Borodovsk is ~1 GB of region data that exists nowhere else. One
# bad shutdown, one corrupted chunk, one "cleared the folder" and it is gone for good.
#
# Run:  powershell -ExecutionPolicy Bypass -File tools\backup-world.ps1
#       powershell -ExecutionPolicy Bypass -File tools\backup-world.ps1 -Keep 10 -Out D:\backups
#
# Nightly, through Task Scheduler (one line, run it once in an admin PowerShell):
#   schtasks /create /tn "Warfare world backup" /tr "powershell -ExecutionPolicy Bypass -File C:\Mods\warfarehub\tools\backup-world.ps1" /sc daily /st 05:00
#
# NOTE: every message in this file stays Latin-only. Cyrillic inside a .ps1 is read as ANSI and turns to mojibake.
param(
  [string]$Server = 'C:\Mods\warfareserver',
  [string]$Out = 'C:\Mods\warfare-backups',
  [int]$Keep = 5
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$world = Join-Path $Server 'world'
if (-not (Test-Path $world)) { throw "No world at $world" }
New-Item -ItemType Directory -Force $Out | Out-Null

# A world that is being written to can still be zipped - the result is a backup you would only ever restore in a
# disaster anyway - but it is worth saying so, and worth marking the file, so a clean one is preferred on restore.
$live = $false
$running = Get-Process java -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\Mods\jdk-21*' }
if ($running) {
  Write-Host 'WARNING: the server looks like it is running. Backing up anyway, marking the file as -live.' -ForegroundColor Yellow
  Write-Host '         For a backup you can trust completely, stop the server first (type stop in its window).' -ForegroundColor Yellow
  $live = $true
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$name = "world_$stamp"
if ($live) { $name = "$name-live" }
$zip = Join-Path $Out "$name.zip"

$size = (Get-ChildItem $world -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum)
Write-Host ("source: {0:N0} MB in {1} files" -f ($size.Sum / 1MB), $size.Count)
Write-Host "writing $zip ..."
$started = Get-Date

# Fastest, not Optimal, on purpose: region files are already compressed inside, so Optimal spends minutes to save
# a couple of percent. The 33k tiny files of the map baseline are what actually takes the time here.
try {
  [System.IO.Compression.ZipFile]::CreateFromDirectory(
    $world, $zip, [System.IO.Compression.CompressionLevel]::Fastest, $true)
} catch {
  # A file held open by the running server fails the whole archive; copy to a staging folder and zip that instead.
  Write-Host "direct zip failed ($($_.Exception.Message)), copying to a staging folder first" -ForegroundColor Yellow
  if (Test-Path $zip) { Remove-Item $zip -Force }
  $stage = Join-Path $Out "_staging"
  if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
  robocopy $world $stage /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
  [System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stage, $zip, [System.IO.Compression.CompressionLevel]::Fastest, $true)
  Remove-Item $stage -Recurse -Force
}

$took = [int]((Get-Date) - $started).TotalSeconds
$made = Get-Item $zip
Write-Host ("done: {0:N0} MB in {1} s" -f ($made.Length / 1MB), $took) -ForegroundColor Green

# ---- rotation: keep the newest $Keep, drop the rest
$all = Get-ChildItem (Join-Path $Out 'world_*.zip') | Sort-Object LastWriteTime -Descending
if ($all.Count -gt $Keep) {
  foreach ($old in ($all | Select-Object -Skip $Keep)) {
    Remove-Item $old.FullName -Force
    Write-Host "  removed old backup $($old.Name)"
  }
}
$left = Get-ChildItem (Join-Path $Out 'world_*.zip') | Measure-Object Length -Sum
Write-Host ("kept {0} backups, {1:N0} MB total in {2}" -f (Get-ChildItem (Join-Path $Out 'world_*.zip')).Count, ($left.Sum / 1MB), $Out)
