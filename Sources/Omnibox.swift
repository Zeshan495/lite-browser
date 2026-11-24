// LiteBrowser — smart address bar: Google suggestions, history matches, inline autocomplete.

import Cocoa

struct Suggestion {
    enum Kind { case search, page, url }
    let kind: Kind
    let title: String
    let subtitle: String
    let url: URL
}

/// One row in the suggestions dropdown.
final class SuggestionRow: NSView {
    let suggestion: Suggestion
    var highlighted = false { didSet { needsDisplay = true; updateColors() } }
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init(_ s: Suggestion) {
        suggestion = s
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 34))
        let symbol: String
        switch s.kind {
        case .search: symbol = "magnifyingglass"
        case .page: symbol = "clock.arrow.circlepath"
        case .url: symbol = "globe"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        if s.kind == .page {
            FaviconCache.shared.icon(for: s.url) { [weak self] img in if let img = img { self?.icon.image = img } }
        }
        title.stringValue = s.title
        title.font = .systemFont(ofSize: 13.5)
        title.lineBreakMode = .byTruncatingTail
        subtitle.stringValue = s.subtitle
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for v in [icon, title, subtitle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            subtitle.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateColors() {
        title.textColor = highlighted ? .white : .labelColor
        subtitle.textColor = highlighted ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        icon.contentTintColor = highlighted ? .white : .secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 7, yRadius: 7).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// Drives the dropdown under the address bar. It is the address field's delegate.
final class OmniboxController: NSObject, NSTextFieldDelegate {
    private weak var field: AddressField?
    private weak var anchor: NSView?
    private let onOpen: (URL) -> Void
    private var panel: NSPanel?
    private let list = NSStackView()
    private var rows: [SuggestionRow] = []
    private var selected = -1
    private var typedLength = 0
    private var knownHosts: [String] = []
    private var fetchGeneration = 0
    private var remote: [String] = []
    private var lastQuery = ""

    init(field: AddressField, anchor: NSView, onOpen: @escaping (URL) -> Void) {
        self.field = field
        self.anchor = anchor
        self.onOpen = onOpen
        super.init()
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidBeginEditing(_ obj: Notification) {
        knownHosts = HistoryStore.shared.topSites(limit: 300).compactMap { $0["host"] }
        typedLength = 0
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let editor = field?.currentEditor() as? NSTextView else { return }
        let typed = editor.string
        let grew = typed.count > typedLength
        typedLength = typed.count

        // Inline autocomplete for sites you visit ("git" → "github.com")
        if grew, typed.count >= 2, !typed.contains(" "), editor.selectedRange().location == (typed as NSString).length {
            let lower = typed.lowercased()
            if let host = knownHosts.first(where: { $0.hasPrefix(lower) && $0.count > lower.count }) {
                let completion = typed + host.dropFirst(lower.count)
                editor.string = completion
                editor.setSelectedRange(NSRange(location: (typed as NSString).length,
                                                length: (completion as NSString).length - (typed as NSString).length))
            }
        }
        update(query: typed)
    }

    func controlTextDidEndEditing(_ obj: Notification) { hide() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            guard !rows.isEmpty else { return false }
            select(min(selected + 1, rows.count - 1)); return true
        case #selector(NSResponder.moveUp(_:)):
            guard !rows.isEmpty else { return false }
            select(max(selected - 1, -1)); return true
        case #selector(NSResponder.insertNewline(_:)):
            if selected >= 0, selected < rows.count { choose(rows[selected].suggestion); return true }
            hide(); return false                                   // the field's action opens what was typed
        case #selector(NSResponder.cancelOperation(_:)):
            if panel?.isVisible == true { hide(); return true }
            return false
        default:
            return false
        }
    }

    // MARK: Suggestions

    private func update(query raw: String) {
        let q = raw.trimmingCharacters(in: .whitespaces)
        lastQuery = q
        guard !q.isEmpty else { hide(); return }
        rebuild()
        guard Prefs.searchSuggestions, q.count < 80 else { remote = []; return }
        fetchGeneration += 1
        let gen = fetchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self, gen == self.fetchGeneration else { return }
            self.fetchGoogle(q, gen: gen)
        }
    }

    private func fetchGoogle(_ q: String, gen: Int) {
        var c = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        c.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: q),
                        URLQueryItem(name: "ie", value: "utf-8"), URLQueryItem(name: "oe", value: "utf-8")]
        URLSession.shared.dataTask(with: URLRequest(url: c.url!, timeoutInterval: 3)) { [weak self] data, _, _ in
            guard let data = data, let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
                  arr.count > 1, let list = arr[1] as? [String] else { return }
            DispatchQueue.main.async {
                guard let self = self, gen == self.fetchGeneration else { return }
                self.remote = list
                self.rebuild()
            }
        }.resume()
    }

    private func suggestions() -> [Suggestion] {
        let q = lastQuery
        let lower = q.lowercased()
        var out: [Suggestion] = []

        // 1) What you typed
        let typedURL = resolveInput(q)
        if HistoryStore.googleQuery(typedURL) != nil {
            out.append(Suggestion(kind: .search, title: q, subtitle: "Google Search", url: typedURL))
        } else {
            out.append(Suggestion(kind: .url, title: prettyURL(typedURL), subtitle: "Open site", url: typedURL))
        }

        // 2) Pages from your history
        var seen = Set<String>()
        for item in HistoryStore.shared.items where out.count < 5 {
            guard !seen.contains(item.url), let u = URL(string: item.url), HistoryStore.googleQuery(u) == nil else { continue }
            if item.url.lowercased().contains(lower) || item.title.lowercased().contains(lower) {
                seen.insert(item.url)
                out.append(Suggestion(kind: .page, title: item.title.isEmpty ? prettyURL(u) : item.title,
                                      subtitle: prettyURL(u), url: u))
            }
        }

        // 3) Google suggestions
        for s in remote where out.count < 10 && s.lowercased() != lower {
            out.append(Suggestion(kind: .search, title: s, subtitle: "", url: googleSearchURL(s)))
        }
        return out
    }

    private func rebuild() {
        let items = suggestions()
        guard !items.isEmpty, field?.currentEditor() != nil else { hide(); return }
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { i, s in
            let r = SuggestionRow(s)
            r.onClick = { [weak self] in self?.choose(s) }
            r.onHover = { [weak self] in self?.select(i) }
            r.translatesAutoresizingMaskIntoConstraints = false
            r.heightAnchor.constraint(equalToConstant: 34).isActive = true
            return r
        }
        selected = -1
        show()
    }

    private func select(_ i: Int) {
        selected = i
        for (n, r) in rows.enumerated() { r.highlighted = n == i }
    }

    private func choose(_ s: Suggestion) {
        hide()
        onOpen(s.url)
    }

    // MARK: Dropdown window

    private func show() {
        guard let anchor = anchor, let window = anchor.window else { return }
        let p = panel ?? makePanel()
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for r in rows {
            list.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let height = CGFloat(rows.count) * 34 + CGFloat(max(0, rows.count - 1)) * 1 + 12
        p.setFrame(NSRect(x: rect.minX, y: rect.minY - height - 6, width: rect.width, height: height), display: true)
        if p.parent == nil { window.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
    }

    func hide() {
        fetchGeneration += 1
        selected = -1
        if let p = panel, p.isVisible {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.becomesKeyOnlyIfNeeded = true
        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        list.orientation = .vertical
        list.spacing = 1
        list.alignment = .leading
        list.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: bg.topAnchor, constant: 6),
            list.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
        ])
        p.contentView = bg
        panel = p
        return p
    }
}

// MARK: - Find on page bar (⌘F)

final class FindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let prev = HoverButton(symbol: "chevron.up", tip: "Previous (⇧⌘G)", pointSize: 12, target: nil, action: nil)
    private let next = HoverButton(symbol: "chevron.down", tip: "Next (⌘G)", pointSize: 12, target: nil, action: nil)
    private let done = NSButton(title: "Done", target: nil, action: nil)
    var onFind: ((String, Bool) -> Void)?       // (text, backwards)
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Find on page"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = self
        field.target = self
        field.action = #selector(searchChanged)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        prev.target = self; prev.action = #selector(findPrev)
        next.target = self; next.action = #selector(findNext)
        done.bezelStyle = .rounded
        done.target = self; done.action = #selector(closeTapped)
        let row = NSStackView(views: [field, status, prev, next, done])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 280),
            prev.widthAnchor.constraint(equalToConstant: 26), next.widthAnchor.constraint(equalToConstant: 26),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.toolbar.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func setResult(found: Bool) {
        let empty = field.stringValue.isEmpty
        status.stringValue = empty ? "" : (found ? "" : "Not found")
        status.textColor = found ? .secondaryLabelColor : .systemRed
    }

    @objc private func searchChanged() { onFind?(field.stringValue, false) }
    @objc func findNext() { onFind?(field.stringValue, false) }
    @objc func findPrev() { onFind?(field.stringValue, true) }
    @objc private func closeTapped() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let back = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            onFind?(field.stringValue, back)
            return true
        }
        return false
    }
}
