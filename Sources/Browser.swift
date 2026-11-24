// LiteBrowser — browser window with a Chrome/Brave-style tab strip.
// One window holds many tabs (BrowserTab), each with its own WKWebView.

import Cocoa
import WebKit
import Network

// MARK: - Colours (adapt to light / dark mode)

enum Theme {
    static func dynamic(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: dark, alpha: 1) : NSColor(white: light, alpha: 1)
        }
    }
    static let strip = dynamic(light: 0.885, dark: 0.105)      // behind the tabs
    static let toolbar = dynamic(light: 1.0, dark: 0.185)      // selected tab + toolbar row
    static let tabHover = dynamic(light: 0.94, dark: 0.145)
    static let omnibox = dynamic(light: 0.945, dark: 0.125)
    static let hover = NSColor.labelColor.withAlphaComponent(0.08)
}

// MARK: - Site icons (favicons), cached per host

final class FaviconCache {
    static let shared = FaviconCache()
    private var cache: [String: NSImage] = [:]
    private var pending: [String: [(NSImage?) -> Void]] = [:]

    func icon(for url: URL?, completion: @escaping (NSImage?) -> Void) {
        guard let url = url, let host = url.host, ["http", "https"].contains(url.scheme ?? "") else {
            completion(nil); return
        }
        if let img = cache[host] { completion(img); return }
        if pending[host] != nil { pending[host]?.append(completion); return }
        pending[host] = [completion]
        var c = URLComponents(string: "https://www.google.com/s2/favicons")!
        c.queryItems = [URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: "32")]
        URLSession.shared.dataTask(with: c.url!) { data, _, _ in
            let img = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                if let img = img { img.size = NSSize(width: 16, height: 16); self.cache[host] = img }
                let waiting = self.pending.removeValue(forKey: host) ?? []
                waiting.forEach { $0(img) }
            }
        }.resume()
    }
}

// MARK: - Small views

/// Borderless icon button with a rounded hover highlight (like Chrome's toolbar buttons).
class HoverButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 7

    convenience init(symbol: String, tip: String, pointSize: CGFloat = 15, target: AnyObject?, action: Selector?) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(cfg) ?? NSImage()
        self.init(image: img, target: target, action: action)
        isBordered = false
        imagePosition = .imageOnly
        toolTip = tip
        contentTintColor = .secondaryLabelColor
    }

    func setSymbol(_ symbol: String, tip: String, pointSize: CGFloat = 15) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(cfg)
        toolTip = tip
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering && isEnabled {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Thin loading bar under the toolbar.
final class ProgressLine: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard progress > 0 else { return }
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * CGFloat(min(progress, 1)), height: bounds.height).fill()
    }
}

/// Toolbar row background (same colour as the selected tab, with a hairline at the bottom).
final class ToolbarRowView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.toolbar.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

// MARK: - One tab in the strip

final class TabView: NSView {
    let tab: BrowserTab
    weak var strip: TabStripView?
    var isActive = false { didSet { if oldValue != isActive { needsDisplay = true; needsLayout = true } } }
    var showsSeparator = true { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true; needsLayout = true } }
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = HoverButton(symbol: "xmark", tip: "Close Tab", pointSize: 9, target: nil, action: nil)
    private var mouseDownPoint: NSPoint?
    private var dragging = false

    init(tab: BrowserTab) {
        self.tab = tab
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        closeButton.cornerRadius = 4
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        [icon, spinner, titleLabel, closeButton].forEach { addSubview($0) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func refresh() {
        titleLabel.stringValue = tab.displayTitle
        toolTip = tab.displayTitle
        icon.image = tab.favicon ?? (tab.isHomePage ? NSApp.applicationIconImage
                                     : NSImage(systemSymbolName: "globe", accessibilityDescription: nil))
        icon.contentTintColor = .secondaryLabelColor
        if tab.isBusy { spinner.startAnimation(nil); icon.isHidden = true }
        else { spinner.stopAnimation(nil); icon.isHidden = false }
        titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        let compact = w < 72
        let showClose = isActive || (hovering && w >= 56)
        let iconX: CGFloat = compact && !showClose ? (w - 16) / 2 : 12
        icon.frame = NSRect(x: iconX, y: (h - 16) / 2, width: 16, height: 16)
        spinner.frame = icon.frame
        closeButton.isHidden = !showClose
        closeButton.frame = NSRect(x: w - 26, y: (h - 18) / 2, width: 18, height: 18)
        titleLabel.isHidden = compact
        let titleX = iconX + 22
        let titleRight = showClose ? closeButton.frame.minX - 4 : w - 10
        titleLabel.frame = NSRect(x: titleX, y: (h - 16) / 2, width: max(0, titleRight - titleX), height: 16)
        titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        if isActive {
            let r: CGFloat = 9, flare: CGFloat = 6
            let p = NSBezierPath()
            // Chrome-style: rounded top corners and small outward curves at the bottom
            p.move(to: NSPoint(x: b.minX, y: b.maxY))
            p.appendArc(from: NSPoint(x: b.minX + flare, y: b.maxY), to: NSPoint(x: b.minX + flare, y: b.maxY - flare), radius: flare)
            p.line(to: NSPoint(x: b.minX + flare, y: b.minY + r))
            p.appendArc(from: NSPoint(x: b.minX + flare, y: b.minY), to: NSPoint(x: b.minX + flare + r, y: b.minY), radius: r)
            p.line(to: NSPoint(x: b.maxX - flare - r, y: b.minY))
            p.appendArc(from: NSPoint(x: b.maxX - flare, y: b.minY), to: NSPoint(x: b.maxX - flare, y: b.minY + r), radius: r)
            p.line(to: NSPoint(x: b.maxX - flare, y: b.maxY - flare))
            p.appendArc(from: NSPoint(x: b.maxX - flare, y: b.maxY), to: NSPoint(x: b.maxX, y: b.maxY), radius: flare)
            p.close()
            Theme.toolbar.setFill()
            p.fill()
        } else if hovering {
            Theme.tabHover.setFill()
            NSBezierPath(roundedRect: b.insetBy(dx: 6, dy: 4).offsetBy(dx: 0, dy: -2), xRadius: 8, yRadius: 8).fill()
        } else if showsSeparator {
            NSColor.separatorColor.setFill()
            NSRect(x: b.maxX - 1, y: b.minY + 9, width: 1, height: b.height - 16).fill()
        }
    }

    // Hover
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; strip?.hoverChanged() }
    override func mouseExited(with event: NSEvent) { hovering = false; strip?.hoverChanged() }
    var isHovering: Bool { hovering }

    // Click = select, drag = reorder, middle-click = close
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragging = false
        tab.owner?.select(tab)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let strip = strip else { return }
        let p = strip.convert(event.locationInWindow, from: nil)
        if !dragging {
            let local = convert(event.locationInWindow, from: nil)
            guard abs(local.x - start.x) > 4 else { return }
            dragging = true
            strip.beginDrag(self, grabOffset: start.x)
        }
        strip.continueDrag(to: p.x)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { strip?.endDrag() }
        dragging = false
        mouseDownPoint = nil
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { tab.owner?.closeTab(tab) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        add("New Tab to the Right", #selector(newTabRight))
        add("Reload", #selector(reloadTab))
        add("Duplicate", #selector(duplicateTab))
        m.addItem(.separator())
        add("Close Tab", #selector(closeClicked))
        add("Close Other Tabs", #selector(closeOthers))
        return m
    }

    @objc private func closeClicked() { tab.owner?.closeTab(tab) }
    @objc private func newTabRight() { tab.owner?.addTab(url: Config.home, activate: true, after: tab) }
    @objc private func reloadTab() { tab.reloadPage() }
    @objc private func duplicateTab() {
        if let u = tab.currentURL { tab.owner?.addTab(url: u, activate: true, after: tab) }
    }
    @objc private func closeOthers() { tab.owner?.closeOtherTabs(than: tab) }
}

// MARK: - The tab strip (sits in the title bar, next to the traffic lights)

final class TabStripView: NSView {
    weak var controller: BrowserWindowController?
    var leftInset: CGFloat = 78 { didSet { needsLayout = true } }
    private var tabViews: [TabView] = []
    private let plusButton = HoverButton(symbol: "plus", tip: "New Tab (⌘T)", pointSize: 14, target: nil, action: nil)
    private let listButton = HoverButton(symbol: "chevron.down", tip: "All Tabs", pointSize: 12, target: nil, action: nil)
    private var dragView: TabView?
    private var dragGrab: CGFloat = 0
    private(set) var tabWidth: CGFloat = 200

    override init(frame: NSRect) {
        super.init(frame: frame)
        plusButton.target = self
        plusButton.action = #selector(plusClicked)
        listButton.target = self
        listButton.action = #selector(listClicked(_:))
        addSubview(plusButton)
        addSubview(listButton)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }   // we call performDrag ourselves

    override func draw(_ dirtyRect: NSRect) {
        Theme.strip.setFill()
        bounds.fill()
    }

    /// Re-syncs the tab views with the controller's tabs.
    func reload() {
        guard let c = controller else { return }
        var reused: [TabView] = []
        for tab in c.tabs {
            if let tv = tabViews.first(where: { $0.tab === tab }) { reused.append(tv) }
            else {
                let tv = TabView(tab: tab)
                tv.strip = self
                addSubview(tv, positioned: .below, relativeTo: plusButton)
                reused.append(tv)
            }
        }
        for tv in tabViews where !reused.contains(where: { $0 === tv }) { tv.removeFromSuperview() }
        tabViews = reused
        for tv in tabViews { tv.isActive = (tv.tab === c.activeTab); tv.refresh() }
        if let active = tabViews.first(where: { $0.isActive }) {
            addSubview(active, positioned: .below, relativeTo: plusButton)   // active tab draws on top
        }
        hoverChanged()
        needsLayout = true
    }

    func update(_ tab: BrowserTab) {
        tabViews.first { $0.tab === tab }?.refresh()
    }

    func hoverChanged() {
        // hide the separator next to the active or hovered tab, like Chrome
        for (i, tv) in tabViews.enumerated() {
            let next = i + 1 < tabViews.count ? tabViews[i + 1] : nil
            tv.showsSeparator = !(tv.isActive || tv.isHovering || next?.isActive == true || next?.isHovering == true)
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let right: CGFloat = 40                       // room for the tab list button
        let available = bounds.width - leftInset - 44 - right
        let count = CGFloat(max(tabViews.count, 1))
        tabWidth = max(40, min(240, floor(available / count)))
        var x = leftInset
        for tv in tabViews {
            if tv !== dragView { tv.frame = NSRect(x: x, y: 6, width: tabWidth, height: h - 6) }
            x += tabWidth
        }
        plusButton.frame = NSRect(x: min(x + 4, bounds.width - right - 32), y: (h - 28) / 2 + 3, width: 28, height: 28)
        listButton.frame = NSRect(x: bounds.width - 36, y: (h - 28) / 2 + 3, width: 28, height: 28)
    }

    // Window dragging on empty space; double-click zooms like a title bar.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
    }

    @objc private func plusClicked() { controller?.newTabHere(nil) }

    @objc private func listClicked(_ sender: NSButton) {
        guard let c = controller else { return }
        let m = NSMenu()
        for tab in c.tabs {
            let i = NSMenuItem(title: tab.displayTitle, action: #selector(pickTab(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = tab
            i.image = tab.favicon
            i.state = tab === c.activeTab ? .on : .off
            m.addItem(i)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    @objc private func pickTab(_ sender: NSMenuItem) {
        if let t = sender.representedObject as? BrowserTab { controller?.select(t) }
    }

    // Drag to reorder
    func beginDrag(_ tv: TabView, grabOffset: CGFloat) {
        dragView = tv
        dragGrab = grabOffset
        addSubview(tv, positioned: .below, relativeTo: plusButton)
    }

    func continueDrag(to x: CGFloat) {
        guard let tv = dragView, let c = controller, let from = tabViews.firstIndex(where: { $0 === tv }) else { return }
        let maxX = leftInset + tabWidth * CGFloat(tabViews.count - 1)
        tv.frame.origin.x = min(max(leftInset, x - dragGrab), maxX)
        let to = min(max(0, Int(((tv.frame.midX - leftInset) / tabWidth).rounded(.down))), tabViews.count - 1)
        if to != from {
            tabViews.remove(at: from)
            tabViews.insert(tv, at: to)
            c.moveTab(from: from, to: to)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                var xx = leftInset
                for other in tabViews {
                    if other !== tv { other.animator().frame = NSRect(x: xx, y: 6, width: tabWidth, height: bounds.height - 6) }
                    xx += tabWidth
                }
            }
            hoverChanged()
        }
    }

    func endDrag() {
        dragView = nil
        needsLayout = true
    }
}

// MARK: - Browser tab (one web page)

final class BrowserTab: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    weak var owner: BrowserWindowController?
    private(set) var favicon: NSImage?
    private var faviconHost: String?
    private var observations: [NSKeyValueObservation] = []
    private let pathMonitor = NWPathMonitor()

    // Error-recovery state
    private var retryCount = 0
    private var generation = 0          // bumps on every real navigation, cancels stale retries
    private var isAutoRetrying = false
    private var lastMainFrameURL: URL?
    private(set) var failedURL: URL?
    private(set) var errorToken: String? // non-nil while our error page is showing
    private var offlineToken: String?

    init(configuration: WKWebViewConfiguration?) {
        let config: WKWebViewConfiguration
        if let given = configuration {
            config = given                       // popup: must use the opener's configuration
        } else {
            config = WKWebViewConfiguration()
            config.websiteDataStore = .default() // keeps you signed in
        }
        config.userContentController = WKUserContentController()
        config.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15" // Google serves the full site
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()
        config.userContentController.add(WeakScriptHandler(self), name: "lite")
        config.userContentController.add(WeakScriptHandler(self), name: "home")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeWebView()
        startNetworkMonitor()
    }

    deinit { pathMonitor.cancel() }

    var hostWindow: NSWindow? { owner?.window }
    var shownURL: URL? { errorToken != nil ? failedURL : webView.url }
    var isHomePage: Bool { Config.isHome(webView.url) && errorToken == nil }
    var isBusy: Bool { webView.isLoading && !isHomePage }

    var displayTitle: String {
        if isHomePage { return "New Tab" }
        if errorToken != nil { return failedURL?.host ?? "Problem loading page" }
        if let t = webView.title, !t.isEmpty { return t }
        return webView.url?.host ?? (webView.isLoading ? "Loading…" : "New Tab")
    }

    /// The page this tab is showing (used by "Reopen Closed Tab").
    var currentURL: URL? {
        if errorToken != nil { return failedURL }
        guard let u = webView.url, u.absoluteString != "about:blank" else { return nil }
        return u
    }

    private func changed() { owner?.tabDidChange(self) }

    private func observeWebView() {
        let refresh: (WKWebView, Any) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async { self?.changed() }
        }
        observations = [
            webView.observe(\.canGoBack) { w, c in refresh(w, c) },
            webView.observe(\.canGoForward) { w, c in refresh(w, c) },
            webView.observe(\.isLoading) { w, c in refresh(w, c) },
            webView.observe(\.estimatedProgress) { w, c in refresh(w, c) },
            webView.observe(\.title) { w, c in refresh(w, c) },
            webView.observe(\.url) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateFavicon(); self?.changed() }
            },
        ]
    }

    private func updateFavicon() {
        let host = webView.url?.host
        guard host != faviconHost else { return }
        faviconHost = host
        favicon = nil
        FaviconCache.shared.icon(for: webView.url) { [weak self] img in
            guard let self = self, self.faviconHost == host else { return }
            self.favicon = img
            self.changed()
        }
    }

    /// Stops everything when the tab closes.
    func tearDown() {
        pathMonitor.cancel()
        errorToken = nil
        observations.removeAll()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "lite")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "home")
    }

    // MARK: Network monitor — reloads the offline page as soon as a connection returns

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async {
                guard let self = self, let token = self.offlineToken, token == self.errorToken,
                      let url = self.failedURL else { return }
                self.offlineToken = nil
                self.load(url)
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    // MARK: Actions

    func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        }
    }

    func reloadPage() {
        if errorToken != nil, let u = failedURL { load(u) } else { webView.reload() }
    }

    /// Called after DNS settings change: retry whatever failed.
    func retryAfterNetworkChange() {
        guard errorToken != nil, let u = failedURL else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.load(u) }
    }

    // MARK: Home page

    func pushHome() {
        guard Config.isHome(webView.url) else { return }
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        let state: [String: Any] = [
            "sites": HistoryStore.shared.topSites(limit: 8),
            "hidden": Array(Prefs.hiddenTopSites),
            "name": first,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state),
           let json = String(data: data, encoding: .utf8) {
            webView.evaluateJavaScript("renderHome(\(json))", completionHandler: nil)
        }
    }

    private func handleHomeMessage(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, Config.isHome(webView.url),
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready": pushHome()
        case "remove":
            if let host = body["host"] as? String { Prefs.hiddenTopSites.insert(host); pushHome() }
        case "restore":
            Prefs.hiddenTopSites = []
            pushHome()
        case "settings":
            AppDelegate.shared.openSettingsTab(body["tab"] as? String ?? "history")
        default: break
        }
    }

    // MARK: Error recovery

    private func handleLoadError(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return } // download / plugin
        guard let url = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? lastMainFrameURL else { return }

        let dnsCodes = [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed]
        let netCodes = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                        NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
                        NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed]
        let isURLError = ns.domain == NSURLErrorDomain
        let isDNS = isURLError && dnsCodes.contains(ns.code)
        let isNet = isURLError && netCodes.contains(ns.code)

        // 1) Transient failures: retry quietly with backoff (0.75s, 1.5s, 3s).
        //    Timeouts already waited a long time, so they go straight to diagnosis.
        if (isDNS || isNet) && ns.code != NSURLErrorTimedOut && retryCount < Config.maxAutoRetries {
            retryCount += 1
            let gen = generation
            let delay = 0.75 * pow(2.0, Double(retryCount - 1))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.generation == gen else { return }
                self.isAutoRetrying = true
                self.load(url)
            }
            return
        }
        retryCount = 0
        failedURL = url

        if isDNS, let host = url.host {
            // 2) DNS failure: ask public DNS directly to tell "your DNS is broken" from "site doesn't exist".
            let gen = generation
            DoH.lookup(host) { [weak self] result in
                guard let self = self, self.generation == gen else { return }
                switch result {
                case .resolved:     self.showError(.dnsBroken(host: host))
                case .noSuchDomain: self.showError(.noSuchSite(host: host))
                case .unreachable:  self.showError(.offline)
                }
            }
        } else if ns.code == NSURLErrorNotConnectedToInternet || (isNet && pathMonitor.currentPath.status != .satisfied) {
            showError(.offline)
        } else if isNet, let host = url.host {
            // 3) Connection failure: DNS filtering, wrong address, a block, or just a slow site?
            let gen = generation
            showError(.checking(host: host))
            Diagnostics.run(host: host) { [weak self] diagnosis in
                guard let self = self, self.generation == gen else { return }
                let dns = self.currentDNSLabel()
                switch diagnosis {
                case .blockedByDNS(let answers): self.showError(.blockedByDNS(host: host, answers: answers, dns: dns))
                case .wrongAddress: self.showError(.wrongAddress(host: host, dns: dns))
                case .unreachable: self.showError(.unreachable(host: host))
                case .slow:
                    self.showError(.other(title: "\(host) is responding slowly",
                                          detail: "Your DNS and connection are fine and the site's server is reachable, but it didn't answer in time. It's probably busy. Try again in a moment."))
                }
            }
        } else {
            showError(.other(title: "This page couldn't load", detail: ns.localizedDescription))
        }
    }

    private func showError(_ kind: ErrorKind) {
        let token = UUID().uuidString
        errorToken = token
        if case .offline = kind {
            offlineToken = token
            pollUntilOnline(token: token)
        } else {
            offlineToken = nil
        }
        webView.loadHTMLString(errorPageHTML(kind, token: token), baseURL: nil)
        changed()
    }

    private func pollUntilOnline(token: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.errorToken == token, let url = self.failedURL else { return }
            DoH.lookup(url.host ?? "www.google.com") { [weak self] result in
                guard let self = self, self.errorToken == token else { return }
                if result == .unreachable { self.pollUntilOnline(token: token) } else { self.load(url) }
            }
        }
    }

    private func currentDNSLabel() -> String {
        if let first = Prefs.dnsServers.first, let e = DNSEntry(first), e.isEncrypted { return e.display }
        let cur = DNSInfo.current()
        return cur.isEmpty ? "your network's DNS" : cur.prefix(2).joined(separator: ", ")
    }

    // Buttons on the error page and the home page
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "home" { handleHomeMessage(message); return }
        guard message.frameInfo.isMainFrame,
              webView.url?.absoluteString == "about:blank",
              let body = message.body as? [String: Any],
              let token = body["token"] as? String, token == errorToken,
              let action = body["action"] as? String else { return }
        switch action {
        case "retry":  if let u = failedURL { load(u) }
        case "search": if let h = failedURL?.host { load(googleSearchURL(h)) }
        case "fixdns": AppDelegate.shared.fixDNS(nil)
        case "dnssettings": AppDelegate.shared.openSettingsTab("dns")
        case "isdown":
            if let h = failedURL?.host, let u = URL(string: "https://downforeveryoneorjustme.com/\(h)") { load(u) }
        case "publicdns":
            let a = NSAlert()
            a.messageText = "Switch to Cloudflare + Google DNS?"
            a.informativeText = "This replaces your current DNS (including a secure DNS profile from LiteBrowser) with 1.1.1.1 and 8.8.8.8. You can change it back any time in Settings › DNS.\n\nmacOS will ask for your password."
            a.addButton(withTitle: "Switch")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn {
                Prefs.dnsServers = Config.publicDNS
                AppDelegate.shared.applyDNS(Config.publicDNS) { _ in }
            }
        default: break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { decisionHandler(.download); return }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow); return
        }
        let web = ["http", "https"].contains(scheme)
        if web || ["about", "file", "data", "blob", "javascript"].contains(scheme) {
            if web && action.navigationType == .linkActivated && action.modifierFlags.contains(.command) {
                owner?.addTab(url: url, activate: action.modifierFlags.contains(.shift), after: self)
                decisionHandler(.cancel); return
            }
            if action.targetFrame?.isMainFrame == true && web {
                lastMainFrameURL = url
                if isAutoRetrying { isAutoRetrying = false } else { generation += 1; retryCount = 0 }
            }
            decisionHandler(.allow); return
        }
        NSWorkspace.shared.open(url)   // mailto:, zoommtg:, etc.
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Download when the server says "attachment" (even for PDFs, CSVs, images…) or WebKit can't show it.
        let disposition = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let isAttachment = disposition.hasPrefix("attachment")
        decisionHandler(response.isForMainFrame && (isAttachment || !response.canShowMIMEType) ? .download
                        : (response.canShowMIMEType ? .allow : .download))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView.url?.absoluteString != "about:blank" { errorToken = nil; offlineToken = nil }
        changed()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if errorToken == nil {
            retryCount = 0
            if let u = webView.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
                HistoryStore.shared.recordVisit(url: u, title: webView.title ?? "")
            }
        }
        pushHome()
        changed()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        startedDownload(download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        startedDownload(download)
    }

    private func startedDownload(_ download: WKDownload) {
        DownloadCenter.shared.track(download)
        owner?.showDownloads(nil)
        // A link that opened a new blank tab just to download a file: close that tab, like Chrome.
        if webView.backForwardList.currentItem == nil, webView.url == nil || webView.url?.absoluteString == "about:blank",
           let owner = owner, owner.tabs.count > 1 {
            DispatchQueue.main.async { owner.closeTab(self) }
        }
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank links and popups (e.g. "Sign in with Google") open as a new tab next to this one
        if let owner = owner {
            return owner.addTab(url: nil, configuration: configuration, activate: true, after: self).webView
        }
        return AppDelegate.shared.openTab(url: nil, configuration: configuration, relativeTo: nil, activate: true).webView
    }

    func webViewDidClose(_ webView: WKWebView) { owner?.closeTab(self) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let w = hostWindow else { completionHandler(); return }
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? "This page says"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.beginSheetModal(for: w) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let w = hostWindow else { completionHandler(false); return }
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? "This page says"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { r in completionHandler(r == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let w = hostWindow else { completionHandler(nil); return }
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        p.beginSheetModal(for: w) { r in completionHandler(r == .OK ? p.urls : nil) }
    }
}

// MARK: - Browser window

final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private(set) var tabs: [BrowserTab] = []
    private(set) var activeTab: BrowserTab?
    var onClose: ((BrowserWindowController) -> Void)?

    static let stripHeight: CGFloat = 40
    static let toolbarHeight: CGFloat = 44

    private let tabStrip = TabStripView()
    private let toolbarRow = ToolbarRowView()
    private let backButton = HoverButton(symbol: "chevron.left", tip: "Back", target: nil, action: nil)
    private let forwardButton = HoverButton(symbol: "chevron.right", tip: "Forward", target: nil, action: nil)
    private let reloadButton = HoverButton(symbol: "arrow.clockwise", tip: "Reload", target: nil, action: nil)
    private let homeButton = HoverButton(symbol: "house", tip: "Home", target: nil, action: nil)
    private let settingsButton = HoverButton(symbol: "gearshape", tip: "Settings", target: nil, action: nil)
    private let downloadsButton = DownloadsButton(symbol: "arrow.down.circle", tip: "Downloads (⌥⌘L)", target: nil, action: nil)
    private var downloadsPopover: NSPopover?
    private let addressField = AddressField()
    private let omnibox = OmniboxView()
    private let lockIcon = NSImageView()
    private let progressLine = ProgressLine()
    private let webContainer = NSView()

    init(url: URL?, configuration: WKWebViewConfiguration? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "LiteBrowser"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed          // we draw our own tabs
        window.minSize = NSSize(width: 520, height: 340)
        window.backgroundColor = Theme.strip
        super.init(window: window)
        window.delegate = self
        buildLayout(in: window)
        addTab(url: url, configuration: configuration, activate: true)
        NotificationCenter.default.addObserver(self, selector: #selector(downloadsChanged),
                                               name: .liteDownloadsChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Downloads

    @objc private func downloadsChanged() {
        let center = DownloadCenter.shared
        downloadsButton.isHidden = center.items.isEmpty
        downloadsButton.active = center.hasActive
        downloadsButton.fraction = center.activeFraction
    }

    /// Shows the downloads list under the toolbar button (⌥⌘L).
    @objc func showDownloads(_ sender: Any?) {
        downloadsButton.isHidden = false
        if let p = downloadsPopover, p.isShown { if sender != nil { p.close() }; return }
        guard window?.isVisible == true else { return }
        let p = NSPopover()
        p.contentViewController = DownloadsViewController()
        p.behavior = .transient
        downloadsPopover = p
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.downloadsButton.window != nil else { return }
            p.show(relativeTo: self.downloadsButton.bounds, of: self.downloadsButton, preferredEdge: self.downloadsButton.isFlipped ? .maxY : .minY)
        }
    }

    // MARK: Layout

    private func buildLayout(in window: NSWindow) {
        tabStrip.controller = self

        for (b, sel) in [(backButton, #selector(goBack(_:))), (forwardButton, #selector(goForward(_:))),
                         (reloadButton, #selector(reloadOrStop(_:))), (homeButton, #selector(goHome(_:))),
                         (downloadsButton, #selector(showDownloads(_:))), (settingsButton, #selector(openSettings(_:)))] {
            b.target = self
            b.action = sel
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 32), b.heightAnchor.constraint(equalToConstant: 30)])
        }

        // Omnibox: lock icon + borderless field inside a rounded capsule
        lockIcon.imageScaling = .scaleProportionallyDown
        addressField.placeholderString = "Search Google or type a URL"
        addressField.isBordered = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        addressField.font = .systemFont(ofSize: 14)
        addressField.usesSingleLineMode = true
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.sendsActionOnEndEditing = false
        addressField.target = self
        addressField.action = #selector(addressEntered(_:))
        addressField.onFocusChange = { [weak self] focused in
            self?.omnibox.focused = focused
            if !focused { DispatchQueue.main.async { self?.refreshChrome() } }
        }
        omnibox.field = addressField
        for v in [lockIcon, addressField] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            omnibox.addSubview(v)
        }
        omnibox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            omnibox.heightAnchor.constraint(equalToConstant: 32),
            lockIcon.leadingAnchor.constraint(equalTo: omnibox.leadingAnchor, constant: 12),
            lockIcon.centerYAnchor.constraint(equalTo: omnibox.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 14),
            lockIcon.heightAnchor.constraint(equalToConstant: 14),
            addressField.leadingAnchor.constraint(equalTo: lockIcon.trailingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: omnibox.trailingAnchor, constant: -12),
            addressField.centerYAnchor.constraint(equalTo: omnibox.centerYAnchor),
        ])

        downloadsButton.isHidden = DownloadCenter.shared.items.isEmpty
        let row = NSStackView(views: [backButton, forwardButton, reloadButton, homeButton, omnibox, downloadsButton, settingsButton])
        row.orientation = .horizontal
        row.spacing = 2
        row.setCustomSpacing(10, after: homeButton)
        row.setCustomSpacing(10, after: omnibox)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        omnibox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        toolbarRow.addSubview(row)
        progressLine.translatesAutoresizingMaskIntoConstraints = false
        toolbarRow.addSubview(progressLine)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: toolbarRow.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: toolbarRow.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: toolbarRow.centerYAnchor),
            progressLine.leadingAnchor.constraint(equalTo: toolbarRow.leadingAnchor),
            progressLine.trailingAnchor.constraint(equalTo: toolbarRow.trailingAnchor),
            progressLine.bottomAnchor.constraint(equalTo: toolbarRow.bottomAnchor),
            progressLine.heightAnchor.constraint(equalToConstant: 2),
        ])

        let content = NSView()
        for v in [tabStrip, toolbarRow, webContainer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: content.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: Self.stripHeight),
            toolbarRow.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            toolbarRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbarRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbarRow.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),
            webContainer.topAnchor.constraint(equalTo: toolbarRow.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        positionTrafficLights()
    }

    /// Centres the red/yellow/green buttons vertically in the taller tab strip, like Chrome.
    private func positionTrafficLights() {
        guard let w = window else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, t) in types.enumerated() {
            guard let b = w.standardWindowButton(t), let sup = b.superview else { continue }
            // centre the buttons on the tabs (tabs span y 6…40, so their middle is ~23pt from the top)
            let y = sup.bounds.height - 23 - b.frame.height / 2
            b.setFrameOrigin(NSPoint(x: 14 + CGFloat(i) * 20, y: max(0, y)))
        }
    }

    // MARK: Tabs

    @discardableResult
    func addTab(url: URL?, configuration: WKWebViewConfiguration? = nil, activate: Bool, after: BrowserTab? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: configuration)
        tab.owner = self
        var index = tabs.count
        if let after = after, let i = tabs.firstIndex(where: { $0 === after }) {
            // like Chrome: open next to the tab it came from (after other tabs it opened)
            index = i + 1
        }
        tabs.insert(tab, at: index)
        if let url = url { tab.load(url) }
        if activate || activeTab == nil { select(tab) } else { tabStrip.reload() }
        return tab
    }

    func select(_ tab: BrowserTab) {
        let previous = activeTab
        if previous !== tab {
            previous?.webView.removeFromSuperview()
            activeTab = tab
            let wv = tab.webView
            wv.translatesAutoresizingMaskIntoConstraints = false
            webContainer.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: webContainer.topAnchor),
                wv.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
                wv.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            ])
        }
        tabStrip.reload()
        refreshChrome()
        tab.pushHome()
        if tab.isHomePage || tab.webView.url == nil { focusAddressBar(nil) } else { window?.makeFirstResponder(tab.webView) }
    }

    func closeTab(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        AppDelegate.shared.noteClosedTab(tab.currentURL)
        tab.tearDown()
        tabs.remove(at: i)
        if tabs.isEmpty { window?.close(); return }
        if activeTab === tab {
            tab.webView.removeFromSuperview()
            activeTab = nil
            select(tabs[min(i, tabs.count - 1)])
        } else {
            tabStrip.reload()
        }
    }

    func closeOtherTabs(than keep: BrowserTab) {
        for t in tabs where t !== keep { closeTab(t) }
        select(keep)
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        let t = tabs.remove(at: from)
        tabs.insert(t, at: to)
    }

    func selectTab(number n: Int) {
        guard !tabs.isEmpty else { return }
        let index = n == 9 ? tabs.count - 1 : n - 1
        if tabs.indices.contains(index) { select(tabs[index]) }
    }

    @objc func selectNextTab(_ sender: Any?) { cycleTab(by: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { cycleTab(by: -1) }

    private func cycleTab(by step: Int) {
        guard let a = activeTab, let i = tabs.firstIndex(where: { $0 === a }), tabs.count > 1 else { return }
        select(tabs[(i + step + tabs.count) % tabs.count])
    }

    @objc func newTabHere(_ sender: Any?) { addTab(url: Config.home, activate: true) }
    @objc func closeCurrentTab(_ sender: Any?) { if let t = activeTab { closeTab(t) } }

    /// Every tab reports changes here; refresh its strip entry, and the toolbar if it's the active one.
    func tabDidChange(_ tab: BrowserTab) {
        tabStrip.update(tab)
        if tab === activeTab { refreshChrome() }
    }

    // MARK: Toolbar state

    private func refreshChrome() {
        guard let tab = activeTab else { return }
        let wv = tab.webView
        backButton.isEnabled = wv.canGoBack
        forwardButton.isEnabled = wv.canGoForward
        let loading = wv.isLoading
        reloadButton.setSymbol(loading ? "xmark" : "arrow.clockwise", tip: loading ? "Stop" : "Reload")
        progressLine.progress = loading ? max(0.08, wv.estimatedProgress) : 0
        if window?.title != tab.displayTitle {
            window?.title = tab.displayTitle
            positionTrafficLights()      // AppKit can re-lay out the title bar when the title changes
        }

        let shown = tab.shownURL
        let isBlank = shown == nil || shown?.absoluteString == "about:blank" || Config.isHome(shown)
        var symbol = "magnifyingglass", tint = NSColor.secondaryLabelColor, tip = "Search Google or type a URL"
        if !isBlank, let u = shown {
            switch u.scheme?.lowercased() {
            case "https": symbol = "lock.fill"; tip = "Secure connection to \(u.host ?? "")"
            case "http": symbol = "exclamationmark.triangle.fill"; tint = .systemOrange; tip = "Not secure: this page isn't encrypted"
            default: symbol = "doc"; tip = u.absoluteString
            }
        }
        lockIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        lockIcon.contentTintColor = tint
        lockIcon.toolTip = tip

        addressField.fullText = isBlank ? "" : (shown?.absoluteString ?? "")
        if addressField.currentEditor() == nil {
            addressField.stringValue = isBlank ? "" : shown.map(prettyURL) ?? ""
        }
    }

    // MARK: Actions (menu items reach these through the responder chain)

    @objc func addressEntered(_ sender: NSTextField) {
        guard let tab = activeTab else { return }
        tab.load(resolveInput(sender.stringValue))
        window?.makeFirstResponder(tab.webView)
    }

    @objc func goBack(_ sender: Any?) { activeTab?.webView.goBack() }
    @objc func goForward(_ sender: Any?) { activeTab?.webView.goForward() }
    @objc func goHome(_ sender: Any?) { activeTab?.load(Config.home) }
    @objc func stopLoading(_ sender: Any?) { activeTab?.webView.stopLoading() }
    @objc func reloadOrStop(_ sender: Any?) {
        guard let t = activeTab else { return }
        t.webView.isLoading ? t.webView.stopLoading() : t.reloadPage()
    }
    @objc func reloadPage(_ sender: Any?) { activeTab?.reloadPage() }
    @objc func focusAddressBar(_ sender: Any?) { window?.makeFirstResponder(addressField) }
    @objc func zoomIn(_ sender: Any?) { if let w = activeTab?.webView { w.pageZoom = min(w.pageZoom + 0.1, 3) } }
    @objc func zoomOut(_ sender: Any?) { if let w = activeTab?.webView { w.pageZoom = max(w.pageZoom - 0.1, 0.3) } }
    @objc func actualSize(_ sender: Any?) { activeTab?.webView.pageZoom = 1 }
    @objc func openSettings(_ sender: Any?) { AppDelegate.shared.showSettings(sender) }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        activeTab?.pushHome()
        positionTrafficLights()
    }
    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowWillEnterFullScreen(_ notification: Notification) { tabStrip.leftInset = 10 }
    func windowDidExitFullScreen(_ notification: Notification) {
        tabStrip.leftInset = 78
        positionTrafficLights()
    }

    func windowWillClose(_ notification: Notification) {
        for t in tabs {
            AppDelegate.shared.noteClosedTab(t.currentURL)
            t.tearDown()
        }
        tabs.removeAll()
        activeTab = nil
        onClose?(self)
    }
}
