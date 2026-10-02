# Builds the pack that is handed out FROM THIS PC.
#
# Copies the pack files into docs\pack\files and writes docs\pack\manifest.json with paths relative to the manifest,
# so the very same pack works through localhost, a LAN address or the domain - nothing is baked in.
#
# Players' manifest URL is then:
#   http://warfarecraft.ru/pack/manifest.json        (domain, via tools\serve-domain.ps1)
#   http://<your-ip>:8123/pack/manifest.json         (no domain yet, via tools\serve-site.ps1 -Public)
#   http://127.0.0.1:8123/pack/manifest.json         (your own test)
#
# Run:  powershell -ExecutionPolicy Bypass -File tools\make-pack.ps1
param(
  [string]$Instance = 'C:\Users\gobli\AppData\Roaming\ElyPrismLauncher\instances\1.21.1(2)\minecraft',
  [string[]]$Roots = @('mods', 'config', 'defaultconfigs', 'resourcepacks', 'shaderpacks'),
  [string]$Notes = 'Build from the owner PC.',
  [string]$Server = '26.133.174.202:12345'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'docs\pack'
# Russian text can't live inside a .ps1 (ANSI reading breaks the file), so the note for players is a separate file
$notesFile = Join-Path $outDir 'notes.txt'
if ((Test-Path $notesFile) -and -not $PSBoundParameters.ContainsKey('Notes')) {
  $fromFile = [IO.File]::ReadAllText($notesFile, [Text.Encoding]::UTF8).Trim()
  if ($fromFile) { $Notes = $fromFile }
}
$filesDir = Join-Path $outDir 'files'
if (-not (Test-Path (Join-Path $Instance 'mods'))) { throw "No mods folder in $Instance" }
New-Item -ItemType Directory -Force $outDir | Out-Null

# versions from the instance metadata
$mc = '1.21.1'; $neo = '21.1.250'
$meta = Join-Path (Split-Path -Parent $Instance) 'mmc-pack.json'
if (Test-Path $meta) {
  foreach ($c in (Get-Content $meta -Raw | ConvertFrom-Json).components) {
    if ($c.uid -eq 'net.minecraft') { $mc = $c.version }
    if ($c.uid -eq 'net.neoforged') { $neo = $c.version }
  }
}

$skipExt = @('.bak', '.disabled', '.log', '.lock', '.tmp', '.part')
$entries = @()
$total = 0
$kept = @{}
foreach ($dir in $Roots) {
  $src = Join-Path $Instance $dir
  if (-not (Test-Path $src)) { continue }
  foreach ($f in Get-ChildItem $src -Recurse -File) {
    if ($skipExt -contains $f.Extension.ToLower()) { continue }
    $rel = $f.FullName.Substring($Instance.Length + 1).Replace('\', '/')
    if ($rel -like '*/cache/*' -or $rel -like '*/logs/*') { continue }
    $target = Join-Path $filesDir ($rel -replace '/', '\')
    New-Item -ItemType Directory -Force (Split-Path -Parent $target) | Out-Null
    # copy only what changed, so re-running this is quick
    if ((-not (Test-Path $target)) -or (Get-Item $target).Length -ne $f.Length -or (Get-Item $target).LastWriteTimeUtc -ne $f.LastWriteTimeUtc) {
      Copy-Item $f.FullName $target -Force
    }
    $url = ($rel.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $entries += [ordered]@{
      path = $rel
      url = "files/$url"
      sha256 = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLower()
      size = $f.Length
    }
    $kept[$target] = $true
    $total += $f.Length
  }
}

# drop files that left the pack, so the folder mirrors the instance
if (Test-Path $filesDir) {
  foreach ($old in Get-ChildItem $filesDir -Recurse -File) {
    if (-not $kept.ContainsKey($old.FullName)) {
      Remove-Item $old.FullName -Force
      Write-Host "  - $($old.FullName.Substring($filesDir.Length + 1))"
    }
  }
}

$manifest = [ordered]@{
  name = 'Warfare Maps and Kits'
  version = (Get-Date -Format 'yyyy.MM.dd-HHmm')
  mcVersion = $mc
  loader = 'NeoForge'
  loaderVersion = $neo
  serverAddress = $Server
  notes = $Notes
  files = $entries
}
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $outDir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), $enc)

# the site's "current build" line reads this
$site = [ordered]@{
  version = $manifest.version
  notes = $Notes
  files = $entries.Count
  size = $total
  date = (Get-Date -Format 'yyyy-MM-dd')
}
[IO.File]::WriteAllText((Join-Path $root 'docs\version.json'), ($site | ConvertTo-Json -Depth 3), $enc)

Write-Host ''
Write-Host "files  : $($entries.Count)   ($([math]::Round($total/1MB,1)) MB in docs\pack\files)"
Write-Host "game   : Minecraft $mc + NeoForge $neo"
Write-Host "version: $($manifest.version)"
Write-Host ''
Write-Host 'Manifest URL for players:' -ForegroundColor Green
Write-Host '  http://warfarecraft.ru/pack/manifest.json   (once the domain points here)' -ForegroundColor Yellow
Write-Host '  http://127.0.0.1:8123/pack/manifest.json    (your own test, tools\serve-site.ps1)'
Write-Host ''
Write-Host 'docs\pack\files is excluded from tools\publish-repo.ps1 - it is handed out from this PC, not GitHub.'
