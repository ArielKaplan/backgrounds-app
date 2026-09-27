import AppKit
import CryptoKit

/// A wallpaper found in the wallpapers folder: a sub-folder with an index.html, or a loose .html file.
struct Wallpaper {
    let id: String          // folder name, or file name for a loose .html file
    let name: String
    let file: URL           // the .html to load
    let root: URL           // what the web view may read (the wallpapers folder)

    /// Raw text of the page's <script type="application/json" id="wallpaper-settings"> block, if any.
    func manifestText(_ html: String) -> String? {
        guard let marker = html.range(of: "id=\"wallpaper-settings\"") else { return nil }
        guard let open = html.range(of: ">", range: marker.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else { return nil }
        return String(html[open.upperBound..<close.lowerBound])
    }

    func stateJSON() -> [String: Any] {
        let html = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var d: [String: Any] = ["id": id, "name": name, "header": String(html.prefix(16384))]
        d["manifest"] = manifestText(html) ?? NSNull()
        return d
    }
}

/// Settings live in ~/Library/Application Support/Backgrounds/config.json.
/// `settings` is owned by the settings page (see app/shared/settings.html); native code only reads a few fields.
final class Store {
    static let shared = Store()

    let supportDir: URL
    private let configURL: URL
    private(set) var folder: URL
    var settings: [String: Any]
    /// Native-only state kept next to the settings (update check times, known built-in wallpapers, ...).
    private(set) var extra: [String: Any] = [:]

    static var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Backgrounds", isDirectory: true)
    }
    static var bundledWallpapers: URL? { Bundle.main.resourceURL?.appendingPathComponent("Wallpapers", isDirectory: true) }

    private init() {
        let fm = FileManager.default
        supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Backgrounds", isDirectory: true)
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        configURL = supportDir.appendingPathComponent("config.json")

        var cfg: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { cfg = obj }
        if let path = cfg["folder"] as? String, !path.isEmpty {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folder = Store.defaultFolder
        }
        settings = cfg["settings"] as? [String: Any] ?? [:]
        extra = cfg.filter { $0.key != "folder" && $0.key != "settings" }

        // First run (or the folder was deleted): create it and copy in the built-in wallpapers.
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = restoreBuiltins()
        }
        // After an app update: bring in new built-in wallpapers and update the unedited copies.
        if extra["syncedVersion"] as? String != Updater.currentVersion { syncBuiltins() }
        if settings["wallpaper"] == nil, let first = scan().first(where: { $0.id == "Aquarium" }) ?? scan().first {
            settings["wallpaper"] = first.id
        }
        save()
    }

    func save() {
        var cfg = extra
        cfg["folder"] = folder.path
        cfg["settings"] = settings
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    func setFolder(_ url: URL) {
        folder = url
        save()
    }

    func setExtra(_ key: String, _ value: Any?) {
        extra[key] = value
        save()
    }

    /// Copies built-in wallpapers that are missing from the folder. Never overwrites the user's copies.
    @discardableResult
    func restoreBuiltins() -> [String] {
        guard let src = Store.bundledWallpapers else { return [] }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var added: [String] = []
        var known = knownBuiltins()
        for item in Self.bundledFolders() {
            let dest = folder.appendingPathComponent(item.lastPathComponent)
            known.insert(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { continue }
            if (try? fm.copyItem(at: item, to: dest)) != nil { added.append(item.lastPathComponent) }
        }
        extra["knownBuiltins"] = Array(known).sorted()
        save()
        return added
    }

    private static func bundledFolders() -> [URL] {
        guard let src = bundledWallpapers else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Built-in wallpapers this user has been given before (so one they deleted isn't brought back).
    private func knownBuiltins() -> Set<String> {
        if let list = extra["knownBuiltins"] as? [String] { return Set(list) }
        // Upgrading from 1.0.0, which didn't record this: whatever built-ins are in the folder now.
        return Set(Self.bundledFolders().map { $0.lastPathComponent }
            .filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) })
    }

    /// After an update: adds new built-in wallpapers, and replaces copies the user never edited (every file
    /// matches some version we shipped, per wallpaper-history.json) with the new version. Edited copies and
    /// built-ins the user deleted are left alone.
    @discardableResult
    func syncBuiltins() -> [String] {
        let fm = FileManager.default
        var changed: [String] = []
        let history = Self.loadHistory()
        var known = knownBuiltins()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for src in Self.bundledFolders() {
            let name = src.lastPathComponent
            let dest = folder.appendingPathComponent(name)
            defer { known.insert(name) }
            if !fm.fileExists(atPath: dest.path) {
                if !known.contains(name), (try? fm.copyItem(at: src, to: dest)) != nil { changed.append(name + " (new)") }
                continue
            }
            let files = Self.files(in: src)
            let unedited = files.allSatisfy { rel in
                let mine = dest.appendingPathComponent(rel)
                guard fm.fileExists(atPath: mine.path), let h = Self.fingerprint(mine) else { return true }   // new file
                return h == Self.fingerprint(src.appendingPathComponent(rel)) || (history[name + "/" + rel]?.contains(h) ?? false)
            }
            guard unedited else { NSLog("Backgrounds: keeping edited wallpaper \(name)"); continue }
            var any = false
            for rel in files {
                let from = src.appendingPathComponent(rel), to = dest.appendingPathComponent(rel)
                if let a = Self.fingerprint(to), a == Self.fingerprint(from) { continue }
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: to)
                if (try? fm.copyItem(at: from, to: to)) != nil { any = true }
            }
            if any { changed.append(name + " (updated)") }
        }
        extra["knownBuiltins"] = Array(known).sorted()
        extra["syncedVersion"] = Updater.currentVersion
        save()
        if !changed.isEmpty { NSLog("Backgrounds: synced built-in wallpapers: \(changed.joined(separator: ", "))") }
        return changed
    }

    private static func files(in dir: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        let base = dir.standardizedFileURL.path
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out.append(String(url.standardizedFileURL.path.dropFirst(base.count + 1)))
        }
        return out
    }

    private static func loadHistory() -> [String: Set<String>] {
        guard let url = Bundle.main.url(forResource: "wallpaper-history", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return [:] }
        return obj.mapValues { Set($0) }
    }

    /// SHA-256 of the content with CRLF normalised to LF (git may check files out either way).
    static func fingerprint(_ url: URL) -> String? {
        guard var data = try? Data(contentsOf: url) else { return nil }
        if data.contains(13) {
            var out = Data(capacity: data.count)
            let bytes = [UInt8](data)
            for i in 0..<bytes.count where !(bytes[i] == 13 && i + 1 < bytes.count && bytes[i + 1] == 10) { out.append(bytes[i]) }
            data = out
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func scan() -> [Wallpaper] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var out: [Wallpaper] = []
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = item.lastPathComponent
            if isDir {
                let index = item.appendingPathComponent("index.html")
                if fm.fileExists(atPath: index.path) {
                    out.append(Wallpaper(id: name, name: Store.displayName(name), file: index, root: folder))
                }
            } else if ["html", "htm"].contains(item.pathExtension.lowercased()) {
                out.append(Wallpaper(id: name, name: Store.displayName(item.deletingPathExtension().lastPathComponent),
                                     file: item, root: folder))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func displayName(_ s: String) -> String {
        s.hasPrefix("Wallpaper - ") ? String(s.dropFirst("Wallpaper - ".count)) : s
    }

    // ---- typed views of the page-owned settings
    var arrangement: String { settings["arrangement"] as? String ?? "same" }
    var mainWallpaper: String? { settings["wallpaper"] as? String }
    var paused: Bool {
        get { settings["paused"] as? Bool ?? false }
        set { settings["paused"] = newValue; save() }
    }
    var pauseWhenCovered: Bool { settings["pauseWhenCovered"] as? Bool ?? true }
    /// Off unless the user turns it on (1.0's "pauseOnBattery" defaulted to on and is ignored).
    var freezeOnBattery: Bool { settings["freezeOnBattery"] as? Bool ?? false }
    var autoUpdateCheck: Bool { settings["autoUpdateCheck"] as? Bool ?? true }

    func hash(for wallpaper: String) -> String {
        let params = settings["params"] as? [String: Any]
        let entry = params?[wallpaper] as? [String: Any]
        return entry?["hash"] as? String ?? ""
    }

    /// The wallpaper a screen should show, or nil for the normal system wallpaper.
    func wallpaper(forScreen id: String, primary: Bool) -> String? {
        switch arrangement {
        case "perScreen":
            let screens = settings["screens"] as? [String: Any] ?? [:]
            if let v = screens[id] { return v as? String }   // NSNull = explicitly none
            return mainWallpaper
        case "main":
            return primary ? mainWallpaper : nil
        default:
            return mainWallpaper
        }
    }

    /// Menu bar shortcut: show one wallpaper (on a specific screen in per-screen mode).
    func choose(_ wallpaper: String?, screen: String?) {
        if arrangement == "perScreen", let screen = screen {
            var screens = settings["screens"] as? [String: Any] ?? [:]
            screens[screen] = wallpaper ?? NSNull()
            settings["screens"] = screens
        } else {
            settings["wallpaper"] = wallpaper ?? NSNull()
        }
        save()
    }
}
