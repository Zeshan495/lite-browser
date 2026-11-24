// LiteBrowser — PIN lock. Two wrong PINs in a row erase all browsing data (see AppDelegate.factoryReset).

import Cocoa
import CommonCrypto

enum AppLock {
    private static let d = UserDefaults.standard
    static let maxFailures = 2

    static var isEnabled: Bool { d.string(forKey: "pinHash") != nil }

    /// Wrong attempts in a row. Saved to disk so quitting and reopening doesn't reset it.
    static var failures: Int {
        get { d.integer(forKey: "pinFailures") }
        set { d.set(newValue, forKey: "pinFailures"); d.synchronize() }
    }

    static var lockOnWake: Bool {
        get { d.object(forKey: "pinLockOnWake") as? Bool ?? true }
        set { d.set(newValue, forKey: "pinLockOnWake") }
    }

    static func isValidFormat(_ pin: String) -> Bool {
        (4...10).contains(pin.count) && pin.allSatisfy { ("0"..."9").contains($0) }
    }

    static func set(_ pin: String) {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        d.set(salt, forKey: "pinSalt")
        d.set(hash(pin, salt: salt), forKey: "pinHash")
        failures = 0
    }

    static func disable() {
        ["pinSalt", "pinHash", "pinFailures"].forEach { d.removeObject(forKey: $0) }
    }

    static func verify(_ pin: String) -> Bool {
        guard let stored = d.string(forKey: "pinHash"), let salt = d.string(forKey: "pinSalt") else { return false }
        let a = Array(hash(pin, salt: salt).utf8), b = Array(stored.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0          // constant-time compare
    }

    /// PBKDF2-SHA256, 150,000 rounds: slow to brute-force even if someone copies the settings file.
    private static func hash(_ pin: String, salt: String) -> String {
        let saltBytes = [UInt8](Data(base64Encoded: salt) ?? Data())
        var out = [UInt8](repeating: 0, count: 32)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pin, pin.utf8.count,
                                 saltBytes, saltBytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 150_000,
                                 &out, out.count)
        return Data(out).base64EncodedString()
    }
}

// MARK: - Lock screen

final class LockView: NSVisualEffectView, NSTextFieldDelegate {
    private let field = NSSecureTextField()
    private let message = NSTextField(labelWithString: "")
    var onUnlock: (() -> Void)?
    var onWipe: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 76).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 76).isActive = true
        let title = NSTextField(labelWithString: "LiteBrowser is locked")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let sub = NSTextField(labelWithString: "Enter your PIN to continue")
        sub.textColor = .secondaryLabelColor

        field.placeholderString = "PIN"
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 20, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        field.wantsLayer = true

        let button = NSButton(title: "Unlock", target: self, action: #selector(submit))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.controlSize = .large

        message.textColor = .systemRed
        message.alignment = .center
        message.maximumNumberOfLines = 3
        message.preferredMaxLayoutWidth = 320

        let stack = NSStackView(views: [icon, title, sub, field, button, message])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(18, after: sub)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func focus() { window?.makeFirstResponder(field) }

    /// Digits only, at most 10.
    func controlTextDidChange(_ obj: Notification) {
        let digits = String(field.stringValue.filter { ("0"..."9").contains($0) }.prefix(10))
        if digits != field.stringValue { field.stringValue = digits }
    }

    @objc private func submit() {
        let pin = field.stringValue
        guard !pin.isEmpty else { return }
        if AppLock.verify(pin) {
            AppLock.failures = 0
            field.stringValue = ""
            message.stringValue = ""
            onUnlock?()
            return
        }
        AppLock.failures += 1
        field.stringValue = ""
        if AppLock.failures >= AppLock.maxFailures {
            onWipe?()
            return
        }
        shake()                                    // no message: just a shake
    }

    private func shake() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -10, 10, -8, 8, -4, 4, 0]
        a.duration = 0.4
        field.layer?.add(a, forKey: "shake")
    }
}

final class LockWindowController: NSWindowController {
    let lockView = LockView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.contentView = lockView
        w.center()
        super.init(window: w)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        lockView.focus()
    }
}
