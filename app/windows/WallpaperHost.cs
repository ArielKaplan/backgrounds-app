using System;
using System.Drawing;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using static Backgrounds.Native;

namespace Backgrounds
{
    /// <summary>
    /// One plain Win32 window per screen, attached behind the desktop icons, with a WebView2 inside.
    /// Pages are served from the wallpapers folder at https://wallpapers.backgrounds.example/ (a WebView2
    /// virtual host), so localStorage persists and live-data fetches get a normal https origin.
    /// </summary>
    sealed class WallpaperHost : NativeWindow, IDisposable
    {
        public const string Host = "wallpapers.backgrounds.example";
        static CoreWebView2Environment env;
        static Task<CoreWebView2Environment> envTask;

        public readonly string ScreenId;
        public Rectangle Bounds { get; private set; }
        public Wallpaper Wallpaper { get; private set; }
        string hash = "", folder;
        CoreWebView2Controller controller;
        bool creating, disposed, frozen, covered;
        Bitmap frozenFrame;
        static int navCounter;

        public WallpaperHost(string screenId, Rectangle bounds)
        {
            ScreenId = screenId;
            Bounds = bounds;
            var cp = new CreateParams
            {
                Caption = "Backgrounds wallpaper",
                X = bounds.X, Y = bounds.Y, Width = bounds.Width, Height = bounds.Height,
                Style = unchecked((int)(WS_POPUP | WS_CLIPCHILDREN | WS_CLIPSIBLINGS)),
                // Layered must be set at creation on raised (24H2+) desktops.
                ExStyle = (int)(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | (Desktop.Raised ? WS_EX_LAYERED : 0)),
            };
            CreateHandle(cp);
            if (Desktop.Raised) SetLayeredWindowAttributes(Handle, 0, 255, LWA_ALPHA);
            Attach();
        }

        public bool Attach()
        {
            if (!Desktop.Attach(Handle)) return false;
            Desktop.Place(Handle, Bounds);
            ShowWindow(Handle, 4 /* SW_SHOWNOACTIVATE */);
            return true;
        }

        public bool IsAttached => Desktop.IsAttached(Handle);

        public void Move(Rectangle bounds)
        {
            Bounds = bounds;
            Desktop.Place(Handle, bounds);
            if (controller != null) controller.Bounds = new Rectangle(0, 0, bounds.Width, bounds.Height);
            Invalidate();
        }

        /// One environment for the whole app (the settings window too): WebView2 refuses a second one with
        /// different options on the same data folder.
        public static Task<CoreWebView2Environment> Env()
        {
            if (envTask != null) return envTask;
            var opts = new CoreWebView2EnvironmentOptions
            {
                // The browser's own occlusion detection doesn't understand a window living inside the desktop;
                // pausing is handled by us instead (see TrayApp.Tick).
                AdditionalBrowserArguments = "--disable-features=CalculateNativeWinOcclusion --autoplay-policy=no-user-gesture-required",
            };
            string data = Path.Combine(Store.Shared.DataDir, "WebView2");
            envTask = CoreWebView2Environment.CreateAsync(null, data, opts);
            return envTask;
        }

        public void Show(Wallpaper wp, string newHash, string folderPath, string extra = null, bool force = false)
        {
            bool same = Wallpaper != null && wp.Id == Wallpaper.Id && wp.File == Wallpaper.File && newHash == hash && folderPath == folder;
            if (same && !force && extra == null && (controller != null || creating)) return;
            Wallpaper = wp; hash = newHash ?? ""; folder = folderPath;
            string fullHash = extra == null ? hash : (hash.Length == 0 ? extra : hash + "&" + extra);
            _ = Navigate(fullHash);
        }

        public void Reload() { if (Wallpaper != null) _ = Navigate(hash); }

        async Task Navigate(string fullHash)
        {
            try
            {
                if (controller == null)
                {
                    if (creating) { pendingHash = fullHash; return; }
                    creating = true;
                    env ??= await Env();
                    var c = await env.CreateCoreWebView2ControllerAsync(Handle);
                    creating = false;
                    if (disposed) { c.Close(); return; }
                    controller = c;
                    controller.DefaultBackgroundColor = Color.Black;
                    controller.Bounds = new Rectangle(0, 0, Bounds.Width, Bounds.Height);
                    var core = controller.CoreWebView2;
                    var s = core.Settings;
                    s.AreDefaultContextMenusEnabled = false;
                    s.AreDefaultScriptDialogsEnabled = false;
                    s.IsStatusBarEnabled = false;
                    s.IsZoomControlEnabled = false;
                    s.AreBrowserAcceleratorKeysEnabled = false;
                    s.IsSwipeNavigationEnabled = false;
                    core.NewWindowRequested += (o, e) => e.Handled = true;
                    core.NavigationStarting += (o, e) =>
                    {
                        // Never let a wallpaper navigate the desktop away to another site.
                        if (!e.Uri.StartsWith("https://" + Host + "/", StringComparison.OrdinalIgnoreCase) && !e.Uri.StartsWith("about:")) e.Cancel = true;
                    };
                    core.ProcessFailed += OnProcessFailed;
                    core.NavigationCompleted += (o, e) =>
                    {
                        // Paused, but a new page arrived (first launch on battery, or options changed while paused):
                        // let it draw for a moment, then freeze on its frame.
                        if (!frozen) return;
                        DropFrozenFrame();
                        ApplyVisibility();
                        CaptureLater(2500);
                    };
                    ApplyVisibility();
                    if (pendingHash != null) { fullHash = pendingHash; pendingHash = null; }
                }
                var core2 = controller.CoreWebView2;
                core2.SetVirtualHostNameToFolderMapping(Host, folder, CoreWebView2HostResourceAccessKind.Allow);
                // A new query each time makes it a new document even when only the #hash changed.
                string url = "https://" + Host + "/" + EscapePath(Wallpaper.RelPath) + "?r=" + (++navCounter) +
                             (fullHash.Length > 0 ? "#" + fullHash : "");
                core2.Navigate(url);
            }
            catch (Exception e)
            {
                creating = false;
                Log.Write("WebView2 failed: " + e);
                // e.g. right after an update, while the previous version's browser processes are still exiting:
                // start over with a fresh environment a few seconds later (a few times).
                if (controller == null && !disposed && ++failures <= 5)
                {
                    env = null; envTask = null;
                    var t = new Timer { Interval = 3000 * failures };
                    t.Tick += (o, a) => { t.Stop(); t.Dispose(); if (!disposed && controller == null) _ = Navigate(fullHash); };
                    t.Start();
                }
            }
        }
        int failures;
        string pendingHash;

        static string EscapePath(string rel)
        {
            var parts = rel.Split('/');
            for (int i = 0; i < parts.Length; i++) parts[i] = Uri.EscapeDataString(parts[i]);
            return string.Join("/", parts);
        }

        void OnProcessFailed(object sender, CoreWebView2ProcessFailedEventArgs e)
        {
            Log.Write("WebView2 process failed: " + e.ProcessFailedKind);
            // Bring the page back. If the whole browser went away, start over with a new controller.
            var t = new Timer { Interval = 1500 };
            t.Tick += (o, a) =>
            {
                t.Stop(); t.Dispose();
                if (disposed) return;
                if (e.ProcessFailedKind == CoreWebView2ProcessFailedKind.BrowserProcessExited)
                {
                    try { controller?.Close(); } catch { }
                    controller = null; env = null; envTask = null;
                }
                _ = Navigate(hash);
            };
            t.Start();
        }

        // ---- pausing

        /// Freeze: keep the last frame on screen and hide the page (a hidden WebView2 stops rendering and
        /// animation frames). Used for "Pause" and "Pause on battery".
        public void SetFrozen(bool on)
        {
            if (on == frozen) return;
            frozen = on;
            if (on) CaptureLater(0);
            else { captureToken++; DropFrozenFrame(); ApplyVisibility(); }
        }

        int captureToken;
        async void CaptureLater(int ms)
        {
            int token = ++captureToken;
            if (ms > 0) await Task.Delay(ms);
            if (token != captureToken || !frozen || disposed) return;
            if (controller == null || covered) { CaptureLater(5000); return; }   // nothing visible to capture yet
            try
            {
                using (var ms2 = new MemoryStream())
                {
                    await controller.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, ms2);
                    if (token != captureToken || !frozen || disposed) return;
                    ms2.Position = 0;
                    var bmp = new Bitmap(ms2);
                    frozenFrame?.Dispose();
                    frozenFrame = bmp;
                }
            }
            catch (Exception e) { Log.Write("capture: " + e.Message); return; }
            Invalidate();
            ApplyVisibility();
        }

        void DropFrozenFrame()
        {
            frozenFrame?.Dispose();
            frozenFrame = null;
            Invalidate();
        }

        /// Covered by a maximized/full-screen window: nobody can see it, just stop rendering.
        public void SetCovered(bool on)
        {
            if (on == covered) return;
            covered = on;
            ApplyVisibility();
        }

        void ApplyVisibility()
        {
            if (controller == null) return;
            // Hidden while covered, or while frozen once there is a frame to show instead.
            bool visible = !covered && !(frozen && frozenFrame != null);
            if (controller.IsVisible != visible) controller.IsVisible = visible;
        }

        void Invalidate() { if (Handle != IntPtr.Zero) InvalidateRect(Handle, IntPtr.Zero, true); }

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern bool InvalidateRect(IntPtr hWnd, IntPtr rect, bool erase);

        protected override void WndProc(ref Message m)
        {
            switch (m.Msg)
            {
                case WM_MOUSEACTIVATE:
                    m.Result = new IntPtr(MA_NOACTIVATE);
                    return;
                case WM_ERASEBKGND:
                    m.Result = new IntPtr(1);
                    return;
                case WM_PAINT:
                    var ps = new PAINTSTRUCT();
                    IntPtr hdc = BeginPaint(Handle, ref ps);
                    using (var g = Graphics.FromHdc(hdc))
                    {
                        if (frozenFrame != null) g.DrawImage(frozenFrame, 0, 0, Bounds.Width, Bounds.Height);
                        else g.Clear(Color.Black);
                    }
                    EndPaint(Handle, ref ps);
                    m.Result = IntPtr.Zero;
                    return;
            }
            base.WndProc(ref m);
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct PAINTSTRUCT
        {
            public IntPtr hdc; public bool fErase; public RECT rcPaint; public bool fRestore; public bool fIncUpdate;
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValArray, SizeConst = 32)] public byte[] rgbReserved;
        }
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern IntPtr BeginPaint(IntPtr hWnd, ref PAINTSTRUCT ps);
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern bool EndPaint(IntPtr hWnd, ref PAINTSTRUCT ps);

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            try { controller?.Close(); } catch { }
            controller = null;
            frozenFrame?.Dispose(); frozenFrame = null;
            if (Handle != IntPtr.Zero) DestroyHandle();
        }
    }
}
