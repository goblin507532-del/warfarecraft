# Uploads a .mrpack as a new version of an existing Modrinth project.
#
# The project itself has to be created once on the site (modrinth.com -> Create a project -> Modpack),
# because it needs a title, description, licence and goes through their review. After that every update
# is just this script.
#
# Run:  powershell -ExecutionPolicy Bypass -File tools\upload-modrinth.ps1 -Slug warfare-maps-kits
param(
  [Parameter(Mandatory = $true)][string]$Slug,
  [string]$MrPack = '',
  [string]$VersionNumber = '',
  [string]$Changelog = '',
  [string]$GameVersion = '1.21.1',
  [string]$Loader = 'neoforge'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $MrPack) {
  $MrPack = (Get-ChildItem (Join-Path $root 'pack') -Filter *.mrpack | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
if (-not $MrPack -or -not (Test-Path $MrPack)) { throw 'No .mrpack found - run tools\make-mrpack.ps1 first' }
if (-not $VersionNumber) {
  $VersionNumber = [IO.Path]::GetFileNameWithoutExtension($MrPack) -replace '^.*?(\d{4}\.\d{2}\.\d{2}.*)$', '$1'
  if (-not $VersionNumber) { $VersionNumber = Get-Date -Format 'yyyy.MM.dd' }
}

if ($env:MODRINTH_TOKEN) {
  $token = $env:MODRINTH_TOKEN
} else {
  $secure = Read-Host 'Modrinth token (modrinth.com -> Settings -> PATs, scope: create versions)' -AsSecureString
  $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Token is required' }

Add-Type -AssemblyName System.Net.Http

$data = [ordered]@{
  name = "Warfare Maps & Kits $VersionNumber"
  version_number = $VersionNumber
  changelog = $Changelog
  dependencies = @()
  game_versions = @($GameVersion)
  version_type = 'release'
  loaders = @($Loader)
  featured = $true
  project_id = $Slug
  primary_file = 'file'
  file_parts = @('file')
}
$json = $data | ConvertTo-Json -Depth 6 -Compress

$client = New-Object System.Net.Http.HttpClient
$client.DefaultRequestHeaders.Add('Authorization', $token)
$client.DefaultRequestHeaders.Add('User-Agent', 'warfare-hub/1.0 (mrpack uploader)')
$form = New-Object System.Net.Http.MultipartFormDataContent

$dataContent = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
$form.Add($dataContent, 'data')

$bytes = [IO.File]::ReadAllBytes($MrPack)
$fileContent = New-Object System.Net.Http.ByteArrayContent($bytes)
$fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/x-modrinth-modpack+zip')
$form.Add($fileContent, 'file', [IO.Path]::GetFileName($MrPack))

Write-Host "uploading $([IO.Path]::GetFileName($MrPack)) ($([math]::Round($bytes.Length/1MB,1)) MB) to project $Slug ..."
$response = $client.PostAsync('https://api.modrinth.com/v2/version', $form).Result
$text = $response.Content.ReadAsStringAsync().Result
if (-not $response.IsSuccessStatusCode) {
  Write-Host "FAILED $($response.StatusCode)"
  Write-Host $text
  throw 'upload rejected'
}
Write-Host 'OK'
Write-Host "https://modrinth.com/modpack/$Slug/versions"
