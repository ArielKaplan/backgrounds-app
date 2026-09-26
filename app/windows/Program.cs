using System;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;

namespace Backgrounds
{
    static class Program
    {
        const string MutexName = "Backgrounds.App.SingleInstance.7f3c";
        const string ShowSettingsEvent = "Backgrounds.App.ShowSettings.7f3c";

        [STAThread]
        static void Main(string[] args)
        {
            using (var mutex = new Mutex(true, MutexName, out bool first))
            {
                if (!first && Array.IndexOf(args, "--updated") >= 0)
                {
                    // Started by the updater: wait for the old version to quit.
                    try { first = mutex.WaitOne(TimeSpan.FromSeconds(30)); }
                    catch (AbandonedMutexException) { first = true; }
                }
                if (!first)
                {
                    // Already running: ask that copy to open its settings window, then leave.
                    try { using (var ev = EventWaitHandle.OpenExisting(ShowSettingsEvent)) ev.Set(); } catch { }
                    return;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.ThreadException += (s, e) => Log.Write("UI error: " + e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (s, e) => Log.Write("fatal: " + e.ExceptionObject);

                try { CoreWebView2Environment.GetAvailableBrowserVersionString(); }
                catch (Exception)
                {
                    var r = MessageBox.Show(
                        "Backgrounds needs the Microsoft Edge WebView2 Runtime, which is part of Windows 11 and up-to-date Windows 10.\n\nOpen the download page now?",
                        "Backgrounds", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                    if (r == DialogResult.Yes)
                        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://go.microsoft.com/fwlink/p/?LinkId=2124703") { UseShellExecute = true });
                    return;
                }

                // Leftovers of the previous version from an update; must go before anything reads the app folder.
                Updater.CleanupOldFiles();
                Log.Write("Backgrounds " + Application.ProductVersion + " starting, Windows " + Environment.OSVersion.Version);
                LoginItem.Refresh();
                var app = new TrayApp();

                using (var ev = new EventWaitHandle(false, EventResetMode.AutoReset, ShowSettingsEvent))
                {
                    var ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
                    ThreadPool.RegisterWaitForSingleObject(ev, (st, timedOut) => ui.Post(_ => SettingsForm.ShowSingle(), null), null, -1, false);
                    Application.Run(app);
                }
                GC.KeepAlive(mutex);
            }
        }
    }
}
