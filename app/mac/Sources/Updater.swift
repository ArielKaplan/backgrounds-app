import AppKit
import CryptoKit

/// In-app updates. Reads update.json from the latest GitHub release, and on request downloads the Mac zip,
/// checks its SHA-256 and ECDSA P-256 signature against the public key built into this app (Info.plist
/// BackgroundsUpdatePublicKey), swaps the app bundle and relaunches. See app/release/make_feed.py.
final class Updater {
    static let shared = Updater()
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    private(set) var status = "idle"     // idle checking upToDate available downloading installing error
    private(set) var error: String?
    private(set) var latestVersion: String?
    private(set) var notes = ""
    private(set) var progress = 0
    var onChange: (() -> Void)?
    private var entry: [String: Any]?
    private var busy = false
    private var progressObservation: NSKeyValueObservation?

    private static var publicKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "BackgroundsUpdatePublicKey") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static var feedURL: String {
        Store.shared.extra["updateFeed"] as? String ?? Bundle.main.object(forInfoDictionaryKey: "BackgroundsUpdateFeed") as? String ?? ""
    }
    static var configured: Bool { !publicKey.isEmpty && !feedURL.isEmpty }

    private func set(_ s: String, _ err: String? = nil) {
        status = s; error = err
        DispatchQueue.main.async { self.onChange?() }
    }

    func stateJSON() -> [String: Any] {
        [
            "current": Self.currentVersion, "status": Self.configured ? status : "disabled",
            "error": error ?? NSNull(), "latest": latestVersion ?? NSNull(), "notes": notes, "progress": progress,
            "lastCheck": Store.shared.extra["lastUpdateCheck"] ?? NSNull(),
        ]
    }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        r.setValue("Backgrounds/\(currentVersion) (Mac)", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// Calls back on the main thread with true when a newer version is available.
    func check(_ done: ((Bool) -> Void)? = nil) {
        guard Self.configured, let url = URL(string: Self.feedURL) else { set("disabled"); done?(false); return }
        guard !busy else { done?(status == "available"); return }
        busy = true
        set("checking")
        URLSession.shared.dataTask(with: Self.request(url)) { data, response, err in
            DispatchQueue.main.async {
                self.busy = false
                do {
                    if let err = err { throw err }
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw UpdateError(http.statusCode == 404 ? "no release has been published yet" : "server said \(http.statusCode)")
                    }
                    guard let data = data, let feed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let version = feed["version"] as? String else { throw UpdateError("bad update feed") }
                    Store.shared.setExtra("lastUpdateCheck", ISO8601DateFormatter().string(from: Date()))
                    self.latestVersion = version
                    self.notes = feed["notes"] as? String ?? ""
                    self.entry = feed["mac"] as? [String: Any]
                    let newer = self.entry != nil && Self.compare(version, Self.currentVersion) > 0
                    self.set(newer ? "available" : "upToDate")
                    done?(newer)
                } catch {
                    NSLog("Backgrounds: update check failed: \(error)")
                    self.set("error", "Couldn't check for updates: \(Self.friendly(error))")
                    done?(false)
                }
            }
        }.resume()
    }

    func install() {
        guard !busy, status == "available", let entry = entry, let version = latestVersion,
              let urlString = entry["url"] as? String, let url = URL(string: urlString),
              let sha = entry["sha256"] as? String, let sig = entry["signature"] as? String else { return }
        let appURL = Bundle.main.bundleURL
        if appURL.path.contains("/AppTranslocation/") {
            set("error", "Move Backgrounds to your Applications folder first (drag it there from Downloads), open it from there, then update.")
            status = "available"; return
        }
        let parent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            set("error", "Backgrounds can't replace itself in \(parent.path). Move it to your Applications folder and try again.")
            status = "available"; return
        }
        busy = true
        progress = 0
        set("downloading")
        let task = URLSession.shared.dataTask(with: Self.request(url)) { data, response, err in
            DispatchQueue.main.async {
                self.progressObservation = nil
                do {
                    if let err = err { throw err }
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError("server said \(http.statusCode)") }
                    guard let data = data else { throw UpdateError("empty download") }
                    try Self.verify(data, platform: "mac", version: version, sha256: sha, signature: sig, publicKey: Self.publicKey)
                    self.set("installing")
                    try self.swapAndRelaunch(zip: data, version: version, appURL: appURL)
                } catch {
                    NSLog("Backgrounds: update failed: \(error)")
                    self.busy = false
                    self.set("error", "The update failed: \(Self.friendly(error))")
                    self.status = "available"
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let pct = Int(p.fractionCompleted * 100)
                if pct != self.progress { self.progress = pct; self.onChange?() }
            }
        }
        task.resume()
    }

    /// Throws unless `data` has the expected SHA-256 and the feed entry's signature is valid for this key.
    static func verify(_ data: Data, platform: String, version: String, sha256: String, signature: String, publicKey: String) throws {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == sha256.lowercased() else { throw UpdateError("the download is damaged (checksum mismatch)") }
        guard let keyData = Data(base64Encoded: publicKey), keyData.count == 64,
              let sigData = Data(base64Encoded: signature), sigData.count == 64 else {
            throw UpdateError("the update's signature is missing or malformed")
        }
        let key = try P256.Signing.PublicKey(rawRepresentation: keyData)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: sigData)
        let message = Data("backgrounds-update\n\(platform)\n\(version)\n\(actual)".utf8)
        guard key.isValidSignature(sig, for: message) else { throw UpdateError("the update's signature is not valid") }
    }

    /// Unpacks the new app next to the running one, then (after we quit) swaps them and opens the new one.
    private func swapAndRelaunch(zip: Data, version: String, appURL: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Backgrounds-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zipURL = work.appendingPathComponent("update.zip")
        try zip.write(to: zipURL)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, work.path]
        try ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError("couldn't unpack the update") }
        let newApp = work.appendingPathComponent("Backgrounds.app")
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("the downloaded app isn't Backgrounds \(version)")
        }
        // Stage it beside the current app (same volume, so the final swap is two renames).
        let staged = appURL.deletingLastPathComponent().appendingPathComponent(".Backgrounds-\(version)-update.app")
        try? fm.removeItem(at: staged)
        try fm.moveItem(at: newApp, to: staged)
        try? fm.removeItem(at: work)

        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        APP=\(Self.shellQuote(appURL.path)); NEW=\(Self.shellQuote(staged.path))
        rm -rf "$APP.old"
        if mv "$APP" "$APP.old" && mv "$NEW" "$APP"; then rm -rf "$APP.old"; else mv "$APP.old" "$APP" 2>/dev/null; rm -rf "$NEW"; fi
        open "$APP"
        """
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", script]
        try sh.run()
        NSLog("Backgrounds: updating to \(version), restarting")
        NSApp.terminate(nil)
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func friendly(_ e: Error) -> String {
        if let u = e as? UpdateError { return u.message }
        if (e as NSError).domain == NSURLErrorDomain { return "no connection" }
        return e.localizedDescription
    }

    /// Compares dotted versions numerically ("1.10.0" > "1.9.2").
    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> [Int] {
            (v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? "").split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}

struct UpdateError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
