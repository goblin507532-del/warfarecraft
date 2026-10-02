# Serves the site on the real domain from this PC, with automatic HTTPS (Caddy + Let's Encrypt).
#
# Before it can work:
#   1. the domain's A record must point at this PC's public IP (printed below);
#   2. ports 80 and 443 must be forwarded to this PC in the router;
#   3. the provider must not block inbound 80/443 (many home tariffs do - then a VPS or Cloudflare Tunnel is needed).
#
# Run:  powershell -ExecutionPolicy Bypass -File tools\serve-domain.ps1
# Stop: Ctrl+C
param(
  [string]$Caddy = 'C:\Mods\tools\caddy\caddy.exe',
  [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$caddyfile = Join-Path $root 'Caddyfile'
if (-not (Test-Path $Caddy)) { throw "Caddy not found at $Caddy" }
if (-not (Test-Path $caddyfile)) { throw "Caddyfile not found at $caddyfile" }

Write-Host ''
Write-Host '  WARFARE SITE / public' -ForegroundColor Yellow

# what the world sees as this machine
try {
  $ip = (Invoke-RestMethod 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
  Write-Host "  public IP  : $ip" -ForegroundColor Green
  Write-Host "  DNS record : A  warfarecraft.ru  ->  $ip     (and A for www)"
} catch {
  Write-Host '  public IP  : could not be detected (no internet?)' -ForegroundColor DarkYellow
}

# local ports
foreach ($port in 80, 443) {
  $busy = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($busy) {
    $proc = (Get-Process -Id $busy[0].OwningProcess -ErrorAction SilentlyContinue).ProcessName
    Write-Host "  port $port    : BUSY (taken by $proc) - free it or Caddy won't start" -ForegroundColor Red
  } else {
    Write-Host "  port $port    : free"
  }
}

# does the domain already resolve here
try {
  $dns = Resolve-DnsName 'warfarecraft.ru' -Type A -ErrorAction Stop | Where-Object { $_.IPAddress }
  Write-Host "  warfarecraft.ru -> $($dns.IPAddress -join ', ')"
} catch {
  Write-Host '  warfarecraft.ru: no A record yet (buy the domain and point it here first)' -ForegroundColor DarkYellow
}
Write-Host ''
if ($CheckOnly) { return }

Write-Host '  starting Caddy (Ctrl+C to stop). First run asks the firewall for permission.' -ForegroundColor Green
Write-Host ''
& $Caddy run --config $caddyfile --adapter caddyfile
