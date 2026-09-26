using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Backgrounds
{
    /// The settings window: app/shared/settings.html in a WebView2, talking to us through web messages.
    sealed class SettingsForm : Form
    {
        const string Host = "settings.backgrounds.example";
        static SettingsForm single;
        readonly WebView2 web;
        string focus;

        /// `focus`: "update" opens the page on the update section.
        public static void ShowSingle(string focus = null)
        {
            if (single == null || single.IsDisposed) single = new SettingsForm();
            single.focus = focus;
            if (focus != null && single.web.CoreWebView2 != null) single.Send(new Dictionary<string, object> { ["event"] = "focus", ["data"] = focus });
            if (single.WindowState == FormWindowState.Minimized) single.WindowState = FormWindowState.Normal;
            single.Show();
            single.Activate();
        }

        public static void CloseSingle() { if (single != null && !single.IsDisposed) single.Close(); }

        public static void PushState()
        {
            if (single == null || single.IsDisposed) return;
            single.Send(new Dictionary<string, object> { ["event"] = "state", ["data"] = State() });
        }

        SettingsForm()
        {
            Text = "Backgrounds";
            Icon = TrayApp.AppIcon(new Size(32, 32));
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.Dpi;
            float k = DeviceDpi / 96f;
            ClientSize = new Size((int)(940 * k), (int)(680 * k));
            MinimumSize = new Size((int)(760 * k), (int)(500 * k));
            BackColor = Color.FromArgb(0x1c, 0x1c, 0x1f);
            web = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.Transparent };
            Controls.Add(web);
            Load += async (s, e) =>
            {
                try
                {
                    await web.EnsureCoreWebView2Async(await WallpaperHost.Env());
                    var core = web.CoreWebView2;
                    core.Settings.AreDefaultContextMenusEnabled = false;
                    core.Settings.IsStatusBarEnabled = false;
                    core.Settings.IsZoomControlEnabled = false;
                    core.SetVirtualHostNameToFolderMapping(Host, Store.AppDir, CoreWebView2HostResourceAccessKind.Allow);
                    core.WebMessageReceived += OnMessage;
                    core.NewWindowRequested += (o, a) => { a.Handled = true; TrayApp.OpenFolder(a.Uri); };
                    core.Navigate("https://" + Host + "/settings.html");
                }
                catch (Exception ex)
                {
                    Log.Write("settings webview: " + ex);
                    MessageBox.Show(this, "The settings window couldn't start:\n" + ex.Message, "Backgrounds", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            };
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            base.OnFormClosed(e);
            web.Dispose();
            if (single == this) single = null;
        }

        void Send(Dictionary<string, object> msg)
        {
            try { web.CoreWebView2?.PostWebMessageAsJson(Store.Json.Serialize(msg)); }
            catch (Exception e) { Log.Write("send: " + e.Message); }
        }

        void OnMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            object id = null;
            try
            {
                if (!(Store.Json.DeserializeObject(e.WebMessageAsJson) is Dictionary<string, object> msg)) return;
                msg.TryGetValue("id", out id);
                string cmd = msg.TryGetValue("cmd", out var c) ? c as string : null;
                var args = msg.TryGetValue("args", out var a) && a is Dictionary<string, object> ad ? ad : new Dictionary<string, object>();
                object result = Dispatch(cmd, args);
                Send(new Dictionary<string, object> { ["reply"] = id, ["ok"] = true, ["result"] = result });
            }
            catch (Exception ex)
            {
                Log.Write("bridge: " + ex);
                Send(new Dictionary<string, object> { ["reply"] = id, ["ok"] = false, ["error"] = ex.Message });
            }
        }

        object Dispatch(string cmd, Dictionary<string, object> args)
        {
            var store = Store.Shared;
            var app = TrayApp.Current;
            switch (cmd)
            {
                case "getState":
                    if (focus != null) { var f = focus; focus = null; BeginInvoke(new Action(() => Send(new Dictionary<string, object> { ["event"] = "focus", ["data"] = f }))); }
                    return State();
                case "checkForUpdates":
                    _ = Updater.Shared.Check();          // progress arrives as "state" events
                    return Updater.Shared.StateJson();
                case "installUpdate":
                    _ = Updater.Shared.Install();
                    return Updater.Shared.StateJson();
                case "setSettings":
                    if (!(args.TryGetValue("settings", out var s) && s is Dictionary<string, object> sd)) throw new Exception("bad settings");
                    store.Settings = sd;
                    store.Save();
                    app.Apply();
                    return State();
                case "setLaunchAtLogin":
                    bool on = args.TryGetValue("enabled", out var en) && en is bool b && b;
                    return new Dictionary<string, object> { ["enabled"] = LoginItem.Set(on) };
                case "chooseFolder":
                    using (var dlg = new FolderBrowserDialog
                    {
                        Description = "Choose the folder that holds your wallpapers (one folder with an index.html per wallpaper).",
                        SelectedPath = store.Folder,
                        ShowNewFolderButton = true,
                    })
                    {
                        if (dlg.ShowDialog(this) != DialogResult.OK || string.IsNullOrEmpty(dlg.SelectedPath)) return null;
                        store.SetFolder(dlg.SelectedPath);
                    }
                    app.Apply(force: true);
                    return State();
                case "openFolder":
                    TrayApp.OpenFolder(store.Folder);
                    return null;
                case "openWallpaperFolder":
                {
                    var wp = store.Scan().FirstOrDefault(w => w.Id == (args.TryGetValue("id", out var i) ? i as string : null));
                    if (wp != null) System.Diagnostics.Process.Start("explorer.exe", "/select,\"" + wp.File + "\"");
                    return null;
                }
                case "restoreBuiltins":
                    var added = store.RestoreBuiltins();
                    app.Apply();
                    return new Dictionary<string, object> { ["added"] = added, ["state"] = State() };
                case "reload":
                    app.Apply(force: true, only: args.TryGetValue("wallpaper", out var w2) ? w2 as string : null);
                    return State();
                case "reloadOnce":
                {
                    string wp = args.TryGetValue("wallpaper", out var x) ? x as string : null;
                    string extra = args.TryGetValue("extra", out var y) ? y as string : null;
                    int n = wp != null && extra != null ? app.ReloadOnce(wp, extra) : 0;
                    return new Dictionary<string, object> { ["message"] = n > 0 ? "Done" : "It only works while this wallpaper is showing" };
                }
                case "closeSettings":
                    BeginInvoke(new Action(Close));
                    return null;
                case "quit":
                    BeginInvoke(new Action(app.Quit));
                    return null;
                default:
                    throw new Exception("unknown command " + cmd);
            }
        }

        public static Dictionary<string, object> State()
        {
            var store = Store.Shared;
            return new Dictionary<string, object>
            {
                ["platform"] = "windows",
                ["version"] = Application.ProductVersion.Split('+')[0],
                ["folder"] = store.Folder,
                ["screens"] = TrayApp.Screens().Select(s => new Dictionary<string, object>
                {
                    ["id"] = s.Id, ["name"] = s.Name, ["primary"] = s.Primary, ["width"] = s.Bounds.Width, ["height"] = s.Bounds.Height,
                }).ToList(),
                ["wallpapers"] = store.Scan().Select(w => w.StateJson()).ToList(),
                ["settings"] = store.Settings,
                ["launchAtLogin"] = LoginItem.IsEnabled,
                ["onBattery"] = TrayApp.Current?.OnBattery ?? false,
                ["update"] = Updater.Shared.StateJson(),
            };
        }
    }
}
