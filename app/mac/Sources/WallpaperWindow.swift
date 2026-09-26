import AppKit
import WebKit

/// One borderless window per screen, parked at the desktop level (under the Finder's desktop icons,
/// like Plash). Click-through, on every Space, ignored by Mission Control / Cmd-Tab.
final class WallpaperWindow: NSWindow, WKNavigationDelegate {
    let screenID: String
    private(set) var wallpaper: Wallpaper?
    private(set) var currentURL: URL?        // what should be showing (without one-off extras)
    private var currentHash = ""
    private var loadedHash = ""              // hash of the last load (may include one-off extras)
    private var webView: WKWebView?
    private var incoming: WKWebView?         // next page, loading underneath the current one
    private let freezeView = NSImageView()
    private var frozen = false
    private var freezeWork: DispatchWorkItem?
    private var coveredPaused = false
    var pauseWhenCovered = true { didSet { updateCovered() } }

    init(screen: NSScreen, screenID: String) {
        self.screenID = screenID
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none
        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        contentView = content
        freezeView.imageScaling = .scaleAxesIndependently
        freezeView.autoresizingMask = [.width, .height]
        freezeView.frame = content.bounds
        setFrame(screen.frame, display: false)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func place(on screen: NSScreen) {
        if frame != screen.frame { setFrame(screen.frame, display: true) }
    }

    // MARK: loading

    private func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()              // persistent: localStorage survives (Ant Farm colony, caches)
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.suppressesIncrementalRendering = true
        let wv = WKWebView(frame: contentView!.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.allowsMagnification = false
        wv.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        return wv
    }

    /// Loads `url` (a file URL with the options in its #hash). `extra` is appended to the hash for this load
    /// only (one-off actions such as the Ant Farm's "reset").
    func show(wallpaper: Wallpaper, hash: String, extra: String? = nil, force: Bool = false) {
        let url = Self.url(for: wallpaper.file, hash: hash)
        let fullHash = extra.map { hash.isEmpty ? $0 : hash + "&" + $0 } ?? hash
        let loadURL = Self.url(for: wallpaper.file, hash: fullHash)
        if !force && extra == nil && url == currentURL && (webView != nil || incoming != nil) { return }
        self.wallpaper = wallpaper
        currentURL = url
        currentHash = hash
        loadedHash = fullHash
        // A fresh web view each time: a hash-only change would otherwise not reload the page.
        // It loads underneath the current page, which is removed once the new one has drawn (no black flash).
        incoming?.removeFromSuperview()
        let wv = makeWebView()
        incoming = wv
        if let current = webView { contentView!.addSubview(wv, positioned: .below, relativeTo: current) }
        else { contentView!.addSubview(wv, positioned: .below, relativeTo: nil) }
        wv.isHidden = isPausedNow
        wv.loadFileURL(loadURL, allowingReadAccessTo: wallpaper.root)
        let token = wv
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.promote(token) }  // in case didFinish never comes
    }

    func reload() {
        guard let wp = wallpaper else { return }
        show(wallpaper: wp, hash: currentHash, force: true)
    }

    private func promote(_ wv: WKWebView) {
        guard wv === incoming else { return }
        incoming = nil
        let old = webView
        webView = wv
        if let old = old {
            // Give the new page a moment to paint before uncovering it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { old.removeFromSuperview() }
        }
        if frozen {
            // Paused, but a new page arrived (first launch on battery, or options changed while paused):
            // let it draw for a moment, then freeze on its frame.
            dropFrozenFrame()
            captureFrozenFrame(after: 2.5)
        }
        applyPause()
    }

    static func url(for file: URL, hash: String) -> URL {
        guard !hash.isEmpty, var c = URLComponents(url: file, resolvingAgainstBaseURL: false) else { return file }
        c.percentEncodedFragment = hash
        return c.url ?? file
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Safety net: make sure the #options made it into the page (some WebKit versions drop fragments on file loads).
        let frag = loadedHash
        if !frag.isEmpty, let file = wallpaper?.file, webView === incoming || webView === self.webView {
            webView.evaluateJavaScript("location.hash") { result, _ in
                if let got = result as? String, got != "#" + frag {
                    NSLog("Backgrounds: options were dropped from the URL (got \(got)), re-applying")
                    let target = Self.url(for: file, hash: frag).absoluteString
                    let js = "location.replace(\(Self.jsString(target))); location.reload();"
                    webView.evaluateJavaScript(js, completionHandler: nil)
                }
            }
        }
        if webView === incoming { promote(webView) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("Backgrounds: load failed: \(error.localizedDescription)")
        if webView === incoming { promote(webView) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("Backgrounds: load failed: \(error.localizedDescription)")
        if webView === incoming { promote(webView) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page crashed or was killed (e.g. memory pressure): bring it back.
        NSLog("Backgrounds: web content process ended, reloading")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, webView === self.webView else { return }
            if let url = self.currentURL, let wp = self.wallpaper { webView.loadFileURL(url, allowingReadAccessTo: wp.root) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Wallpapers can't be clicked, but never let one navigate the desktop away to another site.
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url,
           !url.isFileURL, url.scheme != "about" {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    // MARK: pausing

    /// Freeze: keep the last frame on screen and hide the page (WebKit stops animation frames for hidden views).
    func setFrozen(_ on: Bool) {
        guard on != frozen else { return }
        frozen = on
        if on {
            captureFrozenFrame(after: 0)
        } else {
            freezeWork?.cancel()
            applyPause()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self, !self.frozen else { return }
                self.dropFrozenFrame()
            }
        }
    }

    private func captureFrozenFrame(after delay: Double) {
        freezeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.frozen else { return }
            guard let wv = self.webView, !self.coveredPaused else {
                self.captureFrozenFrame(after: 5)    // nothing visible to capture yet; try again later
                return
            }
            wv.takeSnapshot(with: nil) { [weak self] image, _ in
                guard let self = self, self.frozen, let image = image else { return }
                self.freezeView.image = image
                self.freezeView.frame = self.contentView!.bounds
                self.contentView!.addSubview(self.freezeView, positioned: .above, relativeTo: nil)
                self.applyPause()
            }
        }
        freezeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dropFrozenFrame() {
        freezeView.removeFromSuperview()
        freezeView.image = nil
    }

    /// Hidden while covered, or while frozen once there is a frame to show instead.
    private var isPausedNow: Bool { coveredPaused || (frozen && freezeView.image != nil) }

    private func applyPause() {
        let hide = isPausedNow
        webView?.isHidden = hide
        incoming?.isHidden = hide
    }

    @objc private func occlusionChanged() { updateCovered() }

    private func updateCovered() {
        // macOS reports when a window is completely hidden (full-screen app, maximized windows, screen asleep/locked).
        let covered = pauseWhenCovered && !occlusionState.contains(.visible)
        guard covered != coveredPaused else { return }
        coveredPaused = covered
        applyPause()
    }

    func tearDown() {
        freezeWork?.cancel()
        NotificationCenter.default.removeObserver(self)
        incoming?.removeFromSuperview(); incoming = nil
        webView?.removeFromSuperview(); webView = nil
        orderOut(nil)
        close()
    }
}
