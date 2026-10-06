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

# Where the token comes from, in order. The file is the one the launcher already keeps, so a publish started from
# anywhere - a shortcut, a scheduled task, another program - finds it without being asked.
#
# It used to go straight to Read-Host when GH_TOKEN was unset. Run from anywhere without a console to type into,
# that prompt simply waits for ever: the publish looked like it had hung, and nothing had been uploaded at all.
# So the prompt is now the last resort and only when there is genuinely somebody there to answer it.
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

$headers = @{
  Authorization = "Bearer $token"
  Accept = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent' = 'warfare-publish'
}
$api = 'https://api.github.com'

# The sha GitHub reports for a file is a git blob hash: sha1 over "blob <bytes>\0" and then the content. Computing
# it locally is what lets an unchanged file be skipped instead of re-uploaded, which is most of what made a publish
# slow - every file in docs\ went up on every run whether or not a byte of it had changed.
function Get-GitBlobSha($path) {
  $bytes = [IO.File]::ReadAllBytes($path)
  $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
  $all = New-Object byte[] ($header.Length + $bytes.Length)
  [Array]::Copy($header, 0, $all, 0, $header.Length)
  [Array]::Copy($bytes, 0, $all, $header.Length, $bytes.Length)
  $sha1 = [Security.Cryptography.SHA1]::Create()
  try {
    return (($sha1.ComputeHash($all) | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally {
    $sha1.Dispose()
  }
}

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
# The launcher sources stay off it too (his call, 2026-10-02): players need the exe, which is a release asset and is
# published either way, so the repo tree does not have to carry the code. The LICENSE still goes up, so the terms
# are public even though the source is not.
#
# NOTE: the manual's file name is Cyrillic, and Cyrillic inside a .ps1 is read as ANSI and turns to mojibake - a
# literal here would never match, which is exactly how it leaked once. So the rule is ASCII only: in the repo root,
# the ONLY markdown that goes public is README.md. Anything else there is the owner's own notes.
$skip = @('\build\', '\.git\', 'settings.json', '\out\', '\docs\local\', '\docs\pack\', 'admin.html', 'admin.js',
          '.mrpack', 'caddy-access.log', 'STATUS.md', 'token.txt', '\launcher\')
$files = Get-ChildItem $root -Recurse -File | Where-Object {
  $p = $_.FullName
  $rootMarkdown = ($_.DirectoryName -eq $root) -and ($_.Extension -eq '.md') -and ($_.Name -ne 'README.md')
  (-not $rootMarkdown) -and -not ($skip | Where-Object { $p -like "*$_*" })
}
Write-Host "uploading $($files.Count) files"
$same = 0
foreach ($f in $files) {
  $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
  $sha = $null
  try { $sha = (Api GET "$api/repos/$owner/$repo/contents/$rel`?ref=main" $null).sha } catch { $sha = $null }
  if ($sha -and $sha -eq (Get-GitBlobSha $f.FullName)) {
    $same++
    continue
  }
  $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))
  $body = @{ message = "upload $rel"; content = $content; branch = 'main' }
  if ($sha) { $body.sha = $sha }
  try {
    Api PUT "$api/repos/$owner/$repo/contents/$rel" $body | Out-Null
    Write-Host "  + $rel"
  } catch {
    Write-Host "  ! $rel : $($_.Exception.Message)"
  }
}
if ($same -gt 0) { Write-Host "  = $same unchanged, not re-uploaded" }

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
  # An asset already up there at exactly this size is the one we were about to send. The launcher zip is ~50 MB and
  # went up on every run regardless, which on a home upstream is most of the wait - and most of the time the file
  # had not changed at all.
  $existing = (Api GET "$api/repos/$owner/$repo/releases/$($release.id)/assets?per_page=100" $null) |
    Where-Object { $_.name -eq $name }
  if ($existing -and $existing.size -eq (Get-Item $path).Length) {
    Write-Host "  = $name (already up, same size)"
    continue
  }
  foreach ($old in (Api GET "$api/repos/$owner/$repo/releases/$($release.id)/assets?per_page=100" $null)) {
    if ($old.name -eq $name) {
      Api DELETE "$api/repos/$owner/$repo/releases/assets/$($old.id)" $null | Out-Null
    }
  }
  Write-Host "uploading asset $name ..."
  # A 50 MB upload meets a dropped connection often enough to matter - it has cost two runs already. Each attempt
  # clears whatever half-asset the last one left, or GitHub answers 422 for a duplicate instead of accepting it.
  $uploaded = $false
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      $uploadHeaders = $headers.Clone()
      Invoke-RestMethod -Method POST -Headers $uploadHeaders -ContentType 'application/octet-stream' `
        -Uri "https://uploads.github.com/repos/$owner/$repo/releases/$($release.id)/assets?name=$name" `
        -InFile $path | Out-Null
      $uploaded = $true
      break
    } catch {
      Write-Host "  attempt $attempt failed: $($_.Exception.Message)"
      try {
        foreach ($stale in (Api GET "$api/repos/$owner/$repo/releases/$($release.id)/assets?per_page=100" $null)) {
          if ($stale.name -eq $name) { Api DELETE "$api/repos/$owner/$repo/releases/assets/$($stale.id)" $null | Out-Null }
        }
      } catch { }
      if ($attempt -lt 3) { Start-Sleep -Seconds (5 * $attempt) }
    }
  }
  if ($uploaded) { Write-Host "  + $name" } else { Write-Host "  ! $name did not upload" }
}

Write-Host ''
Write-Host "Site:      https://$owner.github.io/$repo/"
Write-Host "Repo:      https://github.com/$owner/$repo"
Write-Host "Launcher:  https://github.com/$owner/$repo/releases/latest/download/WarfareLauncher-win.zip"
Write-Host 'Pages can take a couple of minutes on the first build.'
