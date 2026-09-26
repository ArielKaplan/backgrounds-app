# CI end-to-end update test on a real Windows desktop. Builds "old" 0.9.0 and "new" 99.0.0 with a throwaway key,
# serves the update from localhost, and checks that the app refuses a badly signed update, then installs a good one
# by itself (swapping its files in place and restarting), refreshing unedited built-in wallpapers only.
$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path "$PSScriptRoot\..\..")
$repo = (Get-Location).Path
$W = Join-Path ($env:RUNNER_TEMP ?? $env:TEMP) 'upd'
if (Test-Path $W) { Remove-Item $W -Recurse -Force }
New-Item -ItemType Directory -Force "$W\srv", "$repo\smoke" | Out-Null
$fail = 0
function Check($cond, $msg) { if ($cond) { Write-Host "  ok   $msg" } else { Write-Host "  FAIL $msg"; $script:fail++ } }
$install = Join-Path $env:LOCALAPPDATA 'BgTest\Backgrounds'
$exe = Join-Path $install 'Backgrounds.exe'
$support = Join-Path $env:APPDATA 'Backgrounds'
$pics = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Backgrounds'
$feedUrl = 'http://127.0.0.1:8765/update.json'
function Ver { if (Test-Path $exe) { ((Get-Item $exe).VersionInfo.ProductVersion -split '\+')[0] } }
function Running { @(Get-Process Backgrounds -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }).Count -gt 0 }

python -m venv "$W\venv"; & "$W\venv\Scripts\pip" install -q cryptography
$py = "$W\venv\Scripts\python.exe"
& $py -c @"
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization as s
import base64, os
for n in ('key', 'wrong'):
    k = ec.generate_private_key(ec.SECP256R1())
    open(os.path.join(r'$W', n + '.pem'), 'wb').write(k.private_bytes(s.Encoding.PEM, s.PrivateFormat.PKCS8, s.NoEncryption()))
    if n == 'key': open(os.path.join(r'$W', 'pub.txt'), 'w').write(base64.b64encode(k.public_key().public_bytes(s.Encoding.X962, s.PublicFormat.UncompressedPoint)[1:]).decode())
"@
$pub = (Get-Content "$W\pub.txt" -Raw).Trim()

Write-Host '== building old (0.9.0)'
pwsh -NoProfile -File app\windows\build.ps1 -Version 0.9.0 -PublicKey $pub -Feed $feedUrl -Out "$W\old" | Out-Null
if ($LASTEXITCODE) { throw 'old build failed' }
# The "new" version changes two wallpapers and adds one.
Add-Content 'Wallpaper - Sheep\index.html' '<!-- v99 -->'
Add-Content 'Wallpaper - Aquarium\index.html' '<!-- v99 -->'
New-Item -ItemType Directory -Force 'Wallpaper - Zz New' | Out-Null
Set-Content 'Wallpaper - Zz New\index.html' '<!doctype html><title>New</title><body style="margin:0;background:#2a6">'
Write-Host '== building new (99.0.0)'
pwsh -NoProfile -File app\windows\build.ps1 -Version 99.0.0 -PublicKey $pub -Feed $feedUrl -Out "$W\new" | Out-Null
if ($LASTEXITCODE) { throw 'new build failed' }
git checkout -- 'Wallpaper - Sheep/index.html' 'Wallpaper - Aquarium/index.html'
Remove-Item 'Wallpaper - Zz New' -Recurse -Force
Copy-Item "$W\new\Backgrounds-windows.zip" "$W\srv\"

function Feed($key) {
  & $py app\release\make_feed.py --version 99.0.0 --key $key --base-url http://127.0.0.1:8765 `
      --windows "$W\srv\Backgrounds-windows.zip" --notes '- Test update' --out "$W\srv\update.json"
}
$server = Start-Process python -ArgumentList '-m', 'http.server', '8765', '--bind', '127.0.0.1', '--directory', "$W\srv" `
    -PassThru -RedirectStandardError "$W\http.log"
Start-Sleep 2

# Fresh install of the old version, told to install updates without asking (test hook).
Get-Process Backgrounds -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($p in $install, $support, $pics) { if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
New-Item -ItemType Directory -Force (Split-Path $install), $support | Out-Null
Copy-Item "$W\old\Backgrounds" (Split-Path $install) -Recurse
Set-Content "$support\config.json" '{"updateAutoInstall": true}'

Write-Host '== 1. update signed with the wrong key'
Feed "$W\wrong.pem"
Start-Process $exe | Out-Null
Start-Sleep 35
Check ((Ver) -eq '0.9.0') "badly signed update refused (still $(Ver))"
Check (Running) 'app still running'
Check ((Get-Content "$support\config.json" -Raw) -match 'lastUpdateCheck') 'it did check the feed'
Check ((Get-Content "$env:LOCALAPPDATA\Backgrounds\log.txt" -Raw) -match 'signature is not valid') 'refused because of the signature'

# The user edits one built-in wallpaper and deletes another.
Add-Content "$pics\Aquarium\index.html" '<!-- my edit -->'
Remove-Item "$pics\Meadow" -Recurse -Force
Get-Process Backgrounds | Stop-Process -Force; Start-Sleep 2
$cfg = Get-Content "$support\config.json" -Raw | ConvertFrom-Json
$cfg.PSObject.Properties.Remove('lastUpdateCheck'); $cfg.PSObject.Properties.Remove('notifiedVersion')
$cfg | ConvertTo-Json -Depth 20 | Set-Content "$support\config.json"

Write-Host '== 2. correctly signed update'
Feed "$W\key.pem"
Start-Process $exe | Out-Null
for ($i = 0; $i -lt 60; $i++) { if ((Ver) -eq '99.0.0' -and (Running)) { break }; Start-Sleep 2 }
Start-Sleep 10
Check ((Ver) -eq '99.0.0') "app replaced itself with 99.0.0 (now $(Ver))"
Check (Running) 'new version relaunched from the same folder'
Check (@(Get-Process Backgrounds -ErrorAction SilentlyContinue).Count -eq 1) 'exactly one copy running'
Check (@(Get-ChildItem $install -Recurse -Filter '*.bgold-*').Count -eq 0) 'old files cleaned up'
Check (Test-Path "$install\Wallpapers\Zz New\index.html") 'bundled wallpapers updated in the app folder'
Check ((Get-Content "$pics\Sheep\index.html" -Raw) -match 'v99') 'unedited built-in wallpaper updated'
$aq = Get-Content "$pics\Aquarium\index.html" -Raw
Check ($aq -match 'my edit' -and $aq -notmatch 'v99') 'edited wallpaper kept as the user left it'
Check (Test-Path "$pics\Zz New\index.html") 'new built-in wallpaper added'
Check (@(Get-ChildItem $pics -Recurse -Filter '*.bgold-*').Count -eq 0) 'no update leftovers copied into the wallpapers folder'
Check ((Get-Content "$env:LOCALAPPDATA\Backgrounds\log.txt" -Raw) -notmatch 'Ant Farm \(updated\)') 'unchanged wallpapers are not touched'
Check (-not (Test-Path "$pics\Meadow")) 'deleted wallpaper not brought back'
Check ((Get-Content "$support\config.json" -Raw) -match '"syncedVersion":"99.0.0"') 'sync recorded'

Write-Host '--- log.txt'
Get-Content "$env:LOCALAPPDATA\Backgrounds\log.txt" | Select-Object -Last 25 | Write-Host
Copy-Item "$env:LOCALAPPDATA\Backgrounds\log.txt" "$repo\smoke\update-log.txt"
Get-Process Backgrounds -ErrorAction SilentlyContinue | Stop-Process -Force
Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'all passed' }
