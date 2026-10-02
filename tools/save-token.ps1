# Stores the GitHub token for the admin build of the launcher, so the "publish update" button works.
# The token is written to %APPDATA%\WarfareLauncher\token.txt and never goes anywhere but api.github.com.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:APPDATA 'WarfareLauncher'
New-Item -ItemType Directory -Force $dir | Out-Null
$file = Join-Path $dir 'token.txt'
$secure = Read-Host 'GitHub token (not echoed)' -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
if ([string]::IsNullOrWhiteSpace($plain)) { throw 'Token is empty' }
[IO.File]::WriteAllText($file, $plain.Trim(), (New-Object System.Text.UTF8Encoding($false)))
# keep it readable only by the current user
icacls $file /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
Write-Host "Saved: $file"
Write-Host 'The launcher shows the ADMIN tab when this file exists. Delete it to hand the launcher to players.'
