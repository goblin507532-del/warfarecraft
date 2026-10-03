# Brings the local server in line with the pack players get.
#
# Why this exists: the server and the client must carry the SAME mods. Update one and forget the other and
# players are thrown off at login with a mod mismatch. This copies mods, configs and the TACZ gun packs from
# docs\pack\files, leaving out the nine client-only mods a server has no use for.
#
# Run:  powershell -ExecutionPolicy Bypass -File tools\sync-server.ps1
#       powershell -ExecutionPolicy Bypass -File tools\sync-server.ps1 -Server D:\other\path
#
# Stop the server first: a jar replaced under a running server is a crash waiting to happen.
param(
  [string]$Server = 'C:\Mods\warfareserver'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pack = Join-Path $root 'docs\pack\files'
if (-not (Test-Path "$pack\mods")) { throw "No pack at $pack - run tools\make-pack.ps1 first" }
if (-not (Test-Path $Server)) { throw "No server folder at $Server" }

$running = Get-Process java -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\Mods\jdk-21*' }
if ($running) {
  Write-Host 'WARNING: a java process is running. Stop the server (type stop in its window) before syncing.' -ForegroundColor Yellow
  $answer = Read-Host 'Continue anyway? (y/N)'
  if ($answer -ne 'y') { return }
}

# A server loads these for nothing: they are rendering, menus and client config UI.
$clientOnly = @('DistantHorizons', 'dynamic-fps', 'fancymenu', 'iris-neoforge', 'sodium-neoforge',
                'melody_', 'konkrete_', 'offlineskins', 'yet_another_config_lib')

Write-Host 'mods...'
$copied = 0
$wanted = @{}
foreach ($m in Get-ChildItem "$pack\mods\*.jar") {
  $skip = $false
  foreach ($c in $clientOnly) { if ($m.Name -like "*$c*") { $skip = $true } }
  if ($skip) { continue }
  $wanted[$m.Name] = $true
  $target = Join-Path $Server "mods\$($m.Name)"
  if ((-not (Test-Path $target)) -or (Get-Item $target).Length -ne $m.Length) {
    Copy-Item $m.FullName $target -Force
    Write-Host "  + $($m.Name)"
    $copied++
  }
}
# a mod that left the pack has to leave the server too, or its version lingers and nobody can log in
$removed = 0
foreach ($old in Get-ChildItem "$Server\mods\*.jar") {
  if (-not $wanted.ContainsKey($old.Name)) {
    Remove-Item $old.FullName -Force
    Write-Host "  - $($old.Name)"
    $removed++
  }
}
Write-Host "mods: $copied updated, $removed removed, $($wanted.Count) total"

Write-Host 'config...'
robocopy "$pack\config" "$Server\config" /E /NFL /NDL /NJH /NJS /MT:8 | Out-Null

if (Test-Path "$pack\tacz") {
  Write-Host 'tacz gun packs...'
  robocopy "$pack\tacz" "$Server\tacz" /E /NFL /NDL /NJH /NJS /MT:8 | Out-Null
}

# NeoForge reads server-scoped settings from the world, not from config\
New-Item -ItemType Directory -Force "$Server\world\serverconfig" | Out-Null
$n = 0
foreach ($f in Get-ChildItem "$Server\config\*-server.toml" -ErrorAction SilentlyContinue) {
  Copy-Item $f.FullName "$Server\world\serverconfig\" -Force
  $n++
}
Write-Host "server-scoped configs mirrored into the world: $n"

Write-Host ''
Write-Host 'Done. Start the server with start.bat.'
