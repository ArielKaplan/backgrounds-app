using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Backgrounds
{
    /// <summary>
    /// In-app updates. Reads update.json from the latest GitHub release, and on request downloads the Windows zip,
    /// checks its SHA-256 and ECDSA P-256 signature against the public key built into this app, swaps the files
    /// in place and restarts. See app/release/make_feed.py for the feed format.
    /// </summary>
    sealed class Updater
    {
        public static readonly Updater Shared = new Updater();
        public static string CurrentVersion => Application.ProductVersion.Split('+')[0];

        public string Status { get; private set; } = "idle";   // idle checking upToDate available downloading installing error
        public string Error { get; private set; }
        public string LatestVersion { get; private set; }
        public string Notes { get; private set; }
        public int Progress { get; private set; }
        public event Action Changed;
        Dictionary<string, object> entry;
        bool busy;

        static string Meta(string key) =>
            typeof(Updater).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == key)?.Value ?? "";
        static string PublicKey => Meta("UpdatePublicKey").Trim();
        static string FeedUrl => Store.Shared.Get("updateFeed") as string ?? Meta("UpdateFeed");
        public static bool Configured => PublicKey.Length > 0 && FeedUrl.Length > 0;

        void Set(string status, string error = null)
        {
            Status = status; Error = error;
            Changed?.Invoke();
        }

        public Dictionary<string, object> StateJson() => new Dictionary<string, object>
        {
            ["current"] = CurrentVersion, ["status"] = Configured ? Status : "disabled", ["error"] = Error,
            ["latest"] = LatestVersion, ["notes"] = Notes, ["progress"] = Progress,
            ["lastCheck"] = Store.Shared.Get("lastUpdateCheck"),
        };

        static WebClient Client()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var c = new WebClient { Encoding = Encoding.UTF8 };
            c.Headers[HttpRequestHeader.UserAgent] = "Backgrounds/" + CurrentVersion + " (Windows)";
            c.Headers[HttpRequestHeader.CacheControl] = "no-cache";
            return c;
        }

        /// Returns true when a newer version is available.
        public async Task<bool> Check()
        {
            if (!Configured) { Set("disabled"); return false; }
            if (busy) return Status == "available";
            busy = true;
            Set("checking");
            try
            {
                string json;
                using (var c = Client()) json = await c.DownloadStringTaskAsync(new Uri(FeedUrl));
                var feed = Store.Json.DeserializeObject(json) as Dictionary<string, object> ?? throw new Exception("bad update feed");
                Store.Shared.Set("lastUpdateCheck", DateTime.UtcNow.ToString("o"));
                string version = feed.TryGetValue("version", out var v) ? v as string : null;
                entry = feed.TryGetValue("windows", out var w) ? w as Dictionary<string, object> : null;
                if (version == null) throw new Exception("update feed has no version");
                LatestVersion = version;
                Notes = feed.TryGetValue("notes", out var n) ? n as string : "";
                bool newer = entry != null && UpdateCrypto.Compare(version, CurrentVersion) > 0;
                Set(newer ? "available" : "upToDate");
                return newer;
            }
            catch (Exception e)
            {
                Log.Write("update check: " + e.Message);
                Set("error", "Couldn't check for updates: " + Friendly(e));
                return false;
            }
            finally { busy = false; }
        }

        public async Task Install()
        {
            if (busy || Status != "available" || entry == null) return;
            busy = true;
            string work = Path.Combine(Path.GetTempPath(), "Backgrounds-update-" + Guid.NewGuid().ToString("N"));
            try
            {
                string appDir = Store.AppDir.TrimEnd('\\');
                if (!CanWrite(appDir))
                    throw new Exception("Backgrounds can't write to its folder (" + appDir + "). Move the Backgrounds folder somewhere you own, such as your user folder, and try again.");

                Progress = 0;
                Set("downloading");
                string url = entry["url"] as string, sha = entry["sha256"] as string, sig = entry["signature"] as string;
                byte[] zip;
                using (var c = Client())
                {
                    c.DownloadProgressChanged += (s, e) => { if (e.ProgressPercentage != Progress) { Progress = e.ProgressPercentage; Changed?.Invoke(); } };
                    zip = await c.DownloadDataTaskAsync(new Uri(url));
                }
                UpdateCrypto.Verify(zip, "windows", LatestVersion, sha, sig, PublicKey);

                Set("installing");
                Directory.CreateDirectory(work);
                string zipPath = Path.Combine(work, "update.zip");
                File.WriteAllBytes(zipPath, zip);
                string unpacked = Path.Combine(work, "files");
                ZipFile.ExtractToDirectory(zipPath, unpacked);
                // The zip holds a "Backgrounds" folder.
                string root = File.Exists(Path.Combine(unpacked, "Backgrounds.exe")) ? unpacked : Path.Combine(unpacked, "Backgrounds");
                string newExe = Path.Combine(root, "Backgrounds.exe");
                if (!File.Exists(newExe)) throw new Exception("the update doesn't contain Backgrounds.exe");
                string got = FileVersionInfo.GetVersionInfo(newExe).ProductVersion?.Split('+')[0];
                if (got != LatestVersion) throw new Exception("the update is version " + got + ", expected " + LatestVersion);

                SwapFiles(root, appDir);
                Log.Write("updated to " + LatestVersion + ", restarting");
                Process.Start(new ProcessStartInfo(Path.Combine(appDir, "Backgrounds.exe"), "--updated") { UseShellExecute = false, WorkingDirectory = appDir });
                TrayApp.Current.Quit();
            }
            catch (Exception e)
            {
                Log.Write("update install: " + e);
                Set("error", "The update failed: " + Friendly(e));
                Status = "available";   // allow another try
            }
            finally
            {
                busy = false;
                try { Directory.Delete(work, true); } catch { }
            }
        }

        /// Replaces the app's files. Running files can't be overwritten but can be renamed, so each existing file
        /// is renamed to *.bgold first (cleaned up on the next start); on any failure everything is put back.
        static void SwapFiles(string from, string to)
        {
            var renamed = new List<(string file, string old)>();
            var created = new List<string>();
            try
            {
                foreach (var src in Directory.GetFiles(from, "*", SearchOption.AllDirectories))
                {
                    string dest = Path.Combine(to, src.Substring(from.Length).TrimStart('\\', '/'));
                    Directory.CreateDirectory(Path.GetDirectoryName(dest));
                    if (File.Exists(dest))
                    {
                        string old = dest + ".bgold-" + Guid.NewGuid().ToString("N").Substring(0, 8);
                        File.Move(dest, old);
                        renamed.Add((dest, old));
                    }
                    File.Copy(src, dest);
                    created.Add(dest);
                }
            }
            catch
            {
                foreach (var f in created) try { File.Delete(f); } catch { }
                for (int i = renamed.Count - 1; i >= 0; i--) try { File.Move(renamed[i].old, renamed[i].file); } catch { }
                throw;
            }
        }

        /// Removes files left over from the last update (they were in use then).
        public static void CleanupOldFiles()
        {
            try
            {
                // Not Store.AppDir: touching Store would initialise it (and sync wallpapers) before this cleanup.
                foreach (var f in Directory.GetFiles(AppDomain.CurrentDomain.BaseDirectory, "*.bgold-*", SearchOption.AllDirectories))
                    try { File.Delete(f); } catch { }
            }
            catch { }
        }

        static bool CanWrite(string dir)
        {
            try
            {
                string probe = Path.Combine(dir, ".write-test-" + Guid.NewGuid().ToString("N"));
                File.WriteAllText(probe, "");
                File.Delete(probe);
                return true;
            }
            catch { return false; }
        }

        static string Friendly(Exception e)
        {
            if (e is WebException we && we.Response is HttpWebResponse r)
                return r.StatusCode == HttpStatusCode.NotFound ? "no release has been published yet" : "server said " + (int)r.StatusCode;
            if (e is WebException) return "no connection";
            return e.Message;
        }
    }
}
