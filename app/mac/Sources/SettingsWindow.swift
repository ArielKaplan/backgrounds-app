import AppKit
import WebKit
import ServiceManagement

/// The settings window: app/shared/settings.html in a web view, talking to us through `bridge` messages.
final class SettingsWindowController: NSObject, WKScriptMessageHandler, NSWindowDelegate, WKNavigationDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var webView: WKWebView?

    private var focus: String?

    /// `focus`: "update" opens the page on the update section.
    func show(focus: String? = nil) {
        self.focus = focus
        if let f = focus, window != nil { send(["event": "focus", "data": f]) }
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    private func build() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakHandler(self), name: "bridge")
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 940, height: 680), configuration: cfg)
        wv.navigationDelegate = self
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Backgrounds"
        w.minSize = NSSize(width: 760, height: 480)
        w.isReleasedWhenClosed = false
        w.contentView = wv
        w.delegate = self
        w.setFrameAutosaveName("BackgroundsSettings")
        if !w.setFrameUsingName("BackgroundsSettings") { w.center() }
        window = w
        webView = wv
        if let page = Bundle.main.url(forResource: "settings", withExtension: "html") {
            wv.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            wv.loadHTMLString("<p style='font:14px system-ui;padding:30px'>settings.html is missing from the app bundle.</p>", baseURL: nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Free the web view while settings are closed.
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
        webView = nil
        window?.contentView = nil
        window = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Links (if any) open in the browser, not in the settings window.
        if let url = navigationAction.request.url, !url.isFileURL, url.scheme != "about" {
            NSWorkspace.shared.open(url); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    /// Pushes fresh state to the page (e.g. after a change from the menu bar, a screen or power change).
    func pushState() {
        guard webView != nil else { return }
        send(["event": "state", "data": Self.state()])
    }

    // MARK: bridge

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        let id = body["id"] ?? NSNull()
        let args = body["args"] as? [String: Any] ?? [:]
        handle(cmd, args) { result in
            switch result {
            case .success(let value): self.send(["reply": id, "ok": true, "result": value ?? NSNull()])
            case .failure(let err): self.send(["reply": id, "ok": false, "error": err.localizedDescription])
            }
        }
    }

    private func send(_ msg: [String: Any]) {
        guard let wv = webView,
              let data = try? JSONSerialization.data(withJSONObject: msg),
              let json = String(data: data, encoding: .utf8) else { return }
        wv.evaluateJavaScript("window.__bridgeReceive(\(json))", completionHandler: nil)
    }

    struct BridgeError: LocalizedError { let errorDescription: String? }

    private func handle(_ cmd: String, _ args: [String: Any], reply: @escaping (Result<Any?, Error>) -> Void) {
        let store = Store.shared
        let manager = WallpaperManager.shared
        switch cmd {
        case "getState":
            reply(.success(Self.state()))
            if let f = focus { focus = nil; send(["event": "focus", "data": f]) }
        case "checkForUpdates":
            Updater.shared.check()             // progress arrives as "state" events
            reply(.success(Updater.shared.stateJSON()))
        case "installUpdate":
            Updater.shared.install()
            reply(.success(Updater.shared.stateJSON()))
        case "setSettings":
            guard let s = args["settings"] as? [String: Any] else { reply(.failure(BridgeError(errorDescription: "bad settings"))); return }
            store.settings = s
            store.save()
            manager.apply()
            AppDelegate.shared?.rebuildMenu()
            reply(.success(Self.state()))
        case "setLaunchAtLogin":
            let (enabled, message) = LoginItem.set(args["enabled"] as? Bool ?? false)
            var r: [String: Any] = ["enabled": enabled]
            if let m = message { r["message"] = m }
            reply(.success(r))
        case "chooseFolder":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = store.folder
            panel.prompt = "Use Folder"
            panel.message = "Choose the folder that holds your wallpapers (one folder with an index.html per wallpaper)."
            if let w = window {
                panel.beginSheetModal(for: w) { resp in
                    guard resp == .OK, let url = panel.url else { reply(.success(nil)); return }
                    store.setFolder(url)
                    manager.apply(force: true)
                    AppDelegate.shared?.rebuildMenu()
                    reply(.success(Self.state()))
                }
            } else { reply(.success(nil)) }
        case "openFolder":
            NSWorkspace.shared.open(store.folder)
            reply(.success(nil))
        case "openWallpaperFolder":
            if let id = args["id"] as? String, let wp = store.scan().first(where: { $0.id == id }) {
                NSWorkspace.shared.activateFileViewerSelecting([wp.file])
            }
            reply(.success(nil))
        case "restoreBuiltins":
            let added = store.restoreBuiltins()
            manager.apply()
            AppDelegate.shared?.rebuildMenu()
            reply(.success(["added": added, "state": Self.state()]))
        case "reload":
            manager.apply(force: true, only: args["wallpaper"] as? String)
            AppDelegate.shared?.rebuildMenu()
            reply(.success(Self.state()))
        case "reloadOnce":
            guard let wp = args["wallpaper"] as? String, let extra = args["extra"] as? String else { reply(.success(nil)); return }
            let n = manager.reloadOnce(wp, extra: extra)
            reply(.success(["message": n > 0 ? "Done" : "It only works while this wallpaper is showing"]))
        case "closeSettings":
            window?.performClose(nil)
            reply(.success(nil))
        case "quit":
            reply(.success(nil))
            DispatchQueue.main.async { NSApp.terminate(nil) }
        default:
            reply(.failure(BridgeError(errorDescription: "unknown command \(cmd)")))
        }
    }

    static func state() -> [String: Any] {
        let store = Store.shared
        let screens: [[String: Any]] = WallpaperManager.screens().map {
            ["id": $0.id, "name": $0.name, "primary": $0.primary,
             "width": Int($0.screen.frame.width), "height": Int($0.screen.frame.height)]
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return [
            "platform": "mac",
            "version": version,
            "folder": store.folder.path,
            "screens": screens,
            "wallpapers": store.scan().map { $0.stateJSON() },
            "settings": store.settings,
            "launchAtLogin": LoginItem.isEnabled,
            "onBattery": WallpaperManager.shared.onBattery,
            "update": Updater.shared.stateJSON(),
        ]
    }
}

/// WKUserContentController keeps its handlers alive; this avoids a retain cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

/// "Start at login": the system login item (SMAppService). Unsigned apps can be refused that, so there is a
/// LaunchAgent fallback, which macOS also lists under System Settings > General > Login Items.
enum LoginItem {
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Bundle.main.bundleIdentifier ?? "Backgrounds").login.plist")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func set(_ on: Bool) -> (Bool, String?) {
        if on {
            do {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    return (true, "Allow Backgrounds in System Settings › Login Items")
                }
                return (true, nil)
            } catch {
                NSLog("Backgrounds: SMAppService register failed (\(error)); using a LaunchAgent")
                return writeAgent() ? (true, nil) : (false, "Couldn't add the login item: \(error.localizedDescription)")
            }
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: agentURL)
            return (isEnabled, nil)
        }
    }

    private static func writeAgent() -> Bool {
        let plist: [String: Any] = [
            "Label": (Bundle.main.bundleIdentifier ?? "Backgrounds") + ".login",
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
            return true
        } catch { return false }
    }
}
