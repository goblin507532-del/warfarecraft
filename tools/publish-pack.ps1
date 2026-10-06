# Publishes the whole modpack to GitHub so the launcher can install it without this PC being on.
#
# How it works: every pack file goes up as a release asset named after its own sha256 ("<hash>.bin"), and the
# manifest in the repo points at those assets by absolute URL. Content-addressed names mean:
#   - a file that did not change is already up there, so it is never uploaded twice;
#   - two identical files share one asset;
#   - names with spaces or Cyrillic cannot break anything, because the asset name is pure hex.
# A later run uploads only what is new, so a mod bump costs one small upload instead of 450 MB.
#
# SHARDS: GitHub allows at most 1000 assets per release ("file_count limited to 1000 assets per release"), and the
# pack is larger than that, so the assets are spread over several releases - "pack", "pack-2", "pack-3" and so on,
# each filled to SHARD_LIMIT. Which shard a file sits on does not matter to anybody: the manifest carries the full
# URL per file, so the launcher never has to work it out. An asset already uploaded is left exactly where it is.
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

# GitHub's ceiling is 1000; stop a little short so a half-finished retry can never wedge a shard
$SHARD_LIMIT = 980
$MAX_SHARDS = 40
$enc = New-Object System.Text.UTF8Encoding($false)
$curl = Join-Path $env:WINDIR 'System32\curl.exe'
if (-not (Test-Path $curl)) { throw "curl.exe not found at $curl" }

# a dry run is a local check of the plan: no token asked for, nothing sent anywhere
$token = ''
if (-not $DryRun) {
  # Same order as publish-repo.ps1, and for the same reason: an unanswerable Read-Host looks exactly like a hung
  # upload, and this script is the slow one, so it is the one where that mistake costs the most.
  $tokenFile = Join-Path $env:APPDATA 'WarfareLauncher\token.txt'
  if ($env:GH_TOKEN) {
    $token = $env:GH_TOKEN
  } elseif (Test-Path $tokenFile) {
    $token = ([IO.File]::ReadAllText($tokenFile)).Trim()
    Write-Host "token: $tokenFile"
  } elseif ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    $secure = Read-Host 'GitHub token (not echoed, not stored)' -AsSecureString
    $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  } else {
    throw "No token: set GH_TOKEN or put the PAT in $tokenFile"
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

function ShardTag($index) {
  if ($index -le 1) { return 'pack' }
  return "pack-$index"
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

# Zero-byte files are not uploaded: GitHub answers 422 for an empty asset. The launcher creates those locally
# instead (Pack.apply), so the pack still gets the file - there is simply nothing to store for it.
$wanted = @{}
$empties = 0
foreach ($e in $entries) {
  if ([int64]$e.size -eq 0) { $empties++; continue }
  $name = "$($e.sha256.ToLower()).bin"
  if (-not $wanted.ContainsKey($name)) { $wanted[$name] = $e }
}
if ($empties -gt 0) { Write-Host "empty files, created by the launcher rather than uploaded: $empties" }

# ---- where every asset already lives, shard by shard
$where = @{}        # asset name -> shard tag
$assetId = @{}      # asset name -> asset id (for pruning)
$counts = @{}       # shard tag -> how many assets it holds
$releaseIds = @{}   # shard tag -> release id

if ($DryRun) {
  Write-Host 'dry run: assuming every shard is empty, nothing is sent'
} else {
  try { Api GET "$api/repos/$owner/$repo" $null | Out-Null } catch {
    throw "No repo $owner/$repo - run tools\publish-repo.ps1 first (it creates it and puts the site up)"
  }
  for ($i = 1; $i -le $MAX_SHARDS; $i++) {
    $tag = ShardTag $i
    $rel = $null
    try { $rel = Api GET "$api/repos/$owner/$repo/releases/tags/$tag" $null } catch { $rel = $null }
    if (-not $rel) { break }   # shards are filled in order, so the first gap is the end
    $releaseIds[$tag] = $rel.id
    $counts[$tag] = 0
    $page = 1
    while ($true) {
      # An empty page comes back as $null, and @($null) is an array of ONE null in PowerShell - without the filter
      # that null reaches a hashtable key as $null and the run dies on the first, empty release.
      $batch = @((Api GET "$api/repos/$owner/$repo/releases/$($rel.id)/assets?per_page=100&page=$page" $null) |
        Where-Object { $null -ne $_ })
      if ($batch.Count -eq 0) { break }
      foreach ($a in $batch) {
        $where[$a.name] = $tag
        $assetId[$a.name] = $a.id
        $counts[$tag] = $counts[$tag] + 1
      }
      if ($batch.Count -lt 100) { break }
      $page++
    }
    Write-Host "  shard $tag : $($counts[$tag]) assets"
  }
  Write-Host "already uploaded: $($where.Count) assets across $($releaseIds.Count) shard(s)"
}

# ---- what still has to go up
$missing = @()
foreach ($name in $wanted.Keys) {
  if (-not $where.ContainsKey($name)) { $missing += $name }
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
    $shardsNeeded = [math]::Ceiling($wanted.Count / $SHARD_LIMIT)
    Write-Host "  all $($missing.Count) files found on disk, ready to upload"
    Write-Host "  they will fill $shardsNeeded shard(s) of at most $SHARD_LIMIT assets"
  } else {
    throw "$bad files in the manifest are not on disk - rerun tools\make-pack.ps1"
  }
} elseif ($missing.Count -gt 0) {
  # retry-all-errors is the point: plain --retry does NOT retry a DNS failure (curl 6), and one blip in the middle
  # of hundreds of uploads used to throw the whole run away
  $curlCfg = Join-Path $env:TEMP ("warfare-upload-" + [guid]::NewGuid().ToString('N') + ".cfg")
  $lines = @(
    'silent',
    'show-error',
    'fail',
    'retry = 5',
    'retry-delay = 3',
    'retry-all-errors',
    'connect-timeout = 30',
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
    $shardIndex = 1
    foreach ($name in $missing) {
      $entry = $wanted[$name]
      # "path" is the plain instance-relative name; "url" is percent-encoded and is not a file name
      $file = Join-Path $filesDir ($entry.path.Replace('/', '\'))
      if (-not (Test-Path -LiteralPath $file)) { throw "Missing local file for $($entry.path): $file" }

      # find a shard with room, making the next one when they are all full
      while ($true) {
        if ($shardIndex -gt $MAX_SHARDS) { throw "Out of shards - raise MAX_SHARDS" }
        $tag = ShardTag $shardIndex
        if (-not $releaseIds.ContainsKey($tag)) {
          # prerelease on purpose: these are file stores, and GitHub's "latest" ignores prereleases, so the
          # player's /releases/latest/download/WarfareLauncher-win.zip link keeps pointing at v1
          $made = Api POST "$api/repos/$owner/$repo/releases" @{
            tag_name = $tag
            name = "Modpack files ($tag)"
            body = 'Pack files, one asset per file, named by sha256. GitHub allows 1000 assets per release, so the pack is split over several of these. The launcher reads docs/pack/manifest.json, which carries the full URL of every file.'
            draft = $false
            prerelease = $true
            make_latest = 'false'
          }
          $releaseIds[$tag] = $made.id
          $counts[$tag] = 0
          Write-Host "shard $tag created"
        }
        if ($counts[$tag] -lt $SHARD_LIMIT) { break }
        $shardIndex++
      }
      $tag = ShardTag $shardIndex

      $n++
      $mb = [math]::Round(((Get-Item -LiteralPath $file).Length)/1MB, 1)
      Write-Host "[$n/$($missing.Count)] $($entry.path)  ($mb MB) -> $tag"
      $url = "https://uploads.github.com/repos/$owner/$repo/releases/$($releaseIds[$tag])/assets?name=$name"
      $ok = $false
      for ($attempt = 1; $attempt -le 3; $attempt++) {
        & $curl --config $curlCfg --data-binary "@$file" --output NUL $url
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
        if ($attempt -lt 3) { Write-Host "    attempt $attempt failed (curl exit $LASTEXITCODE), retrying" }
        # a half-finished attempt can leave an asset under this name, and then the retry gets 422 for a
        # duplicate instead of uploading - so clear it first, ignoring whatever that says
        try {
          $page = 1
          while ($true) {
            $batch = @((Api GET "$api/repos/$owner/$repo/releases/$($releaseIds[$tag])/assets?per_page=100&page=$page" $null) |
              Where-Object { $null -ne $_ })
            if ($batch.Count -eq 0) { break }
            foreach ($a in $batch) {
              if ($a.name -eq $name) { Api DELETE "$api/repos/$owner/$repo/releases/assets/$($a.id)" $null | Out-Null }
            }
            if ($batch.Count -lt 100) { break }
            $page++
          }
        } catch { }
        if ($attempt -lt 3) { Start-Sleep -Seconds (5 * $attempt) }
      }
      if (-not $ok) { throw "Upload failed for $($entry.path) after 3 attempts - rerun, it resumes where it stopped" }
      $where[$name] = $tag
      $counts[$tag] = $counts[$tag] + 1
      $sentBytes += [int64]$entry.size
    }
    Write-Host "uploaded $([math]::Round($sentBytes/1MB,1)) MB"
  } finally {
    Remove-Item -LiteralPath $curlCfg -Force -ErrorAction SilentlyContinue
  }
}

# ---- assets no version refers to any more
$orphans = @()
foreach ($name in $where.Keys) {
  if (-not $wanted.ContainsKey($name)) { $orphans += $name }
}
if ($orphans.Count -gt 0) {
  if ($Prune -and -not $DryRun) {
    foreach ($name in $orphans) {
      if ($assetId.ContainsKey($name)) {
        Api DELETE "$api/repos/$owner/$repo/releases/assets/$($assetId[$name])" $null | Out-Null
        Write-Host "  - $name"
      }
    }
    Write-Host "pruned $($orphans.Count) orphan assets"
  } else {
    Write-Host "$($orphans.Count) orphan assets left in place (run with -Prune to delete; they let an older launcher still install)"
  }
}

# ---- the manifest players read: same pack, absolute asset URLs
$ghFiles = @()
foreach ($e in $entries) {
  # an empty file has no asset, so it gets no url - the launcher makes it from nothing
  $entryUrl = ''
  if ([int64]$e.size -ne 0) {
    $name = "$($e.sha256.ToLower()).bin"
    $tag = 'pack'
    if ($where.ContainsKey($name)) { $tag = $where[$name] }
    $entryUrl = "https://github.com/$owner/$repo/releases/download/$tag/$name"
  }
  $ghFiles += [ordered]@{
    path = $e.path
    url = $entryUrl
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
