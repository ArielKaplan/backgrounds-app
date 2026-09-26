import AppKit

/// Backgrounds for macOS: shows HTML wallpapers behind the desktop icons (like Plash).
/// Menu bar only (LSUIElement); settings are app/shared/settings.html.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.shared = self
        buildMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Backgrounds")
            img?.isTemplate = true
            button.image = img
        }
        rebuildMenu()
        WallpaperManager.shared.onChange = { [weak self] in
            self?.rebuildMenu()
            SettingsWindowController.shared.pushState()
        }
        WallpaperManager.shared.apply()

        // Updates: check shortly after start, then hourly (it only goes to the network once a day).
        Updater.shared.onChange = { [weak self] in
            self?.rebuildMenu()
            SettingsWindowController.shared.pushState()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.maybeCheckForUpdate() }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.maybeCheckForUpdate() }

        // First launch: open settings so there's something to see besides the wallpaper.
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            SettingsWindowController.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Double-clicking the app again opens settings (handy if the menu bar icon is hidden by the notch).
        SettingsWindowController.shared.show()
        return true
    }

    func applicationWillTerminate(_ note: Notification) {
        WallpaperManager.shared.tearDownAll()
    }

    // MARK: updates

    private func maybeCheckForUpdate() {
        let store = Store.shared
        guard Updater.configured, store.autoUpdateCheck else { return }
        if let s = store.extra["lastUpdateCheck"] as? String, let last = ISO8601DateFormatter().date(from: s),
           Date().timeIntervalSince(last) < 23 * 3600 { return }
        Updater.shared.check { newer in
            guard newer, let v = Updater.shared.latestVersion else { return }
            if store.extra["updateAutoInstall"] as? Bool == true { Updater.shared.install(); return }
            guard store.extra["notifiedVersion"] as? String != v else { return }   // asked about this version already
            store.setExtra("notifiedVersion", v)
            self.askToInstall(v)
        }
    }

    private func askToInstall(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "Backgrounds \(version) is available"
        let notes = Updater.shared.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = (notes.isEmpty ? "" : notes + "\n\n") + "You have \(Updater.currentVersion). Install it now? Backgrounds will restart."
        alert.addButton(withTitle: "Install & Restart")
        alert.addButton(withTitle: "Later")
        if let img = NSImage(named: NSImage.applicationIconName) { alert.icon = img }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Updater.shared.install()
            SettingsWindowController.shared.show(focus: "update")    // shows download progress / any error
        }
    }

    @objc private func checkForUpdates() {
        SettingsWindowController.shared.show(focus: "update")
        Updater.shared.check()
    }

    @objc private func showUpdate() { SettingsWindowController.shared.show(focus: "update") }

    // MARK: menus

    /// A main menu is still needed in a menu bar app: it provides Cmd-C/V/X/A/Z/W/Q in the settings window.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Backgrounds", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func rebuildMenu() {
        let store = Store.shared
        let menu = NSMenu()
        menu.delegate = self
        let wallpapers = store.scan()
        let screens = WallpaperManager.screens()

        if Updater.shared.status == "available", let v = Updater.shared.latestVersion {
            let up = NSMenuItem(title: "Install Update \(v)…", action: #selector(showUpdate), keyEquivalent: "")
            up.target = self
            up.attributedTitle = NSAttributedString(string: up.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            menu.addItem(up)
            menu.addItem(.separator())
        }

        func list(screen: WallpaperManager.ScreenInfo?) -> NSMenu {
            let sub = NSMenu()
            let current = screen.map { store.wallpaper(forScreen: $0.id, primary: $0.primary) } ?? store.mainWallpaper
            for wp in wallpapers {
                let item = NSMenuItem(title: wp.name, action: #selector(chooseWallpaper(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["id": wp.id, "screen": screen?.id as Any]
                item.state = wp.id == current ? .on : .off
                sub.addItem(item)
            }
            if wallpapers.isEmpty { sub.addItem(withTitle: "No wallpapers in the folder", action: nil, keyEquivalent: "") }
            sub.addItem(.separator())
            let none = NSMenuItem(title: "None", action: #selector(chooseWallpaper(_:)), keyEquivalent: "")
            none.target = self
            none.representedObject = ["screen": screen?.id as Any]
            none.state = current == nil ? .on : .off
            sub.addItem(none)
            return sub
        }

        if store.arrangement == "perScreen" && screens.count > 1 {
            for s in screens {
                let item = NSMenuItem(title: s.name, action: nil, keyEquivalent: "")
                item.submenu = list(screen: s)
                menu.addItem(item)
            }
        } else {
            let item = NSMenuItem(title: "Wallpaper", action: nil, keyEquivalent: "")
            item.submenu = list(screen: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let pauseTitle: String
        if store.paused { pauseTitle = "Resume" }
        else if WallpaperManager.shared.pausedByBattery { pauseTitle = "Pause (paused on battery)" }
        else { pauseTitle = "Pause" }
        menu.addItem(withTitle: pauseTitle, action: #selector(togglePause), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Open Wallpapers Folder", action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Backgrounds", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {}

    @objc private func chooseWallpaper(_ sender: NSMenuItem) {
        let info = sender.representedObject as? [String: Any] ?? [:]
        Store.shared.choose(info["id"] as? String, screen: info["screen"] as? String)
        changed()
    }

    @objc private func togglePause() {
        Store.shared.paused.toggle()
        changed()
    }

    @objc private func reload() {
        WallpaperManager.shared.apply(force: true)
        changed()
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func openFolder() { NSWorkspace.shared.open(Store.shared.folder) }

    private func changed() {
        WallpaperManager.shared.apply()
        rebuildMenu()
        SettingsWindowController.shared.pushState()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
