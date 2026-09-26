using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;
using Microsoft.Win32;
using static Backgrounds.Native;

namespace Backgrounds
{
    /// Tray icon + one WallpaperHost per screen, kept in line with the settings.
    sealed class TrayApp : ApplicationContext
    {
        public static TrayApp Current;
        readonly NotifyIcon tray;
        readonly Dictionary<string, WallpaperHost> hosts = new Dictionary<string, WallpaperHost>();
        readonly Timer tick = new Timer { Interval = 1000 };
        readonly Timer updateTimer = new Timer { Interval = 3600 * 1000 };
        bool locked, desktopReady;
        public bool OnBattery { get; private set; }

        public TrayApp()
        {
            Current = this;
            tray = new NotifyIcon { Icon = AppIcon(SystemInformation.SmallIconSize), Text = "Backgrounds", Visible = true };
            tray.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) SettingsForm.ShowSingle(); };
            tray.ContextMenuStrip = new ContextMenuStrip();
            tray.ContextMenuStrip.Opening += (s, e) => BuildMenu();
            BuildMenu();

            SystemEvents.DisplaySettingsChanged += (s, e) => Later(500, () => Apply());
            SystemEvents.PowerModeChanged += (s, e) =>
            {
                if (e.Mode == PowerModes.Resume) Later(2000, () => { if (desktopReady) CheckDesktop(); Apply(); });
                if (e.Mode == PowerModes.StatusChange) Tick();
            };
            SystemEvents.SessionSwitch += (s, e) =>
            {
                if (e.Reason == SessionSwitchReason.SessionLock) { locked = true; Tick(); }
                if (e.Reason == SessionSwitchReason.SessionUnlock) { locked = false; Tick(); }
            };
            tick.Tick += (s, e) => Tick();

            OnBattery = SystemInformation.PowerStatus.PowerLineStatus == PowerLineStatus.Offline;
            desktopReady = Desktop.Setup();     // if Explorer isn't ready yet, Tick keeps retrying
            Apply();
            tick.Start();

            // Updates: check shortly after start, then hourly (it only goes to the network once a day).
            Updater.CleanupOldFiles();
            Updater.Shared.Changed += () => SettingsForm.PushState();
            tray.BalloonTipClicked += (s, e) => SettingsForm.ShowSingle("update");
            Later(10000, () => MaybeCheckForUpdate());
            updateTimer.Tick += (s, e) => MaybeCheckForUpdate();
            updateTimer.Start();

            if (!Store.Shared.Settings.ContainsKey("launchedBefore"))
            {
                Store.Shared.Settings["launchedBefore"] = true;
                Store.Shared.Save();
                SettingsForm.ShowSingle();
            }
        }

        async void MaybeCheckForUpdate()
        {
            var store = Store.Shared;
            if (!Updater.Configured || !store.AutoUpdateCheck) return;
            if (DateTime.TryParse(store.Get("lastUpdateCheck") as string, null, System.Globalization.DateTimeStyles.RoundtripKind, out var last)
                && DateTime.UtcNow - last.ToUniversalTime() < TimeSpan.FromHours(23)) return;
            if (!await Updater.Shared.Check()) return;
            string v = Updater.Shared.LatestVersion;
            if (store.Get("updateAutoInstall") is bool auto && auto) { await Updater.Shared.Install(); return; }
            if (store.Get("notifiedVersion") as string == v) return;      // asked about this version already
            store.Set("notifiedVersion", v);
            tray.ShowBalloonTip(15000, "Backgrounds " + v + " is available", "Click to see what's new and install it.", ToolTipIcon.Info);
        }

        public static Icon AppIcon(Size size)
        {
            using (var s = typeof(TrayApp).Assembly.GetManifestResourceStream("Backgrounds.ico"))
                return s != null ? new Icon(s, size) : SystemIcons.Application;
        }

        static void Later(int ms, Action a)
        {
            var t = new Timer { Interval = ms };
            t.Tick += (s, e) => { t.Stop(); t.Dispose(); a(); };
            t.Start();
        }

        public class ScreenInfo { public string Id, Name; public bool Primary; public Rectangle Bounds; }

        public static List<ScreenInfo> Screens()
        {
            return Screen.AllScreens.Select((s, i) => new ScreenInfo
            {
                Id = s.DeviceName,
                Name = "Display " + (DisplayNumber(s.DeviceName) ?? (i + 1).ToString()),
                Primary = s.Primary,
                Bounds = s.Bounds,
            }).OrderBy(s => s.Primary ? 0 : 1).ThenBy(s => s.Bounds.X).ToList();
        }

        static string DisplayNumber(string deviceName)
        {
            // \\.\DISPLAY2 -> "2"
            var digits = new string(deviceName.Reverse().TakeWhile(char.IsDigit).Reverse().ToArray());
            return digits.Length > 0 ? digits : null;
        }

        public bool PausedByBattery => Store.Shared.PauseOnBattery && OnBattery;

        /// Creates/updates/removes wallpaper windows to match the settings.
        public void Apply(bool force = false, string only = null)
        {
            var store = Store.Shared;
            var wallpapers = store.Scan().GroupBy(w => w.Id).ToDictionary(g => g.Key, g => g.First());
            var seen = new HashSet<string>();
            bool freeze = store.Paused || PausedByBattery;
            foreach (var sc in Screens())
            {
                seen.Add(sc.Id);
                string id = store.WallpaperForScreen(sc.Id, sc.Primary);
                if (id == null || !wallpapers.TryGetValue(id, out var wp) || !desktopReady)
                {
                    if (hosts.TryGetValue(sc.Id, out var old)) { old.Dispose(); hosts.Remove(sc.Id); }
                    continue;
                }
                if (!hosts.TryGetValue(sc.Id, out var host))
                {
                    host = new WallpaperHost(sc.Id, sc.Bounds);
                    hosts[sc.Id] = host;
                }
                else if (host.Bounds != sc.Bounds) host.Move(sc.Bounds);
                host.Show(wp, store.Hash(id), store.Folder, force: force && (only == null || only == id));
                host.SetFrozen(freeze);
            }
            foreach (var key in hosts.Keys.Where(k => !seen.Contains(k)).ToList()) { hosts[key].Dispose(); hosts.Remove(key); }
            UpdatePause();
        }

        public int ReloadOnce(string wallpaperId, string extra)
        {
            var wp = Store.Shared.Scan().FirstOrDefault(w => w.Id == wallpaperId);
            if (wp == null) return 0;
            int n = 0;
            foreach (var h in hosts.Values.Where(h => h.Wallpaper?.Id == wallpaperId))
            {
                h.Show(wp, Store.Shared.Hash(wallpaperId), Store.Shared.Folder, extra: extra, force: true);
                n++;
            }
            return n;
        }

        /// Explorer restarted / the desktop layout changed: re-create everything.
        void CheckDesktop()
        {
            if (hosts.Count == 0) return;
            if (Desktop.StillValid() && hosts.Values.All(h => h.IsAttached)) { Desktop.EnsureWorkerWAtBottom(); return; }
            // Only z-order drift? Fix it in place.
            if (Desktop.StillValid() && hosts.Values.All(h => IsWindow(h.Handle) && ParentOf(h.Handle) == Desktop.Parent))
            {
                foreach (var h in hosts.Values) Desktop.Restack(h.Handle);
                return;
            }
            Log.Write("Desktop changed (Explorer restart?) - re-attaching wallpapers");
            foreach (var h in hosts.Values) h.Dispose();
            hosts.Clear();
            desktopReady = false;       // Tick retries until Explorer is back
            nextSetupTry = DateTime.MinValue;
        }
        DateTime nextSetupTry = DateTime.MinValue;

        void Tick()
        {
            if (desktopReady) CheckDesktop();
            if (!desktopReady && DateTime.Now >= nextSetupTry)
            {
                // Explorer may still be starting: retry every 2 s.
                nextSetupTry = DateTime.Now.AddSeconds(2);
                if (Desktop.Setup()) { desktopReady = true; Apply(); return; }
            }
            UpdatePause();
        }

        void UpdatePause()
        {
            var store = Store.Shared;
            bool battery = SystemInformation.PowerStatus.PowerLineStatus == PowerLineStatus.Offline;
            if (battery != OnBattery)
            {
                OnBattery = battery;
                bool freeze = store.Paused || PausedByBattery;
                foreach (var h in hosts.Values) h.SetFrozen(freeze);
                SettingsForm.PushState();
            }

            // Covered: a maximized window on that screen, or a full-screen foreground window.
            var coveredMonitors = new HashSet<IntPtr>();
            if (store.PauseWhenCovered && hosts.Count > 0) coveredMonitors = CoveredMonitors();
            foreach (var h in hosts.Values)
            {
                var c = new POINT { X = h.Bounds.Left + h.Bounds.Width / 2, Y = h.Bounds.Top + h.Bounds.Height / 2 };
                IntPtr mon = MonitorFromPoint(c, MONITOR_DEFAULTTONEAREST);
                h.SetCovered(locked || coveredMonitors.Contains(mon));
            }
        }

        static readonly HashSet<string> ShellClasses = new HashSet<string>
        {
            "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow",
            "Windows.UI.Core.CoreWindow", "XamlExplorerHostIslandWindow", "TopLevelWindowForOverflowXamlIsland",
        };

        static HashSet<IntPtr> CoveredMonitors()
        {
            var result = new HashSet<IntPtr>();
            uint me = (uint)Process.GetCurrentProcess().Id;
            IntPtr fg = GetForegroundWindow();
            EnumWindows((hwnd, _) =>
            {
                if (!IsWindowVisible(hwnd) || IsIconic(hwnd) || IsCloaked(hwnd)) return true;
                GetWindowThreadProcessId(hwnd, out uint pid);
                if (pid == me) return true;
                uint ex = GetWindowLong(hwnd, GWL_EXSTYLE);
                if ((ex & WS_EX_TOOLWINDOW) != 0 || (ex & WS_EX_TRANSPARENT) != 0) return true;
                if (ShellClasses.Contains(ClassName(hwnd))) return true;
                IntPtr mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONULL);
                if (mon == IntPtr.Zero) return true;
                if (IsZoomed(hwnd)) { result.Add(mon); return true; }
                if (hwnd == fg)
                {
                    // full-screen (games, video): covers the whole monitor
                    var r = VisibleBounds(hwnd);
                    foreach (var s in Screen.AllScreens)
                        if (r.Left <= s.Bounds.Left && r.Top <= s.Bounds.Top && r.Right >= s.Bounds.Right && r.Bottom >= s.Bounds.Bottom)
                            result.Add(mon);
                }
                return true;
            }, IntPtr.Zero);
            return result;
        }

        // ---- tray menu

        void BuildMenu()
        {
            var store = Store.Shared;
            var menu = tray.ContextMenuStrip;
            menu.Items.Clear();
            var wallpapers = store.Scan();
            var screens = Screens();

            if (Updater.Shared.Status == "available")
            {
                var up = new ToolStripMenuItem("Install update " + Updater.Shared.LatestVersion + "…", null, (s, e) => SettingsForm.ShowSingle("update"));
                up.Font = new Font(up.Font, FontStyle.Bold);
                menu.Items.Add(up);
                menu.Items.Add(new ToolStripSeparator());
            }

            ToolStripMenuItem List(string title, ScreenInfo screen)
            {
                var item = new ToolStripMenuItem(title);
                string current = screen != null ? store.WallpaperForScreen(screen.Id, screen.Primary) : store.MainWallpaper;
                foreach (var wp in wallpapers)
                {
                    var w = wp;
                    item.DropDownItems.Add(new ToolStripMenuItem(wp.Name, null, (s, e) => Choose(w.Id, screen?.Id)) { Checked = wp.Id == current });
                }
                if (wallpapers.Count == 0) item.DropDownItems.Add(new ToolStripMenuItem("No wallpapers in the folder") { Enabled = false });
                item.DropDownItems.Add(new ToolStripSeparator());
                item.DropDownItems.Add(new ToolStripMenuItem("None", null, (s, e) => Choose(null, screen?.Id)) { Checked = current == null });
                return item;
            }

            if (store.Arrangement == "perScreen" && screens.Count > 1)
                foreach (var s in screens) menu.Items.Add(List(s.Name + (s.Primary ? " (main)" : ""), s));
            else menu.Items.Add(List("Wallpaper", null));
            menu.Items.Add(new ToolStripSeparator());
            string pause = store.Paused ? "Resume" : PausedByBattery ? "Pause (paused on battery)" : "Pause";
            menu.Items.Add(pause, null, (s, e) => { store.Paused = !store.Paused; Changed(); });
            menu.Items.Add("Reload", null, (s, e) => { Apply(force: true); });
            menu.Items.Add(new ToolStripSeparator());
            var settings = new ToolStripMenuItem("Settings…", null, (s, e) => SettingsForm.ShowSingle());
            settings.Font = new Font(settings.Font, FontStyle.Bold);
            menu.Items.Add(settings);
            menu.Items.Add("Open wallpapers folder", null, (s, e) => OpenFolder(store.Folder));
            menu.Items.Add("Check for updates…", null, async (s, e) =>
            {
                SettingsForm.ShowSingle("update");
                await Updater.Shared.Check();
            });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit Backgrounds", null, (s, e) => Quit());
        }

        void Choose(string id, string screen)
        {
            Store.Shared.Choose(id, screen);
            Changed();
        }

        public void Changed()
        {
            Apply();
            SettingsForm.PushState();
        }

        public static void OpenFolder(string path)
        {
            try { Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true }); }
            catch (Exception e) { Log.Write("open folder: " + e.Message); }
        }

        public void Quit()
        {
            tick.Stop();
            updateTimer.Stop();
            foreach (var h in hosts.Values) h.Dispose();
            hosts.Clear();
            tray.Visible = false;
            tray.Dispose();
            SettingsForm.CloseSingle();
            ExitThread();
        }
    }

    static class LoginItem
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string Name = "Backgrounds";
        static string Command => "\"" + Application.ExecutablePath + "\"";

        public static bool IsEnabled
        {
            get
            {
                using (var k = Registry.CurrentUser.OpenSubKey(RunKey))
                    return k?.GetValue(Name) is string v && v.Length > 0;
            }
        }

        public static bool Set(bool on)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (on) k.SetValue(Name, Command); else k.DeleteValue(Name, false);
            }
            return IsEnabled;
        }

        /// If the app was moved, keep the login entry pointing at this copy.
        public static void Refresh()
        {
            try { if (IsEnabled) Set(true); } catch { }
        }
    }
}
