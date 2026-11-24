// LiteBrowser — in-app updates from GitHub Releases.
// Homebrew installs update with `brew upgrade`; other installs download the Mac zip and replace the app.

import Cocoa

extension Notification.Name {
    static let liteUpdateAvailable = Notification.Name("LiteBrowserUpdateAvailable")
}

final class Updater {
    static let shared = Updater()

    struct Release { let version: String; let page: URL; let macZip: URL? }
    enum Phase { case idle, working(String), ready, failed(String) }

    private(set) var available: Release?
    private(set) var phase: Phase = .idle
    var onProgress: ((Phase) -> Void)?

    // MARK: Install type

    /// True when this app lives in Homebrew's Cellar (installed with `brew install`).
    var isHomebrew: Bool { Bundle.main.bundleURL.resolvingSymlinksInPath().path.contains("/Cellar/") }

    var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Where the updated app will be after installing.
    private var relaunchPath: String {
        if isHomebrew, let brew = brewPath {
            let prefix = (brew as NSString).deletingLastPathComponent.replacingOccurrences(of: "/bin", with: "")
            return "\(prefix)/opt/lite-browser/LiteBrowser.app"
        }
        return Bundle.main.bundlePath
    }

    // MARK: Checking

    /// Asks GitHub for the newest release. `newer` is nil when you're up to date.
    func check(_ done: @escaping (Result<Release?, Error>) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest")!,
                             timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let result: Result<Release?, Error>
            if let err = err {
                result = .failure(err)
            } else if let data = data,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let tag = obj["tag_name"] as? String {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.repoURL
                let assets = obj["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { ($0["name"] as? String)?.hasSuffix("-macOS.zip") == true }
                    .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
                let rel = Release(version: version, page: page, macZip: zip)
                let newer = version.compare(AppInfo.version, options: .numeric) == .orderedDescending
                result = .success(newer ? rel : nil)
            } else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                result = .failure(SimpleError("GitHub answered with status \(code)."))
            }
            DispatchQueue.main.async {
                if case .success(let rel) = result {
                    self.available = rel
                    if rel != nil { NotificationCenter.default.post(name: .liteUpdateAvailable, object: nil) }
                }
                done(result)
            }
        }.resume()
    }

    /// Checks at most every 12 hours (called at launch and when the Mac wakes).
    func checkInBackground() {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 12 * 3600 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        check { _ in }
    }

    // MARK: Installing

    private func report(_ p: Phase) {
        phase = p
        onProgress?(p)
    }

    func install() {
        if case .working = phase { return }
        if isHomebrew, let brew = brewPath {
            installWithHomebrew(brew)
        } else if let zip = available?.macZip {
            installFromZip(zip)
        } else {
            report(.failed("No Mac download was found in the latest release."))
        }
    }

    private func installWithHomebrew(_ brew: String) {
        report(.working("Checking Homebrew for the new version…"))
        runBrew(brew, ["update", "--quiet"]) { [weak self] _ in
            guard let self = self else { return }
            self.report(.working("Downloading and building LiteBrowser…"))
            self.runBrew(brew, ["upgrade", "lite-browser"]) { ok in
                self.report(ok ? .ready : .failed("Homebrew couldn't update LiteBrowser. Try `brew upgrade lite-browser` in Terminal."))
            }
        }
    }

    private func runBrew(_ brew: String, _ args: [String], done: @escaping (Bool) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = NSHomeDirectory()
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"   // keep the running version's files until restart
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let text = String(data: h.availableData, encoding: .utf8) else { return }
            let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            if let line = line {
                let clean = line.replacingOccurrences(of: "==> ", with: "")
                DispatchQueue.main.async { self?.report(.working(clean)) }
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { done(proc.terminationStatus == 0) }
        }
        do { try p.run() } catch { report(.failed(error.localizedDescription)) }
    }

    private func installFromZip(_ url: URL) {
        report(.working("Downloading LiteBrowser \(available?.version ?? "")…"))
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, err in
            guard let self = self else { return }
            guard let tmp = tmp, err == nil else {
                DispatchQueue.main.async { self.report(.failed(err?.localizedDescription ?? "Download failed.")) }
                return
            }
            do {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("lb-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: tmp, to: zip)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", zip.path, work.path]
                try p.run()
                p.waitUntilExit()
                let newApp = work.appendingPathComponent("LiteBrowser.app")
                guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: newApp.path) else {
                    throw SimpleError("The downloaded update was damaged.")
                }
                _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: newApp)
                DispatchQueue.main.async { self.report(.ready) }
            } catch {
                DispatchQueue.main.async {
                    self.report(.failed("Couldn't install the update here (\(error.localizedDescription)). Download it from the release page instead."))
                }
            }
        }
        task.resume()
    }

    /// Quits and opens the newly installed version; your tabs are reopened.
    func relaunch() {
        UserDefaults.standard.set(true, forKey: "restoreAfterUpdate")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$LB_APP\""]
        p.environment = ["LB_APP": relaunchPath, "PATH": "/usr/bin:/bin"]
        try? p.run()
        NSApp.terminate(nil)
    }
}
