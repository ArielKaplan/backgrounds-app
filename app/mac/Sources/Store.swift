import AppKit

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

        // First run (or the folder was deleted): create it and copy in the built-in wallpapers.
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = restoreBuiltins()
        }
        if settings["wallpaper"] == nil, let first = scan().first(where: { $0.id == "Aquarium" }) ?? scan().first {
            settings["wallpaper"] = first.id
        }
        save()
    }

    func save() {
        let cfg: [String: Any] = ["folder": folder.path, "settings": settings]
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    func setFolder(_ url: URL) {
        folder = url
        save()
    }

    /// Copies built-in wallpapers that are missing from the folder. Never overwrites the user's copies.
    @discardableResult
    func restoreBuiltins() -> [String] {
        guard let src = Store.bundledWallpapers else { return [] }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var added: [String] = []
        let items = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let dest = folder.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { continue }
            if (try? fm.copyItem(at: item, to: dest)) != nil { added.append(item.lastPathComponent) }
        }
        return added
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
    var pauseOnBattery: Bool { settings["pauseOnBattery"] as? Bool ?? true }

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
