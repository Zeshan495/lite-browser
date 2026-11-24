// LiteBrowser — a tiny native macOS browser.
// Google search, native tabs, and automatic recovery from DNS errors
// (the problem Chrome reports as DNS_PROBE_POSSIBLE / DNS_PROBE_FINISHED_*).

import Cocoa
import WebKit
import Network

// MARK: - Configuration

enum Config {
    static let google = URL(string: "https://www.google.com/")!
    /// The branded LiteBrowser home page bundled in the app (falls back to Google).
    static var home: URL { Bundle.main.url(forResource: "home", withExtension: "html") ?? google }
    static func isHome(_ url: URL?) -> Bool {
        guard let url = url, url.isFileURL, let res = Bundle.main.resourcePath else { return false }
        return url.lastPathComponent == "home.html" && url.path.hasPrefix(res)
    }
    static let searchBase = "https://www.google.com/search"
    static let maxAutoRetries = 3
    /// Public resolvers used by "Fix DNS": Cloudflare + Google.
    static let publicDNS = ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"]
}

func googleSearchURL(_ query: String) -> URL {
    var c = URLComponents(string: Config.searchBase)!
    c.queryItems = [URLQueryItem(name: "q", value: query)]
    return c.url!
}

/// Turns address-bar text into a URL: full URLs and domains are opened, anything else is searched on Google.
func resolveInput(_ raw: String) -> URL {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return Config.home }
    if let u = URL(string: text), let scheme = u.scheme?.lowercased(),
       ["http", "https", "file", "about"].contains(scheme) {
        return u
    }
    let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost"))
    if looksLikeHost {
        let local = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("192.168.")
        if let u = URL(string: "\(local ? "http" : "https")://\(text)"), u.host != nil { return u }
    }
    return googleSearchURL(text)
}

/// What the address bar shows when you're not typing: "github.com/apple", or the search words on Google.
func prettyURL(_ u: URL) -> String {
    if let q = HistoryStore.googleQuery(u) { return q }
    guard var host = u.host else { return u.absoluteString }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    let path = u.path == "/" ? "" : u.path
    return host + path
}

// MARK: - Address bar pieces

/// Text field that switches from the short address to the full URL when you click into it.
final class AddressField: NSTextField {
    var fullText = ""
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            stringValue = fullText
            onFocusChange?(true)
            // after the click finishes, select everything so typing replaces the URL (like Chrome)
            DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

/// The rounded "omnibox" capsule behind the lock icon and address field.
final class OmniboxView: NSView {
    weak var field: NSTextField?
    var focused = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (focused ? NSColor.textBackgroundColor : NSColor.quaternaryLabelColor).cgColor
        layer?.borderWidth = focused ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
    }
    override func mouseDown(with event: NSEvent) {
        if let f = field { window?.makeFirstResponder(f) }
    }
}

// MARK: - DNS-over-HTTPS check (talks to resolvers by IP, so it works even when system DNS is broken)

enum DoHResult { case resolved, noSuchDomain, unreachable }

enum DoH {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 6
        return URLSession(configuration: c)
    }()
    private static let endpoints = ["https://1.1.1.1/dns-query", "https://8.8.8.8/resolve"]

    static func lookup(_ host: String, completion: @escaping (DoHResult) -> Void) {
        DoH.attempt(host, index: 0, sawNX: false) { r in DispatchQueue.main.async { completion(r) } }
    }

    /// IPv4 addresses for host according to public DNS (Cloudflare, then Google). Empty if none/unreachable.
    static func addresses(_ host: String, completion: @escaping ([String]) -> Void) {
        func tryEndpoint(_ index: Int) {
            guard index < DoH.endpoints.count else { completion([]); return }
            var c = URLComponents(string: DoH.endpoints[index])!
            c.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
            var req = URLRequest(url: c.url!)
            req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            DoH.session.dataTask(with: req) { data, _, err in
                guard err == nil, let data = data,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let answers = obj["Answer"] as? [[String: Any]] else { tryEndpoint(index + 1); return }
                let ips = answers.compactMap { ($0["type"] as? Int) == 1 ? $0["data"] as? String : nil }
                if ips.isEmpty { tryEndpoint(index + 1) } else { completion(ips) }
            }.resume()
        }
        tryEndpoint(0)
    }

    private static func attempt(_ host: String, index: Int, sawNX: Bool, done: @escaping (DoHResult) -> Void) {
        guard index < endpoints.count else { done(sawNX ? .noSuchDomain : .unreachable); return }
        var c = URLComponents(string: endpoints[index])!
        c.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
        var req = URLRequest(url: c.url!)
        req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { data, _, err in
            guard err == nil, let data = data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let status = obj["Status"] as? Int else {
                DoH.attempt(host, index: index + 1, sawNX: sawNX, done: done)
                return
            }
            if status == 0, let answers = obj["Answer"] as? [Any], !answers.isEmpty {
                done(.resolved)
            } else {
                DoH.attempt(host, index: index + 1, sawNX: true, done: done)
            }
        }.resume()
    }
}

// MARK: - Connection diagnostics: works out *why* a site won't load

enum Diagnosis {
    case blockedByDNS(answers: [String])   // your DNS answered 0.0.0.0 / 127.x / a private address
    case wrongAddress                      // your DNS's address doesn't work, public DNS's address does
    case unreachable                       // nothing connects: site down, or your network/ISP blocks it
    case slow                              // the site's address connects fine; the site itself is slow
}

enum Diagnostics {
    /// Resolves with the Mac's own DNS (including any encrypted-DNS profile).
    static func systemResolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buf)
                if !out.contains(ip) { out.append(ip) }
            }
            p = ai.pointee.ai_next
        }
        return out
    }

    /// Addresses a DNS filter or ISP block typically hands out instead of the real one.
    static func isBlockAddress(_ ip: String) -> Bool {
        if ["0.0.0.0", "::", "::1"].contains(ip) || ip.hasPrefix("127.") || ip.hasPrefix("10.")
            || ip.hasPrefix("192.168.") || ip.hasPrefix("169.254.") || ip.lowercased().hasPrefix("fe80") { return true }
        if ip.hasPrefix("172."), let second = Int(ip.split(separator: ".").dropFirst().first ?? ""), (16...31).contains(second) {
            return true
        }
        return false
    }

    /// Blocking check: can we open a TCP connection to ip:443 within 4 seconds?
    static func canConnect(_ ip: String) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "litebrowser.connect")
        var ok = false
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: 443, using: .tcp)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: ok = true; sem.signal()
            case .failed, .cancelled: sem.signal()
            default: break
            }
        }
        conn.start(queue: queue)
        _ = sem.wait(timeout: .now() + 4)
        conn.cancel()
        return queue.sync { ok }
    }

    static func run(host: String, completion: @escaping (Diagnosis) -> Void) {
        DoH.addresses(host) { publicIPs in
            DispatchQueue.global(qos: .userInitiated).async {
                let mine = Diagnostics.systemResolve(host)
                let result: Diagnosis
                if !mine.isEmpty && mine.allSatisfy(Diagnostics.isBlockAddress) {
                    result = .blockedByDNS(answers: mine)
                } else if mine.prefix(2).contains(where: Diagnostics.canConnect) {
                    result = .slow
                } else if publicIPs.prefix(2).contains(where: Diagnostics.canConnect) {
                    result = .wrongAddress
                } else {
                    result = .unreachable
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
}

// MARK: - DNS repair (needs admin password; uses macOS's own networksetup tool)

enum DNSFixer {
    enum Outcome { case ok, cancelled, failed(String) }

    /// servers == nil resets every network service to automatic (DHCP) DNS.
    static func apply(servers: [String]?) -> Outcome {
        let arg = servers?.joined(separator: " ") ?? "Empty"
        let script = """
        #!/bin/sh
        /usr/bin/profiles remove -identifier \(EncryptedDNS.profileID) >/dev/null 2>&1
        /usr/sbin/networksetup -listallnetworkservices | /usr/bin/tail -n +2 | /usr/bin/sed 's/^\\*//' | while IFS= read -r svc; do
          /usr/sbin/networksetup -setdnsservers "$svc" \(arg) >/dev/null 2>&1
        done
        /usr/bin/dscacheutil -flushcache
        /usr/bin/killall -HUP mDNSResponder 2>/dev/null
        exit 0
        """
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("litebrowser-dns-\(UUID().uuidString).sh")
        do { try script.write(toFile: path, atomically: true, encoding: .utf8) } catch {
            return .failed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"/bin/sh \(path)\" with administrator privileges")?
            .executeAndReturnError(&err)
        guard let e = err else { return .ok }
        if (e[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed((e[NSAppleScript.errorMessage] as? String) ?? "Unknown error")
    }
}

// MARK: - Friendly error pages (replace the browser's DNS_PROBE_* screens)

enum ErrorKind {
    case dnsBroken(host: String)
    case noSuchSite(host: String)
    case offline
    case checking(host: String)
    case blockedByDNS(host: String, answers: [String], dns: String)
    case wrongAddress(host: String, dns: String)
    case unreachable(host: String)
    case other(title: String, detail: String)
}

func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

func errorPageHTML(_ kind: ErrorKind, token: String) -> String {
    var title = "", body = "", note = ""
    var buttons: [(label: String, action: String, primary: Bool)] = []
    switch kind {
    case .dnsBroken(let host):
        title = "Your DNS couldn't find this site"
        body = "<b>\(escapeHTML(host))</b> is online. LiteBrowser confirmed it through secure public DNS, but the DNS server your Mac uses didn't give an address for it. That DNS server is either failing or blocking this site. (Chrome shows this as <code>DNS_PROBE_POSSIBLE</code>.)"
        note = "“Fix DNS” switches your Mac to the DNS servers chosen in Settings › DNS (Cloudflare + Google by default) and flushes the DNS cache. Undo any time from Network › Reset DNS to Automatic."
        buttons = [("Fix DNS automatically", "fixdns", true), ("Try again", "retry", false)]
    case .noSuchSite(let host):
        title = "That site doesn't exist"
        body = "Public DNS has no record of <b>\(escapeHTML(host))</b>. Check the spelling, or search for it instead."
        buttons = [("Search Google", "search", true), ("Try again", "retry", false)]
    case .offline:
        title = "You're offline"
        body = "LiteBrowser can't reach the internet right now. Check Wi-Fi or your cable."
        note = "This page will reload by itself as soon as you're back online."
        buttons = [("Try again", "retry", true), ("Fix DNS", "fixdns", false)]
    case .checking(let host):
        title = "Checking why \(host) won't load…"
        body = "LiteBrowser is testing your DNS and your connection to <b>\(escapeHTML(host))</b>. This takes a few seconds."
    case .blockedByDNS(let host, let answers, let dns):
        title = "\(host) is blocked by your DNS"
        body = "Your DNS server (<b>\(escapeHTML(dns))</b>) answered with <code>\(escapeHTML(answers.joined(separator: ", ")))</code> instead of the site's real address, so the page can never load. DNS filters often block categories like crypto, ads, gambling or adult sites."
        note = "If you run this DNS server, allow \(host) in its blocklist. Otherwise, switch to public DNS (Cloudflare + Google) in Settings › DNS."
        buttons = [("Use Cloudflare + Google DNS", "publicdns", true), ("Try again", "retry", false), ("DNS settings", "dnssettings", false)]
    case .wrongAddress(let host, let dns):
        title = "Your DNS is sending \(host) to the wrong place"
        body = "The address your DNS (<b>\(escapeHTML(dns))</b>) gives for <b>\(escapeHTML(host))</b> doesn't respond, but the address from public DNS works fine. Your DNS server or internet provider is probably redirecting or blocking this site."
        buttons = [("Use Cloudflare + Google DNS", "publicdns", true), ("Try again", "retry", false), ("DNS settings", "dnssettings", false)]
    case .unreachable(let host):
        title = "Your network can't reach \(host)"
        body = "DNS is fine, but LiteBrowser couldn't connect to <b>\(escapeHTML(host))</b> at any of its addresses, even though your internet works. Either the site is down right now, or your network or internet provider is blocking it."
        note = "Try another network, such as your phone's hotspot. If the site loads there, your Wi-Fi or provider is blocking it."
        buttons = [("Try again", "retry", true), ("Is it down for everyone?", "isdown", false)]
    case .other(let t, let d):
        title = t
        body = escapeHTML(d)
        buttons = [("Try again", "retry", true)]
    }
    let buttonHTML = buttons.map {
        "<button class=\"\($0.primary ? "primary" : "")\" onclick=\"send('\($0.action)')\">\(escapeHTML($0.label))</button>"
    }.joined()
    return """
    <!doctype html><html><head><meta charset="utf-8"><title>\(escapeHTML(title))</title>
    <style>
    :root{color-scheme:light dark}
    body{font:15px -apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;min-height:88vh;margin:0}
    .card{max-width:540px;padding:32px}
    h1{font-size:24px;font-weight:600;margin:0 0 12px}
    p{line-height:1.55;opacity:.85}
    code{font-size:13px;opacity:.8}
    button{font:inherit;padding:8px 18px;margin:14px 8px 0 0;border-radius:8px;border:1px solid #8886;background:transparent;color:inherit;cursor:pointer}
    button.primary{background:#1a73e8;color:#fff;border-color:#1a73e8}
    .note{font-size:13px;opacity:.6;margin-top:22px}
    </style></head><body><div class="card">
    <h1>\(escapeHTML(title))</h1><p>\(body)</p><div>\(buttonHTML)</div>
    \(note.isEmpty ? "" : "<p class=\"note\">\(escapeHTML(note))</p>")
    </div>
    <script>function send(a){window.webkit.messageHandlers.lite.postMessage({action:a,token:'\(token)'})}</script>
    </body></html>
    """
}

// MARK: - Weak proxy so the script handler doesn't retain the window controller

final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

// MARK: - Saved preferences

enum Prefs {
    private static let d = UserDefaults.standard

    /// DNS servers chosen in Settings › DNS (used by "Fix DNS" too).
    static var dnsServers: [String] {
        get {
            let saved = d.array(forKey: "dnsServers") as? [String] ?? []
            return saved.isEmpty ? Config.publicDNS : saved
        }
        set { d.set(newValue, forKey: "dnsServers") }
    }

    /// Sites removed from the home page's Top sites.
    static var hiddenTopSites: Set<String> {
        get { Set(d.array(forKey: "hiddenTopSites") as? [String] ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "hiddenTopSites") }
    }

    /// Sites whose cookies and logins survive "Clear Browsing Data".
    static var keptSites: Set<String> {
        get { Set(d.array(forKey: "keptSites") as? [String] ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "keptSites") }
    }
}

struct DNSPreset { let name: String; let note: String; let servers: [String] }

enum DNSPresets {
    static let list: [DNSPreset] = [
        DNSPreset(name: "Cloudflare", note: "Fastest for most people", servers: ["1.1.1.1", "1.0.0.1"]),
        DNSPreset(name: "Google", note: "Very reliable", servers: ["8.8.8.8", "8.8.4.4"]),
        DNSPreset(name: "Cloudflare + Google", note: "Best of both (default)", servers: Config.publicDNS),
        DNSPreset(name: "Quad9", note: "Blocks malicious sites", servers: ["9.9.9.9", "149.112.112.112"]),
        DNSPreset(name: "AdGuard", note: "Blocks ads and trackers", servers: ["94.140.14.14", "94.140.15.15"]),
        DNSPreset(name: "Cloudflare Family", note: "Blocks malware and adult sites", servers: ["1.1.1.3", "1.0.0.3"]),
        DNSPreset(name: "OpenDNS", note: "Cisco, with phishing protection", servers: ["208.67.222.222", "208.67.220.220"]),
    ]

    static func isValid(_ s: String) -> Bool { DNSEntry(s) != nil }

    /// Either plain IP addresses, or exactly one encrypted server (hostname or https:// URL).
    static func validate(_ raw: [String]) -> (entries: [DNSEntry]?, error: String?) {
        let list = raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if list.isEmpty { return (nil, "Add at least one DNS server.") }
        var entries: [DNSEntry] = []
        for s in list {
            guard let e = DNSEntry(s) else {
                return (nil, "“\(s)” isn't a valid DNS server. Use an IP address (1.1.1.1), a hostname (dns.example.com) or an https:// address.")
            }
            entries.append(e)
        }
        let encrypted = entries.filter { $0.isEncrypted }
        if encrypted.count > 1 { return (nil, "Use only one secure DNS hostname at a time.") }
        if encrypted.count == 1 && entries.count > 1 {
            return (nil, "Use either IP addresses or one secure DNS hostname, not both together.")
        }
        return (entries, nil)
    }
}

/// One DNS server as typed by the user.
enum DNSEntry {
    case ip(String)
    case tls(host: String)      // DNS-over-TLS, port 853 (what Android calls "Private DNS")
    case https(URL)             // DNS-over-HTTPS

    init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if IPv4Address(s) != nil || IPv6Address(s) != nil { self = .ip(s); return }
        if s.lowercased().hasPrefix("https://"), let u = URL(string: s), u.host != nil {
            self = .https(u); return
        }
        var h = s.lowercased()
        if h.hasPrefix("tls://") { h.removeFirst(6) }
        if h.hasSuffix(".") { h.removeLast() }
        let label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
        if h.range(of: "^(\(label)\\.)+[a-z]{2,63}$", options: .regularExpression) != nil {
            self = .tls(host: h); return
        }
        return nil
    }

    var isEncrypted: Bool { if case .ip = self { return false } else { return true } }

    var display: String {
        switch self {
        case .ip(let s): return s
        case .tls(let h): return h
        case .https(let u): return u.absoluteString
        }
    }
}

/// macOS only accepts encrypted DNS (hostname / https) through a configuration profile.
enum EncryptedDNS {
    static let profileID = "io.github.litebrowser.dns"

    /// Writes a .mobileconfig to ~/Downloads and opens it; the user approves it in System Settings.
    static func installProfile(_ entry: DNSEntry) -> String? {
        var dns: [String: Any] = [:]
        switch entry {
        case .tls(let host):
            dns["DNSProtocol"] = "TLS"
            dns["ServerName"] = host
        case .https(let url):
            dns["DNSProtocol"] = "HTTPS"
            dns["ServerURL"] = url.absoluteString
        case .ip:
            return "Plain IP addresses don't need a profile."
        }
        let name = entry.display
        let payload: [String: Any] = [
            "DNSSettings": dns,
            "PayloadDisplayName": "Encrypted DNS (\(name))",
            "PayloadIdentifier": profileID + ".settings",
            "PayloadType": "com.apple.dnsSettings.managed",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
            "ProhibitDisablement": false,
        ]
        let profile: [String: Any] = [
            "PayloadContent": [payload],
            "PayloadDisplayName": "LiteBrowser DNS – \(name)",
            "PayloadDescription": "Makes your Mac use the encrypted DNS server \(name). Created by LiteBrowser.",
            "PayloadIdentifier": profileID,
            "PayloadOrganization": "LiteBrowser",
            "PayloadType": "Configuration",
            "PayloadScope": "System",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
            "PayloadRemovalDisallowed": false,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let file = dir.appendingPathComponent("LiteBrowser-DNS.mobileconfig")
            try data.write(to: file, options: .atomic)
            NSWorkspace.shared.open(file)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let panes = ["x-apple.systempreferences:com.apple.Profiles-Settings.extension",
                             "x-apple.systempreferences:com.apple.preferences.configurationprofiles"]
                for p in panes { if let u = URL(string: p), NSWorkspace.shared.open(u) { break } }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum DNSInfo {
    /// The DNS servers macOS is actually using right now (from `scutil --dns`).
    static func current() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        p.arguments = ["--dns"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [String] = []
        var inFirst = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("resolver #") {
                if inFirst { break }
                inFirst = (t == "resolver #1")
                continue
            }
            if inFirst, t.hasPrefix("nameserver["), let colon = t.firstIndex(of: ":") {
                let v = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !out.contains(v) { out.append(v) }
            }
        }
        return out
    }
}

/// Sends one real DNS query (www.google.com, type A) and times the answer.
/// Plain servers use UDP port 53, hostnames use DNS-over-TLS (853), https:// uses DNS-over-HTTPS.
enum DNSTest {
    private static let query: Data = {
        var q = Data([0x4C, 0x42, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        for label in ["www", "google", "com"] {
            q.append(UInt8(label.utf8.count))
            q.append(contentsOf: Array(label.utf8))
        }
        q.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        return q
    }()

    private static func isGoodAnswer(_ b: [UInt8]) -> Bool {
        guard b.count > 12 else { return false }
        let answers = Int(b[6]) << 8 | Int(b[7])
        return b[0] == 0x4C && b[1] == 0x42 && (b[3] & 0x0F) == 0 && answers > 0
    }

    static func run(_ server: String, completion: @escaping (Bool, Int) -> Void) {
        guard let entry = DNSEntry(server) else { completion(false, 0); return }
        let queue = DispatchQueue(label: "litebrowser.dnstest")
        let start = Date()
        var finished = false
        var cleanup: () -> Void = {}
        func finish(_ ok: Bool) {                       // always runs on `queue`
            guard !finished else { return }
            finished = true
            cleanup()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async { completion(ok, ms) }
        }
        queue.asyncAfter(deadline: .now() + 5) { finish(false) }

        switch entry {
        case .ip(let ip):
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: 53, using: .udp)
            cleanup = { conn.cancel() }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: DNSTest.query, completion: .contentProcessed { _ in })
                    conn.receiveMessage { data, _, _, _ in
                        finish(data.map { DNSTest.isGoodAnswer([UInt8]($0)) } ?? false)
                    }
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: queue)

        case .tls(let host):
            let conn = NWConnection(host: NWEndpoint.Host(host), port: 853, using: .tls)
            cleanup = { conn.cancel() }
            let framed = Data([UInt8(DNSTest.query.count >> 8), UInt8(DNSTest.query.count & 0xFF)]) + DNSTest.query
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: framed, completion: .contentProcessed { _ in })
                    conn.receive(minimumIncompleteLength: 14, maximumLength: 65535) { data, _, _, _ in
                        guard let d = data, d.count > 14 else { finish(false); return }
                        finish(DNSTest.isGoodAnswer(Array([UInt8](d).dropFirst(2))))
                    }
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: queue)

        case .https(let url):
            var req = URLRequest(url: url, timeoutInterval: 5)
            req.httpMethod = "POST"
            req.httpBody = DNSTest.query
            req.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
            req.setValue("application/dns-message", forHTTPHeaderField: "Accept")
            let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200 && data.map { DNSTest.isGoodAnswer([UInt8]($0)) } == true
                queue.async { finish(ok) }
            }
            cleanup = { task.cancel() }
            task.resume()
        }
    }
}

// MARK: - History & search history (saved in ~/Library/Application Support/LiteBrowser)

struct HistoryItem: Codable { var id: String; var url: String; var title: String; var date: Date }
struct SearchItem: Codable { var id: String; var query: String; var date: Date }

final class HistoryStore {
    static let shared = HistoryStore()
    private(set) var items: [HistoryItem] = []      // newest first
    private(set) var searches: [SearchItem] = []    // newest first
    private let fileURL: URL
    private let io = DispatchQueue(label: "litebrowser.history")
    private struct Disk: Codable { var items: [HistoryItem]; var searches: [SearchItem] }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiteBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL), let disk = try? JSONDecoder().decode(Disk.self, from: data) {
            items = disk.items
            searches = disk.searches
        }
    }

    static func googleQuery(_ url: URL) -> String? {
        guard let host = url.host, host.contains("google."), url.path == "/search",
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value,
              !q.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return q
    }

    func recordVisit(url: URL, title: String) {
        let s = url.absoluteString
        if let first = items.first, first.url == s {
            items[0].title = title
            items[0].date = Date()
        } else {
            items.insert(HistoryItem(id: UUID().uuidString, url: s, title: title, date: Date()), at: 0)
            if items.count > 5000 { items.removeLast(items.count - 5000) }
        }
        if let q = Self.googleQuery(url), searches.first?.query != q {
            searches.insert(SearchItem(id: UUID().uuidString, query: q, date: Date()), at: 0)
            if searches.count > 2000 { searches.removeLast(searches.count - 2000) }
        }
        save()
    }

    /// Most-visited sites, weighted so recent visits count more. Used by the home page.
    func topSites(limit: Int) -> [[String: String]] {
        let hidden = Prefs.hiddenTopSites
        let now = Date()
        var score: [String: Double] = [:]
        var info: [String: (url: String, title: String)] = [:]
        for item in items.prefix(4000) {
            guard let u = URL(string: item.url), let rawHost = u.host?.lowercased(),
                  let scheme = u.scheme, ["http", "https"].contains(scheme) else { continue }
            var host = rawHost
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if hidden.contains(host) || host == "accounts.google.com" { continue }
            let ageDays = now.timeIntervalSince(item.date) / 86_400
            score[host, default: 0] += 1.0 / (1.0 + ageDays / 7.0)
            if info[host] == nil { info[host] = ("\(scheme)://\(rawHost)/", item.title) }
        }
        return score.sorted { $0.value > $1.value }.prefix(limit).compactMap { entry in
            guard let i = info[entry.key] else { return nil }
            return ["host": entry.key, "url": i.url, "title": i.title]
        }
    }

    func deleteHistory(ids: Set<String>) { items.removeAll { ids.contains($0.id) }; save() }
    func deleteSearches(ids: Set<String>) { searches.removeAll { ids.contains($0.id) }; save() }
    func clearHistory() { items.removeAll(); save() }

    /// Also removes Google result pages from history, since their addresses contain the search.
    func clearSearches() {
        searches.removeAll()
        items.removeAll { URL(string: $0.url).flatMap(Self.googleQuery) != nil }
        save()
    }

    private func save() {
        let disk = Disk(items: items, searches: searches)
        let url = fileURL
        io.async {
            if let data = try? JSONEncoder().encode(disk) { try? data.write(to: url, options: .atomic) }
        }
    }
}

// MARK: - Which sites stay signed in

enum SiteData {
    /// Ticking one of these keeps the whole group, because their sign-ins depend on each other.
    static let families: [[String]] = [
        ["google.com", "youtube.com", "gmail.com", "gstatic.com", "googleusercontent.com",
         "googleapis.com", "google.com.pk", "ggpht.com", "googlevideo.com", "withgoogle.com"],
        ["microsoft.com", "live.com", "microsoftonline.com", "office.com", "outlook.com",
         "bing.com", "msn.com", "sharepoint.com", "office365.com", "skype.com"],
        ["apple.com", "icloud.com"],
        ["facebook.com", "fbcdn.net", "messenger.com"],
        ["instagram.com", "cdninstagram.com"],
        ["x.com", "twitter.com", "twimg.com"],
        ["github.com", "githubusercontent.com"],
    ]

    static func isKept(_ domain: String, _ kept: Set<String>) -> Bool {
        if kept.contains(domain) { return true }
        if kept.contains("google.com") && domain.hasPrefix("google.") { return true }   // google.co.uk etc.
        return false
    }

    /// Applies the user's ticks: newly ticked sites bring their family along; unticks remove just that site.
    static func updatedKeepList(checked: [String], present: [String]) -> Set<String> {
        let old = Prefs.keptSites
        var result = Set(checked).union(old.subtracting(present))
        for added in Set(checked).subtracting(old) {
            if let family = families.first(where: { $0.contains(added) }) { result.formUnion(family) }
        }
        return result
    }
}

// MARK: - Settings window (History, Searches, Clear Data, DNS)

final class SettingsWindowController: NSWindowController, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private let webView: WKWebView
    private var loaded = false
    private var pendingTab: String?

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "LiteBrowser Settings"
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary, .fullScreenDisallowsTiling]
        window.minSize = NSSize(width: 640, height: 420)
        window.contentView = webView
        window.center()
        super.init(window: window)
        window.delegate = self
        config.userContentController.add(WeakScriptHandler(self), name: "settings")
        webView.navigationDelegate = self
        if let url = Bundle.main.url(forResource: "settings", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<p style='font:15px system-ui;padding:30px'>settings.html is missing from the app bundle. Rebuild with <code>make</code>.</p>", baseURL: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(tab: String) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if loaded {
            js("showTab('\(tab)')")
            pushState()
        } else {
            pendingTab = tab
        }
    }

    private func js(_ code: String) { webView.evaluateJavaScript(code, completionHandler: nil) }

    private func jsString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
    }

    func toast(_ msg: String, error: Bool = false) { js("toast(\(jsString(msg)), \(error))") }

    func pushState() {
        guard loaded else { return }
        let ms: (Date) -> Double = { $0.timeIntervalSince1970 * 1000 }
        let history: [[String: Any]] = HistoryStore.shared.items.prefix(3000).map {
            ["id": $0.id, "url": $0.url, "title": $0.title, "date": ms($0.date)]
        }
        let searches: [[String: Any]] = HistoryStore.shared.searches.prefix(3000).map {
            ["id": $0.id, "query": $0.query, "date": ms($0.date)]
        }
        let presets: [[String: Any]] = DNSPresets.list.map { ["name": $0.name, "note": $0.note, "servers": $0.servers] }
        let current = DNSInfo.current()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            guard let self = self else { return }
            let kept = Prefs.keptSites
            let domains = Set(records.map { $0.displayName }).sorted()
            let sites: [[String: Any]] = domains.map { ["domain": $0, "kept": SiteData.isKept($0, kept)] }
            let state: [String: Any] = [
                "history": history, "searches": searches, "sites": sites,
                "dns": ["servers": Prefs.dnsServers, "presets": presets, "current": current],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: state),
               let json = String(data: data, encoding: .utf8) {
                self.js("render(\(json))")
            }
        }
    }

    private func validServers(_ body: [String: Any]) -> [String]? {
        let result = DNSPresets.validate(body["servers"] as? [String] ?? [])
        if let err = result.error { toast(err, error: true); return nil }
        return result.entries?.map { $0.display }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, webView.url?.isFileURL == true,
              let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        let app = AppDelegate.shared
        switch cmd {
        case "refresh":
            pushState()
        case "close":
            closeAndReturn()
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let t = pendingTab { js("showTab('\(t)')"); pendingTab = nil }
        pushState()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true || action.request.url?.scheme == "about" ? .allow : .cancel)
    }

    func windowDidBecomeKey(_ notification: Notification) { pushState() }

    func refresh() { pushState() }

    /// ⌘W ("Close Tab") closes Settings when it's in front.
    @objc func closeCurrentTab(_ sender: Any?) { closeAndReturn() }

    /// "← Back to browsing" / Esc: close Settings (leaving full screen first) and bring the browser forward.
    func closeAndReturn() {
        guard let w = window else { return }
        if w.styleMask.contains(.fullScreen) {
            w.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                w.close()
                AppDelegate.shared.focusBrowser()
            }
        } else {
            w.close()
            AppDelegate.shared.focusBrowser()
        }
    }
}

struct ClearOptions { var history: Bool; var searches: Bool; var cookies: Bool; var cache: Bool }

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }
    private var controllers: [BrowserWindowController] = []
    private var settings: SettingsWindowController?
    private var recentlyClosed: [URL] = []
    private var isClearingData = false
    private let recentHistoryTag = 7700

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        removeOldExtensionData()
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        DispatchQueue.main.async {
            // If the app was launched by opening a link, application(_:open:) already made a window.
            guard self.controllers.isEmpty else { return }
            self.openWindow(url: args.first.map(resolveInput) ?? Config.home)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { openInBrowser($0) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(url: Config.home) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Windows & tabs

    /// The frontmost browser window (never the Settings window).
    private var browserWindow: NSWindow? {
        if let w = NSApp.keyWindow, w.windowController is BrowserWindowController { return w }
        return NSApp.orderedWindows.first { $0.isVisible && $0.windowController is BrowserWindowController }
    }

    var browserController: BrowserWindowController? { browserWindow?.windowController as? BrowserWindowController }

    /// All browser windows, frontmost first.
    var browserControllers: [BrowserWindowController] {
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
        return ordered + controllers.filter { c in !ordered.contains { $0 === c } }
    }

    private func makeController(url: URL?, configuration: WKWebViewConfiguration? = nil) -> BrowserWindowController {
        let c = BrowserWindowController(url: url, configuration: configuration)
        c.onClose = { [weak self] closed in
            DispatchQueue.main.async { self?.controllers.removeAll { $0 === closed } }
        }
        controllers.append(c)
        return c
    }

    /// Remembers closed tabs for ⇧⌘T.
    func noteClosedTab(_ url: URL?) {
        guard let u = url, !isClearingData else { return }
        recentlyClosed.append(u)
        if recentlyClosed.count > 25 { recentlyClosed.removeFirst() }
    }

    @discardableResult
    func openWindow(url: URL?, configuration: WKWebViewConfiguration? = nil) -> BrowserWindowController {
        let c = makeController(url: url, configuration: configuration)
        if let w = c.window {
            if let key = browserWindow {
                w.cascadeTopLeft(from: NSPoint(x: key.frame.minX + 24, y: key.frame.maxY - 24))
            } else {
                w.center()
            }
            c.showWindow(nil)
        }
        return c
    }

    /// Opens a tab in the frontmost browser window (or a new window if there is none).
    @discardableResult
    func openTab(url: URL?, configuration: WKWebViewConfiguration? = nil,
                 relativeTo parent: NSWindow?, activate: Bool) -> BrowserTab {
        let host = (parent?.windowController as? BrowserWindowController) ?? browserController
        guard let c = host else {
            let w = openWindow(url: url, configuration: configuration)
            return w.activeTab ?? w.tabs[0]
        }
        let tab = c.addTab(url: url, configuration: configuration, activate: activate)
        if activate { c.window?.makeKeyAndOrderFront(nil) }
        return tab
    }

    /// Extensions were removed from LiteBrowser; delete anything an earlier version installed.
    private func removeOldExtensionData() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "extensionsRemoved") else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiteBrowser/Extensions")
        try? FileManager.default.removeItem(at: dir)
        ["extensionsEnabled", "pinnedExtensions"].forEach { d.removeObject(forKey: $0) }
        d.set(true, forKey: "extensionsRemoved")
    }

    func focusBrowser() {
        if let w = browserWindow { w.makeKeyAndOrderFront(nil) } else { openWindow(url: Config.home) }
    }

    func openInBrowser(_ url: URL) {
        openTab(url: url, relativeTo: nil, activate: true)
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(url: Config.home).focusAddressBar(nil)
    }

    @objc func newTab(_ sender: Any?) {
        if let c = browserController {
            c.addTab(url: Config.home, activate: true)
            c.window?.makeKeyAndOrderFront(nil)
        } else {
            openWindow(url: Config.home)
        }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let url = recentlyClosed.popLast() else { NSSound.beep(); return }
        openInBrowser(url)
    }

    /// ⌘1…⌘8 jump to that tab, ⌘9 jumps to the last tab.
    @objc func selectTabNumber(_ sender: NSMenuItem) {
        browserController?.selectTab(number: sender.tag)
    }

    // MARK: Settings

    func openSettingsTab(_ tab: String) { openSettings(tab) }

    private func openSettings(_ tab: String) {
        if settings == nil { settings = SettingsWindowController() }
        settings?.show(tab: tab)
    }

    @objc func showSettings(_ sender: Any?) { openSettings("history") }
    @objc func showHistory(_ sender: Any?) { openSettings("history") }
    @objc func showSearches(_ sender: Any?) { openSettings("searches") }
    @objc func clearBrowsingData(_ sender: Any?) { openSettings("privacy") }
    @objc func showDNSSettings(_ sender: Any?) { openSettings("dns") }

    @objc func openHistoryItem(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { openInBrowser(u) }
    }

    // MARK: Clearing data

    func clear(_ o: ClearOptions, done: @escaping () -> Void) {
        if o.history { HistoryStore.shared.clearHistory() }
        if o.searches { HistoryStore.shared.clearSearches() }
        let store = WKWebsiteDataStore.default()
        let group = DispatchGroup()
        if o.cache {
            group.enter()
            let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                           WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]
            store.removeData(ofTypes: cacheTypes, modifiedSince: .distantPast) { group.leave() }
        }
        if o.cookies {
            group.enter()
            let kept = Prefs.keptSites
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let doomed = records.filter { !SiteData.isKept($0.displayName, kept) }
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: doomed) { group.leave() }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            if o.history {
                // Back/forward lists live inside each tab, so start fresh tabs.
                self.isClearingData = true
                let open = self.controllers
                open.forEach { $0.window?.close() }
                self.recentlyClosed.removeAll()
                self.isClearingData = false
                if !open.isEmpty { self.openWindow(url: Config.home) }
            } else if o.cookies {
                self.controllers.forEach { $0.tabs.forEach { $0.webView.reload() } }
            }
            done()
        }
    }

    // MARK: DNS

    enum DNSApplyResult { case applied, profileOpened, none }

    /// servers == nil → reset to automatic. Plain IPs are set with networksetup (admin password);
    /// a hostname or https:// server is installed as an encrypted-DNS profile the user approves.
    func applyDNS(_ servers: [String]?, done: @escaping (DNSApplyResult) -> Void) {
        if let servers = servers, servers.count == 1, let entry = DNSEntry(servers[0]), entry.isEncrypted {
            if let err = EncryptedDNS.installProfile(entry) {
                let a = NSAlert()
                a.messageText = "Couldn't create the DNS profile"
                a.informativeText = err
                a.runModal()
                done(.none)
                return
            }
            let a = NSAlert()
            a.messageText = "One more step: approve the DNS profile"
            a.informativeText = """
            macOS needs your permission to use \(entry.display).

            1. In System Settings, open Privacy & Security › Profiles (on older macOS: General › Device Management).
            2. Double-click “LiteBrowser DNS – \(entry.display)”.
            3. Click Install and enter your password.

            To undo it later, use Network › Reset DNS to Automatic in LiteBrowser, or remove the profile there.
            """
            a.addButton(withTitle: "OK")
            a.runModal()
            done(.profileOpened)
            return
        }
        switch DNSFixer.apply(servers: servers) {
        case .ok:
            controllers.forEach { $0.tabs.forEach { $0.retryAfterNetworkChange() } }
            done(.applied)
        case .cancelled:
            done(.none)
        case .failed(let msg):
            let a = NSAlert()
            a.messageText = "Couldn't change DNS settings"
            a.informativeText = msg
            a.runModal()
            done(.none)
        }
    }

    @objc func fixDNS(_ sender: Any?) {
        let servers = Prefs.dnsServers
        let a = NSAlert()
        a.messageText = "Switch your Mac to these DNS servers?"
        a.informativeText = "\(servers.joined(separator: ", "))\n\nThis is applied to every network connection. It fixes most DNS_PROBE errors. You can change the servers in Settings › DNS.\n\nmacOS will ask for your permission."
        a.addButton(withTitle: "Fix DNS")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        applyDNS(servers) { _ in }
    }

    @objc func resetDNS(_ sender: Any?) { applyDNS(nil) { _ in } }

    // MARK: History menu (recent pages are filled in each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.filter { $0.tag == recentHistoryTag }.forEach { menu.removeItem($0) }
        guard let anchor = menu.items.firstIndex(where: { $0.tag == recentHistoryTag - 1 }) else { return }
        var index = anchor + 1
        var seen = Set<String>()
        for item in HistoryStore.shared.items where seen.count < 15 {
            guard !seen.contains(item.url), let url = URL(string: item.url) else { continue }
            seen.insert(item.url)
            var title = item.title.isEmpty ? (url.host ?? item.url) : item.title
            if title.count > 60 { title = String(title.prefix(57)) + "…" }
            let mi = NSMenuItem(title: title, action: #selector(openHistoryItem(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = url
            mi.toolTip = item.url
            mi.tag = recentHistoryTag
            menu.insertItem(mi, at: index)
            index += 1
        }
        if seen.isEmpty {
            let none = NSMenuItem(title: "No recent pages", action: nil, keyEquivalent: "")
            none.isEnabled = false
            none.tag = recentHistoryTag
            menu.insertItem(none, at: index)
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String,
                  _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        @discardableResult
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let top = NSMenuItem()
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            top.submenu = m
            main.addItem(top)
            return m
        }
        let B = BrowserWindowController.self
        menu("LiteBrowser", [
            item("About LiteBrowser", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ","),
            .separator(),
            item("Hide LiteBrowser", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit LiteBrowser", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("File", [
            item("New Tab", #selector(newTab(_:)), "t"),
            item("New Window", #selector(newWindow(_:)), "n"),
            item("Reopen Closed Tab", #selector(reopenClosedTab(_:)), "t", [.command, .shift]),
            item("Open Location…", #selector(B.focusAddressBar(_:)), "l"),
            .separator(),
            item("Close Tab", #selector(B.closeCurrentTab(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        menu("View", [
            item("Reload Page", #selector(B.reloadPage(_:)), "r"),
            item("Stop", #selector(B.stopLoading(_:)), "."),
            .separator(),
            item("Zoom In", #selector(B.zoomIn(_:)), "="),
            item("Zoom Out", #selector(B.zoomOut(_:)), "-"),
            item("Actual Size", #selector(B.actualSize(_:)), "0"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let anchor = NSMenuItem.separator()
        anchor.tag = recentHistoryTag - 1
        let historyMenu = menu("History", [
            item("Back", #selector(B.goBack(_:)), "["),
            item("Forward", #selector(B.goForward(_:)), "]"),
            item("Home", #selector(B.goHome(_:)), "h", [.command, .shift]),
            anchor,
            // recently visited pages are inserted here
            .separator(),
            item("Show All History", #selector(showHistory(_:)), "y"),
            item("Downloads", #selector(B.showDownloads(_:)), "l", [.command, .option]),
            item("Show Search History", #selector(showSearches(_:)), "y", [.command, .shift]),
            item("Clear Browsing Data…", #selector(clearBrowsingData(_:)), "\u{8}", [.command, .shift]),
        ])
        historyMenu.delegate = self
        menu("Network", [
            item("DNS Settings…", #selector(showDNSSettings(_:)), ""),
            item("Fix DNS (use my DNS servers)…", #selector(fixDNS(_:)), ""),
            item("Reset DNS to Automatic", #selector(resetDNS(_:)), ""),
        ])
        let windowMenu = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            NSMenuItem.separator(),
            item("Show Next Tab", #selector(B.selectNextTab(_:)), "\t", [.control]),
            item("Show Previous Tab", #selector(B.selectPreviousTab(_:)), "\t", [.control, .shift]),
            item("Next Tab", #selector(B.selectNextTab(_:)), "}", [.command]),
            item("Previous Tab", #selector(B.selectPreviousTab(_:)), "{", [.command]),
            NSMenuItem.separator(),
        ] + (1...9).map { n -> NSMenuItem in
            let i = item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(selectTabNumber(_:)), "\(n)")
            i.tag = n
            return i
        })
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu   // macOS adds tab switching items here automatically
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
