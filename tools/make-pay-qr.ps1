# Renders the donate QR code into docs\img\pay-qr.svg.
#
# What goes into the QR, in order of preference:
#   1. -Link  : a personal payment link from your bank app (T-Bank / Sber "мне переводят", Alfa, etc.).
#               This is the only kind of QR that works for payers from ANY bank.
#   2. phone  : falls back to Sberbank's public "transfer by phone" URL, which opens the Sber app prefilled.
#               Payers from other banks should use the phone number shown next to the QR instead.
#
# Run:  powershell -ExecutionPolicy Bypass -File tools\make-pay-qr.ps1
#       powershell -ExecutionPolicy Bypass -File tools\make-pay-qr.ps1 -Link "https://www.tbank.ru/rm/xxxx"
param(
  [string]$Link = '',
  [string]$Phone = '79998929604'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$qrTool = 'C:\Mods\tools\qr'
if (-not (Test-Path (Join-Path $qrTool 'node_modules\qrcode'))) {
  throw "qrcode package missing. Run:  cd $qrTool ; npm install qrcode"
}

$payload = if ($Link) { $Link } else { "https://www.sberbank.com/sms/pbpn?requisiteNumber=$Phone" }
$out = Join-Path $root 'docs\img\pay-qr.svg'
$runner = Join-Path $qrTool 'qr.js'
if (-not (Test-Path $runner)) { throw "missing $runner" }
Push-Location $qrTool
node $runner $payload $out
Pop-Location
if (-not (Test-Path $out)) { throw 'QR was not written' }

Write-Host "payload: $payload"
Write-Host "svg    : $out  ($([math]::Round((Get-Item $out).Length/1KB,1)) KB)"
Write-Host ''
Write-Host 'Put the same value into docs\config.js as payLink so the button and the QR match.'
