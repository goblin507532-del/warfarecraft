# Serves docs\ on localhost (and, with -Public, to everyone) and exposes a small write API for the admin page.
# Pure PowerShell, no node, nothing to install.
#
# Run:   powershell -ExecutionPolicy Bypass -File tools\serve-site.ps1
#        powershell -ExecutionPolicy Bypass -File tools\serve-site.ps1 -Public      # players can reach the pack
# Admin: http://127.0.0.1:8123/admin.html   (only reachable from this machine)
# Stop:  Ctrl+C
param(
  [int]$Port = 8123,
  [switch]$NoBrowser,
  [switch]$Public
)
$ErrorActionPreference = 'Stop'
$hub = Split-Path -Parent $PSScriptRoot
$root = Join-Path $hub 'docs'
if (-not (Test-Path (Join-Path $root 'index.html'))) { throw "No docs\index.html next to $PSScriptRoot" }

$types = @{
  '.html' = 'text/html; charset=utf-8'
  '.css'  = 'text/css; charset=utf-8'
  '.js'   = 'application/javascript; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'
  '.txt'  = 'text/plain; charset=utf-8'
  '.jpg'  = 'image/jpeg'
  '.jpeg' = 'image/jpeg'
  '.png'  = 'image/png'
  '.svg'  = 'image/svg+xml'
  '.ico'  = 'image/x-icon'
  '.webp' = 'image/webp'
  '.mp4'  = 'video/mp4'
  '.jar'  = 'application/java-archive'
  '.woff2'= 'font/woff2'
}
$enc = New-Object System.Text.UTF8Encoding($false)
$imageName = '^(hero|shot-([1-9]|1[0-2]))\.(jpg|jpeg|png|webp)$'

function Send-Bytes($context, $bytes, $contentType, $status = 200) {
  $context.Response.StatusCode = $status
  $context.Response.ContentType = $contentType
  $context.Response.Headers.Add('Cache-Control', 'no-store')
  $context.Response.ContentLength64 = $bytes.Length
  if ($context.Request.HttpMethod -ne 'HEAD') { $context.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
}

function Send-Json($context, $object, $status = 200) {
  $json = if ($object -is [string]) { $object } else { $object | ConvertTo-Json -Depth 8 }
  Send-Bytes $context ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $status
}

function Read-Body($context) {
  $reader = New-Object IO.StreamReader($context.Request.InputStream, [Text.Encoding]::UTF8)
  try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Read-Raw($context) {
  $ms = New-Object IO.MemoryStream
  $context.Request.InputStream.CopyTo($ms)
  return $ms.ToArray()
}

function Run-Tool($script, $arguments = @()) {
  $file = Join-Path $PSScriptRoot $script
  $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file) + $arguments
  $out = & powershell @all 2>&1 | Out-String
  return $out.Trim()
}

$listener = New-Object System.Net.HttpListener
$prefix = if ($Public) { "http://+:$Port/" } else { "http://127.0.0.1:$Port/" }
$listener.Prefixes.Add($prefix)
try {
  $listener.Start()
} catch {
  if ($Public) {
    Write-Host ''
    Write-Host 'Listening on every interface needs a one-time permission. In an ADMIN PowerShell run:' -ForegroundColor Yellow
    Write-Host "  netsh http add urlacl url=http://+:$Port/ user=Everyone" -ForegroundColor Yellow
    Write-Host "  New-NetFirewallRule -DisplayName `"Warfare pack $Port`" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow" -ForegroundColor Yellow
    Write-Host ''
  }
  throw "Cannot listen on $prefix : $($_.Exception.Message)"
}

Write-Host ''
Write-Host '  WARFARE SITE' -ForegroundColor Yellow
Write-Host "  serving : $root"
Write-Host "  site    : http://127.0.0.1:$Port/" -ForegroundColor Green
Write-Host "  admin   : http://127.0.0.1:$Port/admin.html" -ForegroundColor Green
if ($Public) {
  try {
    $ip = (Invoke-RestMethod 'https://api.ipify.org?format=json' -TimeoutSec 8).ip
    Write-Host "  players : http://${ip}:$Port/pack/manifest.json  (needs port $Port forwarded)"
  } catch { }
  $lan = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' } | Select-Object -First 1).IPAddress
  if ($lan) { Write-Host "  LAN     : http://${lan}:$Port/pack/manifest.json" }
  Write-Host '  admin API stays closed to everyone but this machine' -ForegroundColor DarkGray
}
Write-Host '  stop    : Ctrl+C'
Write-Host ''
if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$Port/" | Out-Null }

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    # one bad request must never take the server down - the launcher pulls hundreds of files through it
    try {
      $path = [Uri]::UnescapeDataString($context.Request.Url.AbsolutePath)
      $method = $context.Request.HttpMethod
      $query = $context.Request.QueryString
      $local = $context.Request.IsLocal

      if ($path -like '/api/*') {
        if (-not $local) {
          Send-Json $context @{ ok = $false; error = 'admin API is local only' } 403
          Write-Host "  403  $path (remote)" -ForegroundColor DarkYellow
        } else {
          switch -Regex ($path) {
            '^/api/state$' {
              $state = @{ ok = $true }
              foreach ($n in 'funding', 'site', 'version') {
                $f = Join-Path $root "$n.json"
                $state[$n] = if (Test-Path $f) { [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json } else { $null }
              }
              $imgs = @()
              if (Test-Path (Join-Path $root 'img')) {
                $imgs = Get-ChildItem (Join-Path $root 'img') -File | Where-Object { $_.Name -match $imageName } |
                  ForEach-Object { @{ name = $_.Name; size = $_.Length } }
              }
              $state['images'] = $imgs
              $notes = Join-Path $root 'pack\notes.txt'
              $state['packNotes'] = if (Test-Path $notes) { [IO.File]::ReadAllText($notes, [Text.Encoding]::UTF8) } else { '' }
              Send-Json $context $state
              Write-Host "  200  $path"
            }
            '^/api/(funding|site)$' {
              $name = $Matches[1]
              $body = Read-Body $context
              try { $null = $body | ConvertFrom-Json } catch { Send-Json $context @{ ok = $false; error = 'bad json' } 400; break }
              [IO.File]::WriteAllText((Join-Path $root "$name.json"), $body, $enc)
              Send-Json $context @{ ok = $true; saved = "$name.json" }
              Write-Host "  200  $path (saved)" -ForegroundColor Green
            }
            '^/api/notes$' {
              $body = Read-Body $context
              New-Item -ItemType Directory -Force (Join-Path $root 'pack') | Out-Null
              [IO.File]::WriteAllText((Join-Path $root 'pack\notes.txt'), $body, $enc)
              Send-Json $context @{ ok = $true }
              Write-Host "  200  $path (saved)" -ForegroundColor Green
            }
            '^/api/upload$' {
              $name = $query['name']
              if (-not $name -or $name -notmatch $imageName) {
                Send-Json $context @{ ok = $false; error = 'name must be hero.jpg or shot-1..12 with jpg/png/webp' } 400
                break
              }
              $bytes = Read-Raw $context
              if ($bytes.Length -lt 100) { Send-Json $context @{ ok = $false; error = 'empty file' } 400; break }
              if ($bytes.Length -gt 12MB) { Send-Json $context @{ ok = $false; error = 'file over 12 MB' } 400; break }
              New-Item -ItemType Directory -Force (Join-Path $root 'img') | Out-Null
              [IO.File]::WriteAllBytes((Join-Path $root "img\$name"), $bytes)
              Send-Json $context @{ ok = $true; name = $name; size = $bytes.Length }
              Write-Host "  200  $path -> $name ($([math]::Round($bytes.Length/1KB)) KB)" -ForegroundColor Green
            }
            '^/api/delete$' {
              $name = $query['name']
              if (-not $name -or $name -notmatch $imageName) { Send-Json $context @{ ok = $false; error = 'bad name' } 400; break }
              Remove-Item (Join-Path $root "img\$name") -Force -ErrorAction SilentlyContinue
              Send-Json $context @{ ok = $true }
              Write-Host "  200  $path -> $name removed" -ForegroundColor Green
            }
            '^/api/pack$' {
              Write-Host '  ...  rebuilding the pack' -ForegroundColor Yellow
              $out = Run-Tool 'make-pack.ps1'
              Send-Json $context @{ ok = $true; output = $out }
              Write-Host "  200  $path (done)" -ForegroundColor Green
            }
            '^/api/qr$' {
              $link = $query['link']
              $args = @()
              if ($link) { $args = @('-Link', $link) }
              $out = Run-Tool 'make-pay-qr.ps1' $args
              Send-Json $context @{ ok = $true; output = $out }
              Write-Host "  200  $path (qr)" -ForegroundColor Green
            }
            default {
              Send-Json $context @{ ok = $false; error = 'unknown endpoint' } 404
            }
          }
        }
      } else {
        if ($path -eq '/') { $path = '/index.html' }
        # the admin page is for this machine only
        if (($path -like '/admin*') -and -not $local) {
          Send-Bytes $context ([Text.Encoding]::UTF8.GetBytes('403')) 'text/plain; charset=utf-8' 403
          Write-Host "  403  $path (remote)" -ForegroundColor DarkYellow
        } else {
          $file = Join-Path $root ($path.TrimStart('/') -replace '/', '\')
          $full = [IO.Path]::GetFullPath($file)
          $safe = $full.StartsWith([IO.Path]::GetFullPath($root), [StringComparison]::OrdinalIgnoreCase)
          if ($safe -and (Test-Path $full -PathType Leaf)) {
            $info = Get-Item $full
            $ext = $info.Extension.ToLower()
            $context.Response.ContentType = if ($types.ContainsKey($ext)) { $types[$ext] } else { 'application/octet-stream' }
            $context.Response.Headers.Add('Cache-Control', 'no-store')
            $context.Response.ContentLength64 = $info.Length
            if ($method -ne 'HEAD') {
              # streamed, so a 60 MB mod doesn't have to sit in memory first
              $stream = [IO.File]::OpenRead($full)
              try { $stream.CopyTo($context.Response.OutputStream, 131072) } finally { $stream.Dispose() }
            }
            Write-Host "  200  $path"
          } else {
            Send-Bytes $context ([Text.Encoding]::UTF8.GetBytes('404')) 'text/plain; charset=utf-8' 404
            Write-Host "  404  $path" -ForegroundColor DarkGray
          }
        }
      }
    } catch {
      Write-Host ("  ERR  " + $_.Exception.Message) -ForegroundColor DarkYellow
    } finally {
      try { $context.Response.OutputStream.Close() } catch {}
    }
  }
} finally {
  $listener.Stop()
  $listener.Close()
  Write-Host 'stopped'
}
