// LiteBrowser — downloads: saving files, progress, and the toolbar downloads button + list.

import Cocoa
import WebKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let liteDownloadsChanged = Notification.Name("LiteBrowserDownloadsChanged")
}

final class DownloadItem {
    let id: UUID
    weak var download: WKDownload?
    var filename: String
    var destination: URL?
    var sourceURL: URL?
    var state: State = .running
    var error: String?
    var started = Date()
    enum State: String { case running, finished, failed, cancelled }

    init(id: UUID = UUID(), download: WKDownload?, filename: String) {
        self.id = id
        self.download = download
        self.filename = filename
    }

    var fileExists: Bool { destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    var fraction: Double? {
        guard state == .running, let p = download?.progress, p.totalUnitCount > 0 else { return nil }
        return p.fractionCompleted
    }

    var statusText: String {
        switch state {
        case .finished:
            if !fileExists { return "Deleted or moved" }
            let size = destination.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            return size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + " · Done" } ?? "Done"
        case .failed: return "Failed: " + (error ?? "unknown error")
        case .cancelled: return "Cancelled"
        case .running:
            guard let p = download?.progress else { return "Starting…" }
            let done = ByteCountFormatter.string(fromByteCount: p.completedUnitCount, countStyle: .file)
            if p.totalUnitCount > 0 {
                let total = ByteCountFormatter.string(fromByteCount: p.totalUnitCount, countStyle: .file)
                return "\(done) of \(total)"
            }
            return done
        }
    }
}

/// Owns every download, decides where files go, and tells the toolbar buttons to update.
final class DownloadCenter: NSObject, WKDownloadDelegate {
    static let shared = DownloadCenter()
    private(set) var items: [DownloadItem] = []
    private var timer: Timer?
    private let store: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiteBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }()

    private struct Record: Codable {
        var id: String; var filename: String; var path: String?; var source: String?
        var state: String; var error: String?; var date: Date
    }

    override init() {
        super.init()
        // Bring back the download list from earlier sessions
        if let data = try? Data(contentsOf: store), let recs = try? JSONDecoder().decode([Record].self, from: data) {
            items = recs.map { r in
                let it = DownloadItem(id: UUID(uuidString: r.id) ?? UUID(), download: nil, filename: r.filename)
                it.destination = r.path.map { URL(fileURLWithPath: $0) }
                it.sourceURL = r.source.flatMap(URL.init(string:))
                let st = DownloadItem.State(rawValue: r.state) ?? .failed
                it.state = st == .running ? .failed : st          // interrupted when the app quit
                it.error = st == .running ? "Interrupted when LiteBrowser quit" : r.error
                it.started = r.date
                return it
            }
        }
    }

    private func save() {
        let recs = items.prefix(200).map {
            Record(id: $0.id.uuidString, filename: $0.filename, path: $0.destination?.path,
                   source: $0.sourceURL?.absoluteString, state: $0.state.rawValue, error: $0.error, date: $0.started)
        }
        if let data = try? JSONEncoder().encode(Array(recs)) { try? data.write(to: store, options: .atomic) }
    }

    var hasActive: Bool { items.contains { $0.state == .running } }

    /// Overall progress of running downloads (nil = unknown size).
    var activeFraction: Double? {
        let running = items.filter { $0.state == .running }
        let known = running.compactMap { $0.fraction }
        guard !running.isEmpty, known.count == running.count else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    /// Folder downloads are saved to (Settings can change it; defaults to ~/Downloads).
    var folder: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: "downloadFolder") { return URL(fileURLWithPath: p) }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "downloadFolder") }
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        let name = download.originalRequest?.url?.lastPathComponent ?? "Download"
        let it = DownloadItem(download: download, filename: name.isEmpty ? "Download" : name)
        it.sourceURL = download.originalRequest?.url.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
        items.insert(it, at: 0)
        if items.count > 200 { items.removeLast(items.count - 200) }
        startTimer()
        save()
        changed()
    }

    private func item(for d: WKDownload) -> DownloadItem? { items.first { $0.download === d } }

    private func changed() { NotificationCenter.default.post(name: .liteDownloadsChanged, object: nil) }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.changed()
            if !self.hasActive { self.timer?.invalidate(); self.timer = nil }
        }
    }

    /// Checks we can really write into the folder (this also triggers macOS's
    /// "allow access to Downloads" prompt the first time).
    private func canWrite(to dir: URL) -> Bool {
        let probe = dir.appendingPathComponent(".litebrowser-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    private func uniqueURL(in dir: URL, for name: String) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension
        var dest = dir.appendingPathComponent(clean)
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            i += 1
        }
        return dest
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let name = suggestedFilename.isEmpty ? (response.suggestedFilename ?? "Download") : suggestedFilename
        item(for: download)?.filename = name

        var dir = folder
        if Prefs.askDownloadLocation || !canWrite(to: dir) {
            // macOS blocked the folder (privacy setting) or it no longer exists: let the user pick a place.
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.message = Prefs.askDownloadLocation ? "Where do you want to save this file?"
                : "LiteBrowser can't save to “\(dir.lastPathComponent)”. Choose where to save this file."
            panel.directoryURL = Prefs.askDownloadLocation ? dir : FileManager.default.homeDirectoryForCurrentUser
            guard panel.runModal() == .OK, let chosen = panel.url else {
                item(for: download)?.state = .cancelled
                changed()
                completionHandler(nil)
                return
            }
            dir = chosen.deletingLastPathComponent()
            if !Prefs.askDownloadLocation { folder = dir }
            try? FileManager.default.removeItem(at: chosen)    // WebKit refuses to overwrite
            item(for: download)?.destination = chosen
            changed()
            completionHandler(chosen)
            return
        }
        let dest = uniqueURL(in: dir, for: name)
        item(for: download)?.destination = dest
        changed()
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let it = item(for: download) else { return }
        it.state = .finished
        if let path = it.destination?.path {
            // Makes the Downloads stack in the Dock bounce, like Safari
            DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"), object: path)
        }
        NSApp.requestUserAttention(.informationalRequest)
        save()
        changed()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let it = item(for: download) else { return }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { it.state = .cancelled }
        else { it.state = .failed; it.error = error.localizedDescription }
        save()
        changed()
    }

    // MARK: Actions

    func cancel(_ it: DownloadItem) {
        it.download?.cancel { _ in }
        it.state = .cancelled
        save()
        changed()
    }

    func remove(_ it: DownloadItem) {
        if it.state == .running { it.download?.cancel { _ in } }
        items.removeAll { $0 === it }
        save()
        changed()
    }

    /// The list for Settings › Downloads.
    func settingsInfo() -> [[String: Any]] {
        items.map { it in
            [
                "id": it.id.uuidString,
                "name": it.filename,
                "status": it.statusText,
                "state": it.state.rawValue,
                "fraction": it.fraction ?? -1,
                "source": it.sourceURL?.host ?? "",
                "date": it.started.timeIntervalSince1970 * 1000,
                "exists": it.fileExists,
                "canRetry": it.sourceURL != nil,
            ]
        }
    }

    func reveal(_ it: DownloadItem) {
        if let d = it.destination, FileManager.default.fileExists(atPath: d.path) {
            NSWorkspace.shared.activateFileViewerSelecting([d])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    func open(_ it: DownloadItem) {
        if let d = it.destination { NSWorkspace.shared.open(d) }
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
        save()
        changed()
    }
}

// MARK: - Toolbar button with a progress ring

final class DownloadsButton: HoverButton {
    var fraction: Double? { didSet { needsDisplay = true } }
    var active = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard active else { return }
        let r = NSRect(x: bounds.midX - 11, y: bounds.midY - 11, width: 22, height: 22)
        NSColor.controlAccentColor.withAlphaComponent(0.25).setStroke()
        let track = NSBezierPath(ovalIn: r)
        track.lineWidth = 2
        track.stroke()
        let f = fraction ?? 0.25
        let arc = NSBezierPath()
        let c = NSPoint(x: r.midX, y: r.midY)
        let start: CGFloat = isFlipped ? -90 : 90
        let end = isFlipped ? start + CGFloat(f) * 360 : start - CGFloat(f) * 360
        arc.appendArc(withCenter: c, radius: 11, startAngle: start, endAngle: end, clockwise: !isFlipped)
        arc.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        arc.stroke()
    }
}

// MARK: - Downloads list (popover)

final class DownloadsViewController: NSViewController {
    private let stack = NSStackView()
    private var observer: NSObjectProtocol?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        let title = NSTextField(labelWithString: "Downloads")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let folderButton = NSButton(title: "Open Folder", target: self, action: #selector(openFolder))
        folderButton.bezelStyle = .rounded
        folderButton.controlSize = .small
        let allButton = NSButton(title: "Show All", target: self, action: #selector(showAll))
        allButton.bezelStyle = .rounded
        allButton.controlSize = .small
        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearDone))
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        let header = NSStackView(views: [title, NSView(), clearButton, folderButton, allButton])
        header.orientation = .horizontal

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let docView = FlippedView()
        docView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        docView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = docView
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: docView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
            docView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        for v in [header, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
        rebuild()
        observer = NotificationCenter.default.addObserver(forName: .liteDownloadsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = DownloadCenter.shared.items
        if items.isEmpty {
            let none = NSTextField(labelWithString: "No downloads yet. Files are saved to “\(DownloadCenter.shared.folder.lastPathComponent)”.")
            none.textColor = .secondaryLabelColor
            stack.addArrangedSubview(none)
        }
        for it in items.prefix(8) { stack.addArrangedSubview(row(for: it)) }
        let height = min(460, max(90, CGFloat(min(items.count, 8)) * 54 + 60))
        preferredContentSize = NSSize(width: 380, height: height)
    }

    private func row(for it: DownloadItem) -> NSView {
        let ext = (it.filename as NSString).pathExtension
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: .init(filenameExtension: ext) ?? .data))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let name = NSTextField(labelWithString: it.filename)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let status = NSTextField(labelWithString: it.statusText)
        status.font = .systemFont(ofSize: 11)
        status.textColor = it.state == .failed ? .systemRed : .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let texts = NSStackView(views: [name, status])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        if it.state == .running {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.controlSize = .small
            if let f = it.fraction { bar.isIndeterminate = false; bar.doubleValue = f * 100 }
            else { bar.isIndeterminate = true; bar.startAnimation(nil) }
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 220).isActive = true
            texts.insertArrangedSubview(bar, at: 1)
        }
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var buttons: [NSView] = []
        func button(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) {
            let b = ClosureButton(symbol: symbol, tip: tip, action: action)
            buttons.append(b)
        }
        switch it.state {
        case .running: button("xmark.circle", "Cancel") { DownloadCenter.shared.cancel(it) }
        case .finished where it.fileExists:
            button("magnifyingglass.circle", "Show in Finder") { DownloadCenter.shared.reveal(it) }
            button("arrow.up.forward.app", "Open") { DownloadCenter.shared.open(it) }
        default: break
        }

        let row = NSStackView(views: [icon, texts] + buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 350).isActive = true
        if it.state == .finished {
            let click = NSClickGestureRecognizer(target: self, action: #selector(rowDoubleClicked(_:)))
            click.numberOfClicksRequired = 2
            row.addGestureRecognizer(click)
            row.identifier = NSUserInterfaceItemIdentifier(it.id.uuidString)
        }
        return row
    }

    @objc private func rowDoubleClicked(_ g: NSClickGestureRecognizer) {
        guard let id = g.view?.identifier?.rawValue,
              let it = DownloadCenter.shared.items.first(where: { $0.id.uuidString == id }) else { return }
        DownloadCenter.shared.open(it)
    }

    @objc private func openFolder() { NSWorkspace.shared.open(DownloadCenter.shared.folder) }
    @objc private func clearDone() { DownloadCenter.shared.clearFinished() }
    @objc private func showAll() { AppDelegate.shared.showAllDownloads(nil) }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Small icon button that runs a closure.
final class ClosureButton: HoverButton {
    private var handler: (() -> Void)?

    convenience init(symbol: String, tip: String, action: @escaping () -> Void) {
        self.init(symbol: symbol, tip: tip, pointSize: 15, target: nil, action: nil)
        handler = action
        target = self
        self.action = #selector(run)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    @objc private func run() { handler?() }
}
