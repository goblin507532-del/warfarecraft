# Builds a Modrinth modpack (.mrpack) out of a live Prism/MultiMC instance.
#
# Mods that exist on Modrinth are referenced by their CDN link (nothing of theirs is redistributed);
# everything else - your own jars and files from other sites - goes into overrides/.
#
# Run:  powershell -ExecutionPolicy Bypass -File tools\make-mrpack.ps1
#       powershell -ExecutionPolicy Bypass -File tools\make-mrpack.ps1 -Instance "D:\games\inst\minecraft" -Version 1.0.1
param(
  [string]$Instance = 'C:\Users\gobli\AppData\Roaming\ElyPrismLauncher\instances\1.21.1(2)\minecraft',
  [string]$Name = 'Warfare Maps & Kits',
  [string]$Summary = 'Military maps, kits, commander orders and a 3D tactical map for NeoForge 1.21.1.',
  [string]$Version = '',
  [string]$Minecraft = '',
  [string]$Neoforge = '',
  [switch]$NoConfig
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'pack'
$work = Join-Path $env:TEMP ("mrpack-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $work | Out-Null
New-Item -ItemType Directory -Force $out | Out-Null

if (-not (Test-Path (Join-Path $Instance 'mods'))) { throw "No mods folder in $Instance" }

# ---- versions from the instance metadata when not given
if (-not $Minecraft -or -not $Neoforge) {
  $meta = Join-Path (Split-Path -Parent $Instance) 'mmc-pack.json'
  if (Test-Path $meta) {
    $components = (Get-Content $meta -Raw | ConvertFrom-Json).components
    foreach ($c in $components) {
      if ($c.uid -eq 'net.minecraft' -and -not $Minecraft) { $Minecraft = $c.version }
      if ($c.uid -eq 'net.neoforged' -and -not $Neoforge) { $Neoforge = $c.version }
    }
  }
}
if (-not $Minecraft) { $Minecraft = '1.21.1' }
if (-not $Neoforge) { $Neoforge = '21.1.250' }
if (-not $Version) { $Version = (Get-Date -Format 'yyyy.MM.dd') }
Write-Host "pack $Name $Version  (mc $Minecraft, neoforge $Neoforge)"

# ---- hash every mod
function Hash($path, $algo) {
  return (Get-FileHash -Path $path -Algorithm $algo).Hash.ToLower()
}
$mods = Get-ChildItem (Join-Path $Instance 'mods') -File | Where-Object {
  $_.Extension -eq '.jar' -and $_.Name -notlike '*.bak' -and $_.Name -notlike '*.disabled'
}
Write-Host "mods found: $($mods.Count)"
$entries = @()
foreach ($m in $mods) {
  $entries += [pscustomobject]@{
    File = $m
    Sha1 = Hash $m.FullName 'SHA1'
    Sha512 = Hash $m.FullName 'SHA512'
  }
}

# ---- ask Modrinth which of them it hosts (one batched call)
$resolved = @{}
try {
  $body = @{ hashes = @($entries.Sha512); algorithm = 'sha512' } | ConvertTo-Json -Compress
  $answer = Invoke-RestMethod -Method POST -Uri 'https://api.modrinth.com/v2/version_files' `
    -ContentType 'application/json' -Body $body -Headers @{ 'User-Agent' = 'warfare-hub/1.0 (mrpack builder)' }
  foreach ($p in $answer.PSObject.Properties) { $resolved[$p.Name.ToLower()] = $p.Value }
  Write-Host "known to Modrinth: $($resolved.Count)"
} catch {
  Write-Host "Modrinth lookup failed ($($_.Exception.Message)); everything goes to overrides"
}

# ---- split into links and overrides
$files = @()
$bundled = @()
foreach ($e in $entries) {
  $hit = $resolved[$e.Sha512]
  $url = $null
  if ($hit) {
    foreach ($f in $hit.files) {
      if ($f.hashes.sha512 -and $f.hashes.sha512.ToLower() -eq $e.Sha512) { $url = $f.url; break }
    }
    if (-not $url -and $hit.files.Count -gt 0) { $url = $hit.files[0].url }
  }
  if ($url) {
    $files += [ordered]@{
      path = "mods/" + $e.File.Name
      hashes = [ordered]@{ sha1 = $e.Sha1; sha512 = $e.Sha512 }
      env = [ordered]@{ client = 'required'; server = 'required' }
      downloads = @($url)
      fileSize = $e.File.Length
    }
  } else {
    $bundled += $e.File
  }
}

# ---- overrides: bundled jars plus the pack's configs
$ovr = Join-Path $work 'overrides'
New-Item -ItemType Directory -Force (Join-Path $ovr 'mods') | Out-Null
foreach ($f in $bundled) { Copy-Item $f.FullName (Join-Path $ovr 'mods') -Force }
if (-not $NoConfig) {
  foreach ($dir in 'config', 'defaultconfigs', 'resourcepacks', 'shaderpacks') {
    $src = Join-Path $Instance $dir
    if (-not (Test-Path $src)) { continue }
    $dst = Join-Path $ovr $dir
    robocopy $src $dst /E /XF *.log *.lock *.tmp /NFL /NDL /NJH /NJS | Out-Null
  }
}

# ---- index
$index = [ordered]@{
  formatVersion = 1
  game = 'minecraft'
  versionId = $Version
  name = $Name
  summary = $Summary
  files = $files
  dependencies = [ordered]@{ minecraft = $Minecraft; neoforge = $Neoforge }
}
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $work 'modrinth.index.json'), ($index | ConvertTo-Json -Depth 8), $enc)

# ---- zip it up as .mrpack
$safe = ($Name -replace '[^A-Za-z0-9]+', '-').Trim('-')
$zip = Join-Path $out "$safe-$Version.zip"
$mrpack = Join-Path $out "$safe-$Version.mrpack"
if (Test-Path $zip) { Remove-Item -Force $zip }
if (Test-Path $mrpack) { Remove-Item -Force $mrpack }
Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip
Rename-Item $zip $mrpack
Remove-Item -Recurse -Force $work

Write-Host ''
Write-Host "MRPACK: $mrpack  ($([math]::Round((Get-Item $mrpack).Length/1MB,1)) MB)"
Write-Host "linked from Modrinth : $($files.Count)"
Write-Host "bundled in overrides : $($bundled.Count)"
foreach ($b in $bundled) { Write-Host "   - $($b.Name)" }
Write-Host ''
Write-Host 'Bundled jars are shipped inside the pack. Your own mods are fine; for anyone else''s mod'
Write-Host 'either get permission, or drop it and ask players to install it themselves.'
