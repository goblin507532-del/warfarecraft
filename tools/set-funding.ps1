# Updates the numbers in the "Сборы и планы" block (docs\funding.json). Anything you don't pass stays as it is.
#
# Examples:
#   tools\set-funding.ps1 -Raised 1500
#   tools\set-funding.ps1 -Raised 2200 -PatchPercent 85
#   tools\set-funding.ps1 -HostDays 20                 # hosting paid for 20 more days from today
#   tools\set-funding.ps1 -HostUntil 2026-10-13 -PatchDate 2026-10-05
param(
  [int]$Raised = -1,
  [int]$Goal = -1,
  [int]$PatchPercent = -1,
  [string]$PatchDate = '',
  [string]$HostUntil = '',
  [int]$HostDays = -1,
  [int]$HostPeriodDays = -1,
  [string]$GoalNote = '',
  [string]$PatchNote = ''
)
$ErrorActionPreference = 'Stop'
$file = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\funding.json'
if (-not (Test-Path $file)) { throw "not found: $file" }
$json = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json

if ($Raised -ge 0) { $json.raised = $Raised }
if ($Goal -gt 0) { $json.goal = $Goal }
if ($PatchPercent -ge 0) { $json.patchPercent = [Math]::Min(100, $PatchPercent) }
if ($PatchDate) { $json.patchDate = $PatchDate }
if ($HostUntil) { $json.hostPaidUntil = $HostUntil }
if ($HostDays -ge 0) { $json.hostPaidUntil = (Get-Date).AddDays($HostDays).ToString('yyyy-MM-dd') }
if ($HostPeriodDays -gt 0) { $json.hostPeriodDays = $HostPeriodDays }
if ($GoalNote) { $json.goalNote = $GoalNote }
if ($PatchNote) { $json.patchNote = $PatchNote }
$json.updated = (Get-Date).ToString('yyyy-MM-dd')

$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($file, ($json | ConvertTo-Json -Depth 4), $enc)

$daysLeft = [Math]::Max(0, [Math]::Ceiling(([datetime]$json.hostPaidUntil - (Get-Date)).TotalDays))
Write-Host ''
Write-Host "raised      : $($json.raised) / $($json.goal)"
Write-Host "patch       : $($json.patchPercent)%  -> $($json.patchDate)"
Write-Host "hosting     : until $($json.hostPaidUntil)  ($daysLeft days left)"
Write-Host "updated     : $($json.updated)"
Write-Host ''
Write-Host 'The site picks it up on reload. If the site is published on GitHub, run tools\publish-repo.ps1 to push it.'
