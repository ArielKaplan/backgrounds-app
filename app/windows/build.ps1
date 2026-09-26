# Builds Backgrounds for Windows into app\windows\build\Backgrounds\ and Backgrounds-windows.zip.
# Needs the .NET SDK (https://dot.net) — the app itself only needs .NET Framework 4.8, which Windows includes.
# Optional overrides (used by the CI update test): -Version 9.9.9 -PublicKey <base64> -Feed <url> -Out <dir>
param([string]$Version = '', [string]$PublicKey = '', [string]$Feed = '', [string]$Out = '')
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$root = Resolve-Path '..\..'
$out = if ($Out) { $Out } else { Join-Path $PSScriptRoot 'build' }
$app = Join-Path $out 'Backgrounds'

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
$props = @()
if ($Version) { $props += "-p:Version=$Version" }
if ($PublicKey) { $props += "-p:UpdatePublicKey=$PublicKey" }
if ($Feed) { $props += "-p:UpdateFeed=$Feed" }
dotnet build Backgrounds.csproj -c Release -o (Join-Path $out 'bin') @props
if ($LASTEXITCODE -ne 0) { throw 'build failed' }

New-Item -ItemType Directory -Force $app | Out-Null
$bin = Join-Path $out 'bin'
foreach ($f in 'Backgrounds.exe', 'Backgrounds.exe.config', 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll', 'settings.html') {
  Copy-Item (Join-Path $bin $f) $app
}
Copy-Item (Join-Path $bin 'runtimes') $app -Recurse

# Built-in wallpapers: every "Wallpaper - X" folder of the repo becomes Wallpapers\X (zips left out).
$wp = Join-Path $app 'Wallpapers'
New-Item -ItemType Directory -Force $wp | Out-Null
Get-ChildItem $root -Directory -Filter 'Wallpaper - *' | ForEach-Object {
  if (Test-Path (Join-Path $_.FullName 'index.html')) {
    $dest = Join-Path $wp ($_.Name -replace '^Wallpaper - ', '')
    New-Item -ItemType Directory -Force $dest | Out-Null
    Get-ChildItem $_.FullName -Exclude '*.zip', '.DS_Store' | Copy-Item -Destination $dest -Recurse
  }
}

# Fingerprints of every shipped version of the built-in wallpapers (lets updates refresh unedited copies).
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if ($py) { & $py.Source (Join-Path $root 'app\release\wallpaper_history.py') $root (Join-Path $app 'wallpaper-history.json') }
else { Write-Host 'python not found: skipping wallpaper-history.json (updates then only refresh wallpapers identical to this build)' }

$zip = Join-Path $out 'Backgrounds-windows.zip'
Compress-Archive -Path $app -DestinationPath $zip
Remove-Item $bin -Recurse -Force
Write-Host "== built $app and $zip"
