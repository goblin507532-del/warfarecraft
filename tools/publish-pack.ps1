# Publishes the whole modpack to GitHub so the launcher can install it without this PC being on.
#
# How it works: every pack file goes up as a release asset named after its own sha256 ("<hash>.bin"), and the
# manifest in the repo points at those assets by absolute URL. Content-addressed names mean:
#   - a file that did not change is already up there, so it is never uploaded twice;
#   - two identical files share one asset;
#   - names with spaces or Cyrillic cannot break anything, because the asset name is pure hex.
# A later run uploads only what is new, so a mod bump costs one small upload instead of 375 MB.
#
# Run:  powershell -ExecutionPolicy Bypass -File tools\publish-pack.ps1
#       powershell -ExecutionPolicy Bypass -File tools\publish-pack.ps1 -Prune    (also delete orphan assets)
#       powershell -ExecutionPolicy Bypass -File tools\publish-pack.ps1 -DryRun   (check the plan, no token, no network)
#
# Token: a classic PAT with the "repo" scope, or a fine-grained token with Contents write.
# Set GH_TOKEN to skip the prompt.  Order: tools\make-pack.ps1 first, then this.
param(
  [switch]$Prune,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$store = Join-Path $PSScriptRoot 'settings.json'
if (-not (Test-Path $store)) { throw 'Run tools\setup.ps1 first (it asks for your GitHub user and repo)' }
$cfg = [IO.File]::ReadAllText($store, [Text.Encoding]::UTF8) | ConvertFrom-Json
$owner = $cfg.ghUser
$repo = $cfg.ghRepo
if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repo)) { throw 'settings.json has no ghUser/ghRepo' }

$packDir = Join-Path $root 'docs\pack'
$filesDir = Join-Path $packDir 'files'
$manifestPath = Join-Path $packDir 'manifest.json'
if (-not (Test-Path $manifestPath)) { throw "No manifest at $manifestPath - run tools\make-pack.ps1 first" }

$tag = 'pack'
$enc = New-Object System.Text.UTF8Encoding($false)
$curl = Join-Path $env:WINDIR 'System32\curl.exe'
if (-not (Test-Path $curl)) { throw "curl.exe not found at $curl" }

# a dry run is a local check of the plan: no token asked for, nothing sent anywhere
$token = ''
if (-not $DryRun) {
  if ($env:GH_TOKEN) {
    $token = $env:GH_TOKEN
  } else {
    $secure = Read-Host 'GitHub token (not echoed, not stored)' -AsSecureString
    $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  }
  if ([string]::IsNullOrWhiteSpace($token)) { throw 'Token is required' }
}

$headers = @{
  Authorization = "Bearer $token"
  Accept = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent' = 'warfare-publish-pack'
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

# ---- the manifest make-pack.ps1 built (paths, hashes and sizes are already in it)
$manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$entries = @($manifest.files)
if ($entries.Count -eq 0) { throw 'The manifest has no files in it' }
$totalBytes = 0
foreach ($e in $entries) { $totalBytes += [int64]$e.size }
Write-Host "pack $($manifest.version): $($entries.Count) files, $([math]::Round($totalBytes/1MB,1)) MB"

foreach ($e in $entries) {
  if ([string]::IsNullOrWhiteSpace($e.sha256)) { throw "Entry without a hash: $($e.path) - rebuild with tools\make-pack.ps1" }
}

$release = $null
$have = @{}
if ($DryRun) {
  Write-Host "dry run: assuming the release is empty, nothing is sent"
} else {
  # ---- the repo has to exist; this script does not create it (publish-repo.ps1 does)
  try { Api GET "$api/repos/$owner/$repo" $null | Out-Null } catch {
    throw "No repo $owner/$repo - run tools\publish-repo.ps1 first (it creates it and puts the site up)"
  }

  # ---- one long-lived release holds the pack; assets accumulate across versions
  try { $release = Api GET "$api/repos/$owner/$repo/releases/tags/$tag" $null } catch { $release = $null }
  if (-not $release) {
    $release = Api POST "$api/repos/$owner/$repo/releases" @{
      tag_name = $tag
      name = 'Modpack files'
      body = 'Pack files, one asset per file, named by sha256. The launcher reads docs/pack/manifest.json and pulls what it is missing.'
      draft = $false
      prerelease = $false
    }
    Write-Host "release '$tag' created"
  }

  # ---- what is up there already (paginated: a full pack is several hundred assets)
  $page = 1
  while ($true) {
    $batch = @(Api GET "$api/repos/$owner/$repo/releases/$($release.id)/assets?per_page=100&page=$page" $null)
    if ($batch.Count -eq 0) { break }
    foreach ($a in $batch) { $have[$a.name] = $a.id }
    if ($batch.Count -lt 100) { break }
    $page++
  }
  Write-Host "already on the release: $($have.Count) assets"
}

# ---- upload what is missing, one asset per distinct hash
$wanted = @{}
foreach ($e in $entries) {
  $name = "$($e.sha256.ToLower()).bin"
  if (-not $wanted.ContainsKey($name)) { $wanted[$name] = $e }
}
$missing = @()
foreach ($name in $wanted.Keys) {
  if (-not $have.ContainsKey($name)) { $missing += $name }
}
$missingBytes = 0
foreach ($name in $missing) { $missingBytes += [int64]$wanted[$name].size }
Write-Host "to upload: $($missing.Count) of $($wanted.Count) assets, $([math]::Round($missingBytes/1MB,1)) MB"

if ($DryRun) {
  # the one thing worth checking offline: that every file the manifest names is really on disk
  $bad = 0
  foreach ($name in $missing) {
    $entry = $wanted[$name]
    $file = Join-Path $filesDir ($entry.path.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $file)) {
      Write-Host "  MISSING ON DISK: $($entry.path)"
      $bad++
    }
  }
  if ($bad -eq 0) {
    Write-Host "  all $($missing.Count) files found on disk, ready to upload"
  } else {
    throw "$bad files in the manifest are not on disk - rerun tools\make-pack.ps1"
  }
} elseif ($missing.Count -gt 0) {
  # the token goes in a curl config file, not on the command line, so it stays out of the process list
  $curlCfg = Join-Path $env:TEMP ("warfare-upload-" + [guid]::NewGuid().ToString('N') + ".cfg")
  $lines = @(
    'silent',
    'show-error',
    'fail',
    'retry = 3',
    'retry-delay = 2',
    'request = POST',
    ('header = "Authorization: Bearer ' + $token + '"'),
    'header = "Accept: application/vnd.github+json"',
    'header = "X-GitHub-Api-Version: 2022-11-28"',
    'header = "Content-Type: application/octet-stream"',
    'user-agent = "warfare-publish-pack"'
  )
  [IO.File]::WriteAllLines($curlCfg, $lines, $enc)
  try {
    $n = 0
    $sentBytes = 0
    foreach ($name in $missing) {
      $entry = $wanted[$name]
      # "path" is the plain instance-relative name; "url" is percent-encoded and is not a file name
      $file = Join-Path $filesDir ($entry.path.Replace('/', '\'))
      if (-not (Test-Path -LiteralPath $file)) { throw "Missing local file for $($entry.path): $file" }
      $n++
      $mb = [math]::Round(((Get-Item -LiteralPath $file).Length)/1MB, 1)
      Write-Host "[$n/$($missing.Count)] $($entry.path)  ($mb MB)"
      $url = "https://uploads.github.com/repos/$owner/$repo/releases/$($release.id)/assets?name=$name"
      & $curl --config $curlCfg --data-binary "@$file" --output NUL $url
      if ($LASTEXITCODE -ne 0) { throw "Upload failed for $($entry.path) (curl exit $LASTEXITCODE)" }
      $sentBytes += [int64]$entry.size
    }
    Write-Host "uploaded $([math]::Round($sentBytes/1MB,1)) MB"
  } finally {
    Remove-Item -LiteralPath $curlCfg -Force -ErrorAction SilentlyContinue
  }
}

# ---- assets no version refers to any more
$orphans = @()
foreach ($name in $have.Keys) {
  if (-not $wanted.ContainsKey($name)) { $orphans += $name }
}
if ($orphans.Count -gt 0) {
  if ($Prune -and -not $DryRun) {
    foreach ($name in $orphans) {
      Api DELETE "$api/repos/$owner/$repo/releases/assets/$($have[$name])" $null | Out-Null
      Write-Host "  - $name"
    }
    Write-Host "pruned $($orphans.Count) orphan assets"
  } else {
    Write-Host "$($orphans.Count) orphan assets left in place (run with -Prune to delete; they let an older launcher still install)"
  }
}

# ---- the manifest players read: same pack, absolute asset URLs
$base = "https://github.com/$owner/$repo/releases/download/$tag"
$ghFiles = @()
foreach ($e in $entries) {
  $ghFiles += [ordered]@{
    path = $e.path
    url = "$base/$($e.sha256.ToLower()).bin"
    sha256 = $e.sha256
    size = $e.size
  }
}
$ghManifest = [ordered]@{
  name = $manifest.name
  version = $manifest.version
  mcVersion = $manifest.mcVersion
  loader = $manifest.loader
  loaderVersion = $manifest.loaderVersion
  serverAddress = $manifest.serverAddress
  notes = $manifest.notes
  files = $ghFiles
}
$ghPath = Join-Path $packDir 'manifest-github.json'
$ghJson = $ghManifest | ConvertTo-Json -Depth 6
if ($DryRun) {
  Write-Host "would write $ghPath and put it in the repo at docs/pack/manifest.json"
  Write-Host "  example url: $($ghFiles[0].url)"
} else {
  [IO.File]::WriteAllText($ghPath, $ghJson, $enc)
  Write-Host "wrote $ghPath"

  # into the repo as docs/pack/manifest.json - publish-repo.ps1 skips docs\pack\, so nothing fights over it
  $repoPath = 'docs/pack/manifest.json'
  $content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ghJson))
  $sha = $null
  try { $sha = (Api GET "$api/repos/$owner/$repo/contents/$repoPath`?ref=main" $null).sha } catch { $sha = $null }
  $body = @{ message = "pack $($manifest.version)"; content = $content; branch = 'main' }
  if ($sha) { $body.sha = $sha }
  Api PUT "$api/repos/$owner/$repo/contents/$repoPath" $body | Out-Null
  Write-Host "manifest published to the repo"
}

Write-Host ''
Write-Host 'Players get the pack from:'
Write-Host "  https://raw.githubusercontent.com/$owner/$repo/main/docs/pack/manifest.json"
Write-Host "  https://$owner.github.io/$repo/pack/manifest.json   (same file, once Pages has built)"
Write-Host 'Both are already built into the launcher, so a fresh install needs nothing typed in.'
