# CI smoke test: starts the built app on a real Windows desktop and checks that the wallpaper window is attached
# behind the desktop icons, that WebView2 is rendering in it, and that it survives an Explorer restart.
param([string]$AppDir = "$PSScriptRoot\..\windows\build\Backgrounds", [string]$Shots = "$PSScriptRoot\..\..\smoke")
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Shots | Out-Null
$fail = 0
function Check($cond, $msg) { if ($cond) { Write-Host "  ok   $msg" } else { Write-Host "  FAIL $msg"; $script:fail++ } }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class W {
  public delegate bool P(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(P p, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, P p, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtr")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static string Text(IntPtr h) { var s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }
  public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static List<IntPtr> Hosts() {
    var res = new List<IntPtr>();
    // our wallpaper windows are children of Progman / a WorkerW, so search all descendants of top-level windows
    EnumWindows((t, l) => { if (Text(t) == "Backgrounds wallpaper") res.Add(t);
      EnumChildWindows(t, (c, l2) => { if (Text(c) == "Backgrounds wallpaper") res.Add(c); return true; }, IntPtr.Zero); return true; }, IntPtr.Zero);
    return res;
  }
  public static List<string> Children(IntPtr h) {
    var res = new List<string>();
    EnumChildWindows(h, (c, l) => { res.Add(Cls(c)); return true; }, IntPtr.Zero);
    return res;
  }
}
"@

function Shot($name) {
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size) } catch { Write-Host "  (screenshot failed: $_)" }
  $bmp.Save("$Shots\$name.png"); $g.Dispose(); $bmp.Dispose()
}

function Describe-Hosts {
  $hosts = [W]::Hosts()
  foreach ($h in $hosts) {
    $p = [W]::GetParent($h); $r = New-Object W+RECT; [void][W]::GetWindowRect($h, [ref]$r)
    $ex = [W]::GetWindowLongPtr($h, -20).ToInt64()
    Write-Host ("  host {0}: parent={1} visible={2} rect={3},{4},{5},{6} layered={7} children={8}" -f $h, [W]::Cls($p), [W]::IsWindowVisible($h), $r.L, $r.T, $r.R, $r.B, (($ex -band 0x80000) -ne 0), (([W]::Children($h) | Select-Object -Unique) -join ','))
  }
  return ,$hosts
}

$os = [Environment]::OSVersion.Version
$progman = [W]::FindWindow("Progman", $null)
$raised = (([W]::GetWindowLongPtr($progman, -20).ToInt64()) -band 0x00200000) -ne 0
Write-Host "Windows $os, explorer running: $([bool](Get-Process explorer -ErrorAction SilentlyContinue)), progman=$progman raised=$raised"
Write-Host "WebView2: $((Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue).pv)"

$exe = Join-Path (Resolve-Path $AppDir) 'Backgrounds.exe'
$proc = Start-Process $exe -PassThru
Start-Sleep 20
Check (!$proc.HasExited) 'app is running'
Check (Test-Path "$env:USERPROFILE\Pictures\Backgrounds\Aquarium\index.html") 'built-in wallpapers copied to Pictures\Backgrounds'
Check (Test-Path "$env:APPDATA\Backgrounds\config.json") 'config.json written'

$hosts = Describe-Hosts
Check ($hosts.Count -ge 1) "wallpaper window(s) exist ($($hosts.Count))"
if ($hosts.Count -ge 1) {
  $h = $hosts[0]; $pcls = [W]::Cls([W]::GetParent($h))
  Check ($pcls -eq 'WorkerW' -or $pcls -eq 'Progman') "attached behind the icons (parent $pcls)"
  if ($raised) { Check ($pcls -eq 'Progman') 'raised desktop: child of Progman' }
  $kids = [W]::Children($h)
  Check (($kids | Where-Object { $_ -like 'Chrome_*' }).Count -ge 1) 'WebView2 is rendering inside it'
  $r = New-Object W+RECT; [void][W]::GetWindowRect($h, [ref]$r)
  $s = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  Check ($r.L -eq $s.Left -and $r.T -eq $s.Top -and ($r.R - $r.L) -eq $s.Width -and ($r.B - $r.T) -eq $s.Height) "covers the screen ($($s.Width)x$($s.Height))"
}
$settings = Get-Process -Id $proc.Id | Select-Object -ExpandProperty MainWindowTitle
Check ($settings -eq 'Backgrounds') "settings window opened on first launch (title '$settings')"
Shot 'windows-1-first-launch'

# Second launch: must not start another copy.
$second = Start-Process $exe -PassThru
Start-Sleep 5
Check ($second.HasExited) 'second launch exits (single instance)'

# Show the bare desktop
(New-Object -ComObject Shell.Application).MinimizeAll()
Start-Sleep 5
Shot 'windows-2-desktop'

# Explorer restart: wallpaper must come back by itself.
Write-Host 'restarting Explorer...'
Stop-Process -Name explorer -Force
Start-Sleep 4
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
Start-Sleep 20
$hosts = Describe-Hosts
Check ($hosts.Count -ge 1) 'wallpaper re-attached after Explorer restart'
if ($hosts.Count -ge 1) {
  $pcls = [W]::Cls([W]::GetParent($hosts[0]))
  Check ($pcls -eq 'WorkerW' -or $pcls -eq 'Progman') "re-attached behind the icons (parent $pcls)"
  Check ((([W]::Children($hosts[0])) | Where-Object { $_ -like 'Chrome_*' }).Count -ge 1) 'WebView2 rendering again'
}
(New-Object -ComObject Shell.Application).MinimizeAll()
Start-Sleep 3
Shot 'windows-3-after-explorer-restart'
Check (!$proc.HasExited) 'app still running'

Write-Host '--- log.txt'
Get-Content "$env:LOCALAPPDATA\Backgrounds\log.txt" -ErrorAction SilentlyContinue | Write-Host
Copy-Item "$env:LOCALAPPDATA\Backgrounds\log.txt" $Shots -ErrorAction SilentlyContinue
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'all passed' }
