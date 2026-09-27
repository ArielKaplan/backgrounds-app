import AppKit
import IOKit.ps

/// Keeps one WallpaperWindow per screen in line with the settings.
final class WallpaperManager {
    static let shared = WallpaperManager()
    private var windows: [String: WallpaperWindow] = [:]
    private(set) var onBattery = Power.onBattery()
    var onChange: (() -> Void)?     // settings window / menu refresh

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // Screens are still settling right after a change; apply now and once more shortly after.
            self?.apply()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.apply() }
        }
        Power.observe { [weak self] in
            guard let self = self else { return }
            let now = Power.onBattery()
            if now != self.onBattery { self.onBattery = now; self.apply(); self.onChange?() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.onBattery = Power.onBattery()
            self.apply()
        }
    }

    struct ScreenInfo { let id: String; let name: String; let primary: Bool; let screen: NSScreen }

    static func screens() -> [ScreenInfo] {
        let all = NSScreen.screens
        return all.enumerated().map { i, s in
            ScreenInfo(id: screenID(s), name: s.localizedName, primary: i == 0, screen: s)
        }
    }

    /// Stable across launches and re-plugging: the display's UUID (falls back to its number).
    static func screenID(_ s: NSScreen) -> String {
        guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return s.localizedName }
        let did = CGDirectDisplayID(num.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, uuid) { return str as String }
        return String(did)
    }

    var pausedByBattery: Bool { Store.shared.freezeOnBattery && onBattery }

    func apply(force: Bool = false, only wallpaperID: String? = nil) {
        let store = Store.shared
        let wallpapers = Dictionary(store.scan().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let infos = Self.screens()
        var seen = Set<String>()
        let freeze = store.paused || pausedByBattery
        for info in infos {
            seen.insert(info.id)
            guard let id = store.wallpaper(forScreen: info.id, primary: info.primary), let wp = wallpapers[id] else {
                windows.removeValue(forKey: info.id)?.tearDown()
                continue
            }
            let win: WallpaperWindow
            if let w = windows[info.id] { win = w } else {
                win = WallpaperWindow(screen: info.screen, screenID: info.id)
                windows[info.id] = win
            }
            win.place(on: info.screen)
            win.pauseWhenCovered = store.pauseWhenCovered
            let forceThis = force && (wallpaperID == nil || wallpaperID == id)
            win.show(wallpaper: wp, hash: store.hash(for: id), force: forceThis)
            if !win.isVisible { win.orderBack(nil) }
            win.setFrozen(freeze)
        }
        for (id, win) in windows where !seen.contains(id) {
            win.tearDown()
            windows.removeValue(forKey: id)
        }
    }

    /// Loads a wallpaper once with extra options (e.g. "reset"), on every screen that shows it.
    func reloadOnce(_ wallpaperID: String, extra: String) -> Int {
        guard let wp = Store.shared.scan().first(where: { $0.id == wallpaperID }) else { return 0 }
        var n = 0
        for win in windows.values where win.wallpaper?.id == wallpaperID {
            win.show(wallpaper: wp, hash: Store.shared.hash(for: wallpaperID), extra: extra, force: true)
            n += 1
        }
        return n
    }

    func tearDownAll() {
        windows.values.forEach { $0.tearDown() }
        windows.removeAll()
    }
}

enum Power {
    static func onBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"   // kIOPMBatteryPowerKey
    }

    private static var handlers: [() -> Void] = []
    private static var source: CFRunLoopSource?

    /// Calls `handler` on the main thread whenever the power source changes (plugged / unplugged).
    static func observe(_ handler: @escaping () -> Void) {
        handlers.append(handler)
        guard source == nil else { return }
        let callback: IOPowerSourceCallbackType = { _ in
            DispatchQueue.main.async { Power.handlers.forEach { $0() } }
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() {
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        // Belt and braces: also re-check every minute.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Power.handlers.forEach { $0() } }
    }
}
