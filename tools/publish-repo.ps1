# Creates the GitHub repo (if needed), uploads the site + launcher sources + manifest, turns on GitHub Pages
# and publishes the launcher and the mod jar as release assets. No git and no hosting required.
#
# Run:  powershell -ExecutionPolicy Bypass -File tools\publish-repo.ps1
# Token: a classic PAT with the "repo" scope, or a fine-grained token with Contents+Pages write.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$store = Join-Path $PSScriptRoot 'settings.json'
if (-not (Test-Path $store)) { throw 'Run tools\setup.ps1 first' }
$cfg = Get-Content $store -Raw | ConvertFrom-Json
$owner = $cfg.ghUser
$repo = $cfg.ghRepo

if ($env:GH_TOKEN) {
  $token = $env:GH_TOKEN
} else {
  $secure = Read-Host 'GitHub token (not echoed, not stored)' -AsSecureString
  $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Token is required' }

$headers = @{
  Authorization = "Bearer $token"
  Accept = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent' = 'warfare-publish'
}
$api = 'https://api.github.com'

function Api($method, $url, $body) {
  $args = @{ Method = $method; Uri = $url; Headers = $headers }
  if ($body) {
    $args.Body = ($body | ConvertTo-Json -Depth 6 -Compress)
    $args.ContentType = 'application/json'
  }
  return Invoke-RestMethod @args
}

# ---- repo
$exists = $true
try { Api GET "$api/repos/$owner/$repo" $null | Out-Null } catch { $exists = $false }
if (-not $exists) {
  Write-Host "creating repo $owner/$repo"
  Api POST "$api/user/repos" @{
    name = $repo
    description = 'Warfare Maps and Kits: launcher, modpack manifest and site'
    private = $false
    auto_init = $true
    has_issues = $true
  } | Out-Null
  Start-Sleep -Seconds 3
} else {
  Write-Host "repo $owner/$repo already exists"
}

# ---- files
# The owner's manual stays off the public repo: it is written for him, not for players - his home IP, the admin
# workflow, where the token lives, how the donations are set up. STATUS.md is the same kind of file.
#
# The launcher sources stay off it too (his call, 2026-10-02: "сурсы удали чтобы игроки качали ток exe"). Players
# need the exe, which is a release asset and is published either way - the repo tree does not have to carry the
# code. The LICENSE still goes up, so the terms are public even though the source is not.
$skip = @('\build\', '\.git\', 'settings.json', '\out\', '\docs\local\', '\docs\pack\', 'admin.html', 'admin.js',
          '.mrpack', 'caddy-access.log', 'ИНСТРУКЦИЯ.md', 'STATUS.md', 'token.txt', '\launcher\')
$files = Get-ChildItem $root -Recurse -File | Where-Object {
  $p = $_.FullName
  -not ($skip | Where-Object { $p -like "*$_*" })
}
Write-Host "uploading $($files.Count) files"
foreach ($f in $files) {
  $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
  $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))
  $sha = $null
  try { $sha = (Api GET "$api/repos/$owner/$repo/contents/$rel`?ref=main" $null).sha } catch { $sha = $null }
  $body = @{ message = "upload $rel"; content = $content; branch = 'main' }
  if ($sha) { $body.sha = $sha }
  try {
    Api PUT "$api/repos/$owner/$repo/contents/$rel" $body | Out-Null
    Write-Host "  + $rel"
  } catch {
    Write-Host "  ! $rel : $($_.Exception.Message)"
  }
}

# ---- GitHub Pages from /docs
try {
  Api POST "$api/repos/$owner/$repo/pages" @{ source = @{ branch = 'main'; path = '/docs' } } | Out-Null
  Write-Host 'pages enabled'
} catch {
  try {
    Api PUT "$api/repos/$owner/$repo/pages" @{ source = @{ branch = 'main'; path = '/docs' } } | Out-Null
    Write-Host 'pages updated'
  } catch {
    Write-Host "pages: $($_.Exception.Message) (enable it by hand in Settings -> Pages)"
  }
}

# ---- release with the launcher and the mod
$tag = 'v1'
$release = $null
try { $release = Api GET "$api/repos/$owner/$repo/releases/tags/$tag" $null } catch { $release = $null }
if (-not $release) {
  $release = Api POST "$api/repos/$owner/$repo/releases" @{
    tag_name = $tag
    name = 'Launcher and mod'
    body = 'Launcher (Windows, no Java needed) and the mod jar.'
    draft = $false
    prerelease = $false
  }
  Write-Host "release $tag created"
}

$assets = @(
  'C:\Mods\warfarelauncher\build\WarfareLauncher-win.zip',
  'C:\Mods\warfarelauncher\build\WarfareLauncher.jar'
)
# the mod jar is named after its version, so take whatever the newest build is rather than a number frozen in here
$modJar = Get-ChildItem 'C:\Users\gobli\OneDrive\Desktop\ClaudeMods\jars\warfaremapskits-*.jar' -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($modJar) { $assets += $modJar.FullName }
foreach ($path in $assets) {
  if (-not (Test-Path $path)) { Write-Host "skip (missing): $path"; continue }
  $name = [IO.Path]::GetFileName($path)
  foreach ($old in (Api GET "$api/repos/$owner/$repo/releases/$($release.id)/assets?per_page=100" $null)) {
    if ($old.name -eq $name) {
      Api DELETE "$api/repos/$owner/$repo/releases/assets/$($old.id)" $null | Out-Null
    }
  }
  Write-Host "uploading asset $name ..."
  $uploadHeaders = $headers.Clone()
  Invoke-RestMethod -Method POST -Headers $uploadHeaders -ContentType 'application/octet-stream' `
    -Uri "https://uploads.github.com/repos/$owner/$repo/releases/$($release.id)/assets?name=$name" `
    -InFile $path | Out-Null
  Write-Host "  + $name"
}

Write-Host ''
Write-Host "Site:      https://$owner.github.io/$repo/"
Write-Host "Repo:      https://github.com/$owner/$repo"
Write-Host "Launcher:  https://github.com/$owner/$repo/releases/latest/download/WarfareLauncher-win.zip"
Write-Host 'Pages can take a couple of minutes on the first build.'
