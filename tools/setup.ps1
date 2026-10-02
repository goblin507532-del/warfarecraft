# Fills in the placeholders of the site, the launcher and the manifest.
#
# Run:  powershell -ExecutionPolicy Bypass -File tools\setup.ps1
#         asks for everything, offering what was answered last time
#       powershell -ExecutionPolicy Bypass -File tools\setup.ps1 -GhUser me -GhRepo warfare-hub
#         anything passed as a switch is not asked for; nothing at all is asked when every blank is filled
#
# Values given once are remembered in tools\settings.json, so a later run can change one thing and keep the rest.
param(
  [string]$GhUser,
  [string]$GhRepo,
  [string]$Server,
  [string]$Boosty,
  [string]$Alerts,
  [string]$Direct,
  [string]$Discord,
  [string]$Telegram
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$store = Join-Path $PSScriptRoot 'settings.json'
$old = if (Test-Path $store) { [IO.File]::ReadAllText($store, [Text.Encoding]::UTF8) | ConvertFrom-Json } else { $null }

function Ask($title, $given, $current, $fallback) {
  if (-not [string]::IsNullOrWhiteSpace($given)) { return $given.Trim() }
  $shown = if ($current) { $current } else { $fallback }
  $answer = Read-Host "$title [$shown]"
  if ([string]::IsNullOrWhiteSpace($answer)) { return $shown }
  return $answer.Trim()
}

Write-Host '--- Warfare hub setup ---'
$ghUser  = Ask 'GitHub user'            $GhUser   $old.ghUser  ''
$ghRepo  = Ask 'Repository name'        $GhRepo   $old.ghRepo  'warfare-hub'
$server  = Ask 'Server address'         $Server   $old.server  '26.133.174.202:12345'
$boosty  = Ask 'Donate: Boosty URL'     $Boosty   $old.donateBoosty ''
$alerts  = Ask 'Donate: DonationAlerts' $Alerts   $old.donateAlerts ''
$direct  = Ask 'Donate: direct/other'   $Direct   $old.donateDirect ''
$discord = Ask 'Discord invite'         $Discord  $old.discord ''
$telegram= Ask 'Telegram link'          $Telegram $old.telegram ''

if ([string]::IsNullOrWhiteSpace($ghUser)) { throw 'GitHub user is required' }

$map = [ordered]@{
  '__GH_USER__'        = $ghUser
  '__GH_REPO__'        = $ghRepo
  '__DONATE_BOOSTY__'  = $boosty
  '__DONATE_ALERTS__'  = $alerts
  '__DONATE_DIRECT__'  = $direct
  '__DISCORD__'        = $discord
  '__TELEGRAM__'       = $telegram
}
# A placeholder is replaced once and then it is gone, so a second run had nothing left to patch and a renamed repo
# could never be corrected. Whatever the last run wrote is therefore replaced by the new answer as well.
#
# The nick and the repo are replaced only as part of the URL shapes they appear in, never on their own: a bare
# replace of a short repo name would eat it out of unrelated text as well ("warfare" would turn warfarecraft.ru
# into warfare-hubcraft.ru). The donate links are full URLs, so those are safe to swap whole.
function AddRename($mapRef, $was, $now) {
  if ([string]::IsNullOrWhiteSpace($was)) { return }
  if ($was -eq $now) { return }
  if ($was.Length -lt 8) { return }
  $mapRef[$was] = $now
}
if ($old) {
  $wasUser = if ($old.ghUser) { $old.ghUser } else { '' }
  $wasRepo = if ($old.ghRepo) { $old.ghRepo } else { '' }
  if ($wasUser -and $wasRepo -and ("$wasUser/$wasRepo" -ne "$ghUser/$ghRepo")) {
    $map["$wasUser.github.io/$wasRepo"] = "$ghUser.github.io/$ghRepo"
    $map["github.com/$wasUser/$wasRepo"] = "github.com/$ghUser/$ghRepo"
    $map["githubusercontent.com/$wasUser/$wasRepo"] = "githubusercontent.com/$ghUser/$ghRepo"
  }
  AddRename $map $old.donateBoosty $boosty
  AddRename $map $old.donateAlerts $alerts
  AddRename $map $old.donateDirect $direct
  AddRename $map $old.discord $discord
  AddRename $map $old.telegram $telegram
}
$targets = @(
  (Join-Path $root 'docs\config.js'),
  (Join-Path $root 'docs\index.html'),
  # both copies of the launcher source: the mirror in this repo and the one build.ps1 actually compiles
  (Join-Path $root 'launcher\src\warfare\launcher\Config.java'),
  'C:\Mods\warfarelauncher\src\warfare\launcher\Config.java',
  (Join-Path $root 'docs\pack\manifest.json'),
  (Join-Path $root 'README.md')
)
$enc = New-Object System.Text.UTF8Encoding($false)
foreach ($file in $targets) {
  if (-not (Test-Path $file)) { continue }
  $text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
  $before = $text
  foreach ($k in $map.Keys) { $text = $text.Replace($k, $map[$k]) }
  $text = $text.Replace('26.133.174.202:12345', $server)
  if ($text -ne $before) {
    [IO.File]::WriteAllText($file, $text, $enc)
    Write-Host "patched $([IO.Path]::GetFileName($file))"
  }
}

$settings = [ordered]@{
  ghUser = $ghUser; ghRepo = $ghRepo; server = $server
  donateBoosty = $boosty; donateAlerts = $alerts; donateDirect = $direct
  discord = $discord; telegram = $telegram
}
# UTF8Encoding($false): Out-File -Encoding utf8 writes a BOM, and everything that reads this back parses JSON
[IO.File]::WriteAllText($store, ($settings | ConvertTo-Json), $enc)
Write-Host ''
Write-Host "Site will live at:  https://$ghUser.github.io/$ghRepo/"
Write-Host "Manifest URL:       https://raw.githubusercontent.com/$ghUser/$ghRepo/main/docs/pack/manifest.json"
Write-Host 'Next, in this order:'
Write-Host '  1. C:\Mods\warfarelauncher\build.ps1        rebuild the launcher with your addresses baked in'
Write-Host '  2. tools\make-pack.ps1                      assemble the pack from the test instance'
Write-Host '  3. tools\publish-repo.ps1                   create the repo, put the site and the launcher up'
Write-Host '  4. tools\publish-pack.ps1                   put the pack files up (this is what players download)'
