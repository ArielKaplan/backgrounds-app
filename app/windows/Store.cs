using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;

namespace Backgrounds
{
    class Wallpaper
    {
        public string Id;       // folder name, or file name for a loose .html file
        public string Name;
        public string File;     // the .html to load
        public string RelPath;  // path of File inside the wallpapers folder, with '/' separators

        public Dictionary<string, object> StateJson()
        {
            string html = "";
            try { html = System.IO.File.ReadAllText(File, Encoding.UTF8); } catch (Exception e) { Log.Write("read " + File + ": " + e.Message); }
            return new Dictionary<string, object>
            {
                ["id"] = Id, ["name"] = Name,
                ["header"] = html.Length > 16384 ? html.Substring(0, 16384) : html,
                ["manifest"] = ManifestText(html),
            };
        }

        /// Raw text of the page's <script type="application/json" id="wallpaper-settings"> block, if any.
        public static string ManifestText(string html)
        {
            int i = html.IndexOf("id=\"wallpaper-settings\"", StringComparison.Ordinal);
            if (i < 0) return null;
            int a = html.IndexOf('>', i);
            if (a < 0) return null;
            int b = html.IndexOf("</script>", a, StringComparison.Ordinal);
            return b > a ? html.Substring(a + 1, b - a - 1) : null;
        }
    }

    /// Settings live in %APPDATA%\Backgrounds\config.json. `Settings` is owned by the settings page
    /// (app/shared/settings.html); native code only reads a few fields.
    class Store
    {
        // Order matters: static fields initialise top to bottom, and the Store constructor uses Json.
        public static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 256 };
        public static readonly Store Shared = new Store();

        public readonly string SupportDir, DataDir;
        readonly string configPath;
        public string Folder { get; private set; }
        public Dictionary<string, object> Settings;
        /// Native-only state kept next to the settings (update check times, known built-in wallpapers, ...).
        readonly Dictionary<string, object> cfg;

        public static string DefaultFolder =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Backgrounds");
        public static string AppDir => AppDomain.CurrentDomain.BaseDirectory;
        public static string BundledWallpapers => Path.Combine(AppDir, "Wallpapers");

        Store()
        {
            SupportDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Backgrounds");
            DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Backgrounds");
            Directory.CreateDirectory(SupportDir);
            Directory.CreateDirectory(DataDir);
            configPath = Path.Combine(SupportDir, "config.json");

            cfg = null;
            try { if (System.IO.File.Exists(configPath)) cfg = Json.DeserializeObject(System.IO.File.ReadAllText(configPath, Encoding.UTF8)) as Dictionary<string, object>; }
            catch (Exception e) { Log.Write("config.json unreadable, starting fresh: " + e.Message); }
            cfg ??= new Dictionary<string, object>();
            Folder = cfg.TryGetValue("folder", out var f) && f is string fs && fs.Length > 0 ? fs : DefaultFolder;
            Settings = cfg.TryGetValue("settings", out var s) && s is Dictionary<string, object> sd ? sd : new Dictionary<string, object>();

            // First run (or the folder was deleted): create it and copy in the built-in wallpapers.
            if (!Directory.Exists(Folder))
            {
                try { Directory.CreateDirectory(Folder); } catch (Exception e) { Log.Write("create folder: " + e.Message); }
                RestoreBuiltins();
            }
            // After an app update: bring in new built-in wallpapers and update the unedited copies.
            if (Get("syncedVersion") as string != Updater.CurrentVersion) SyncBuiltins();
            if (!Settings.ContainsKey("wallpaper"))
            {
                var all = Scan();
                var first = all.FirstOrDefault(w => w.Id == "Aquarium") ?? all.FirstOrDefault();
                if (first != null) Settings["wallpaper"] = first.Id;
            }
            Save();
        }

        public void Save()
        {
            try
            {
                cfg["folder"] = Folder;
                cfg["settings"] = Settings;
                string tmp = configPath + ".tmp";
                System.IO.File.WriteAllText(tmp, Json.Serialize(cfg), new UTF8Encoding(false));
                if (System.IO.File.Exists(configPath)) System.IO.File.Replace(tmp, configPath, null);
                else System.IO.File.Move(tmp, configPath);
            }
            catch (Exception e) { Log.Write("save config: " + e.Message); }
        }

        public void SetFolder(string path) { Folder = path; Save(); }

        public object Get(string key) => cfg.TryGetValue(key, out var v) ? v : null;
        public void Set(string key, object value) { cfg[key] = value; Save(); }

        /// Copies built-in wallpapers that are missing from the folder. Never overwrites the user's copies.
        public List<string> RestoreBuiltins()
        {
            var added = new List<string>();
            if (!Directory.Exists(BundledWallpapers)) return added;
            Directory.CreateDirectory(Folder);
            var known = KnownBuiltins();
            foreach (var src in Directory.GetDirectories(BundledWallpapers).OrderBy(x => x))
            {
                string name = Path.GetFileName(src), dest = Path.Combine(Folder, name);
                known.Add(name);
                if (Directory.Exists(dest) || System.IO.File.Exists(dest)) continue;
                try { CopyDir(src, dest); added.Add(name); } catch (Exception e) { Log.Write("copy " + name + ": " + e.Message); }
            }
            cfg["knownBuiltins"] = known.ToList();
            Save();
            return added;
        }

        /// Built-in wallpapers this user has been given before (so one they deleted isn't brought back).
        HashSet<string> KnownBuiltins()
        {
            if (Get("knownBuiltins") is System.Collections.IEnumerable list && !(list is string))
                return new HashSet<string>(list.OfType<string>());
            // Upgrading from 1.0.0, which didn't record this: whatever built-ins are in the folder now.
            var set = new HashSet<string>();
            if (Directory.Exists(BundledWallpapers))
                foreach (var src in Directory.GetDirectories(BundledWallpapers))
                    if (Directory.Exists(Path.Combine(Folder, Path.GetFileName(src)))) set.Add(Path.GetFileName(src));
            return set;
        }

        /// After an update: adds new built-in wallpapers, and replaces copies the user never edited (every file
        /// matches some version we shipped, per wallpaper-history.json) with the new version. Edited copies and
        /// built-ins the user deleted are left alone. Returns what changed.
        public List<string> SyncBuiltins()
        {
            var changed = new List<string>();
            try
            {
                if (!Directory.Exists(BundledWallpapers)) return changed;
                Directory.CreateDirectory(Folder);
                var history = LoadHistory();
                var known = KnownBuiltins();
                foreach (var src in Directory.GetDirectories(BundledWallpapers).OrderBy(x => x))
                {
                    string name = Path.GetFileName(src), dest = Path.Combine(Folder, name);
                    if (!Directory.Exists(dest))
                    {
                        if (!known.Contains(name) && !System.IO.File.Exists(dest)) { CopyDir(src, dest); changed.Add(name + " (new)"); }
                    }
                    else if (Unedited(src, dest, name, history))
                    {
                        bool any = false;
                        foreach (var f in Directory.GetFiles(src, "*", SearchOption.AllDirectories))
                        {
                            string target = Path.Combine(dest, f.Substring(src.Length + 1));
                            if (System.IO.File.Exists(target) && Fingerprint(target) == Fingerprint(f)) continue;
                            Directory.CreateDirectory(Path.GetDirectoryName(target));
                            System.IO.File.Copy(f, target, true);
                            any = true;
                        }
                        if (any) changed.Add(name + " (updated)");
                    }
                    else Log.Write("sync: keeping edited wallpaper " + name);
                    known.Add(name);
                }
                cfg["knownBuiltins"] = known.ToList();
                cfg["syncedVersion"] = Updater.CurrentVersion;
                Save();
                if (changed.Count > 0) Log.Write("sync: " + string.Join(", ", changed));
            }
            catch (Exception e) { Log.Write("sync built-ins: " + e.Message); }
            return changed;
        }

        static bool Unedited(string src, string dest, string name, Dictionary<string, HashSet<string>> history)
        {
            foreach (var f in Directory.GetFiles(src, "*", SearchOption.AllDirectories))
            {
                string rel = f.Substring(src.Length + 1).Replace('\\', '/');
                string mine = Path.Combine(dest, rel);
                if (!System.IO.File.Exists(mine)) continue;                // a file new in this version
                string h = Fingerprint(mine);
                if (h == Fingerprint(f)) continue;
                if (history.TryGetValue(name + "/" + rel, out var known) && known.Contains(h)) continue;
                return false;
            }
            return true;
        }

        static Dictionary<string, HashSet<string>> LoadHistory()
        {
            var result = new Dictionary<string, HashSet<string>>();
            try
            {
                string path = Path.Combine(AppDir, "wallpaper-history.json");
                if (!System.IO.File.Exists(path)) return result;
                if (Json.DeserializeObject(System.IO.File.ReadAllText(path)) is Dictionary<string, object> d)
                    foreach (var kv in d)
                        if (kv.Value is System.Collections.IEnumerable list)
                            result[kv.Key] = new HashSet<string>(list.OfType<string>());
            }
            catch (Exception e) { Log.Write("wallpaper-history.json: " + e.Message); }
            return result;
        }

        /// SHA-256 of the content with CRLF normalised to LF (git may check files out either way).
        public static string Fingerprint(string path)
        {
            byte[] data = System.IO.File.ReadAllBytes(path);
            var norm = new List<byte>(data.Length);
            for (int i = 0; i < data.Length; i++)
                if (!(data[i] == 13 && i + 1 < data.Length && data[i + 1] == 10)) norm.Add(data[i]);
            using (var sha = System.Security.Cryptography.SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(norm.ToArray())).Replace("-", "").ToLowerInvariant();
        }

        static void CopyDir(string src, string dest)
        {
            Directory.CreateDirectory(dest);
            foreach (var f in Directory.GetFiles(src)) System.IO.File.Copy(f, Path.Combine(dest, Path.GetFileName(f)));
            foreach (var d in Directory.GetDirectories(src)) CopyDir(d, Path.Combine(dest, Path.GetFileName(d)));
        }

        public List<Wallpaper> Scan()
        {
            var list = new List<Wallpaper>();
            try
            {
                foreach (var dir in Directory.GetDirectories(Folder))
                {
                    string name = Path.GetFileName(dir);
                    if (name.StartsWith(".")) continue;
                    string index = Path.Combine(dir, "index.html");
                    if (System.IO.File.Exists(index))
                        list.Add(new Wallpaper { Id = name, Name = DisplayName(name), File = index, RelPath = name + "/index.html" });
                }
                foreach (var file in Directory.GetFiles(Folder))
                {
                    string ext = Path.GetExtension(file).ToLowerInvariant();
                    if (ext != ".html" && ext != ".htm") continue;
                    string name = Path.GetFileName(file);
                    list.Add(new Wallpaper { Id = name, Name = DisplayName(Path.GetFileNameWithoutExtension(file)), File = file, RelPath = name });
                }
            }
            catch (Exception e) { Log.Write("scan: " + e.Message); }
            return list.OrderBy(w => w.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        }

        public static string DisplayName(string s) => s.StartsWith("Wallpaper - ") ? s.Substring("Wallpaper - ".Length) : s;

        // ---- typed views of the page-owned settings
        public string Arrangement => Settings.TryGetValue("arrangement", out var v) && v is string s ? s : "same";
        public string MainWallpaper => Settings.TryGetValue("wallpaper", out var v) ? v as string : null;
        public bool Paused
        {
            get => Bool("paused", false);
            set { Settings["paused"] = value; Save(); }
        }
        public bool PauseWhenCovered => Bool("pauseWhenCovered", true);
        public bool PauseOnBattery => Bool("pauseOnBattery", true);
        public bool AutoUpdateCheck => Bool("autoUpdateCheck", true);

        bool Bool(string key, bool dflt)
        {
            if (!Settings.TryGetValue(key, out var v) || v == null) return dflt;
            if (v is bool b) return b;
            try { return Convert.ToDouble(v) != 0; } catch { return dflt; }
        }

        public string Hash(string wallpaper)
        {
            if (Settings.TryGetValue("params", out var p) && p is Dictionary<string, object> all &&
                all.TryGetValue(wallpaper, out var e) && e is Dictionary<string, object> entry &&
                entry.TryGetValue("hash", out var h) && h is string hs) return hs;
            return "";
        }

        /// The wallpaper a screen should show, or null for the normal Windows wallpaper.
        public string WallpaperForScreen(string screenId, bool primary)
        {
            switch (Arrangement)
            {
                case "perScreen":
                    if (Settings.TryGetValue("screens", out var s) && s is Dictionary<string, object> screens && screens.ContainsKey(screenId))
                        return screens[screenId] as string;    // null = explicitly none
                    return MainWallpaper;
                case "main":
                    return primary ? MainWallpaper : null;
                default:
                    return MainWallpaper;
            }
        }

        /// Tray menu shortcut: show one wallpaper (on one screen in per-screen mode).
        public void Choose(string wallpaper, string screenId)
        {
            if (Arrangement == "perScreen" && screenId != null)
            {
                if (!(Settings.TryGetValue("screens", out var s) && s is Dictionary<string, object> screens))
                    Settings["screens"] = screens = new Dictionary<string, object>();
                screens[screenId] = wallpaper;
            }
            else Settings["wallpaper"] = wallpaper;
            Save();
        }
    }

    static class Log
    {
        static readonly object Gate = new object();
        public static void Write(string msg)
        {
            try
            {
                lock (Gate)
                {
                    string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Backgrounds");
                    Directory.CreateDirectory(dir);
                    string path = Path.Combine(dir, "log.txt");
                    var fi = new FileInfo(path);
                    if (fi.Exists && fi.Length > 512 * 1024) fi.Delete();
                    System.IO.File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss ") + msg + Environment.NewLine);
                }
            }
            catch { }
            System.Diagnostics.Debug.WriteLine(msg);
        }
    }
}
