import AppKit
import FalconCore

/// Decides whether a link inside a message may be opened.
///
/// Mail is the main way phishing arrives, so a link is only followed without asking when the
/// reader has said they trust the sender, or the sender's domain. Everything else asks first,
/// showing who sent the message and where the link actually goes.
enum LinkGuard {
    private static let domainsKey = "trustedLinkDomains"
    private static let contactsKey = "trustedLinkContacts"

    static var trustedDomains: Set<String> {
        get { Set(Preferences.string(domainsKey, default: "").split(separator: ",").map(String.init)) }
        set { Preferences.set(newValue.sorted().joined(separator: ","), domainsKey) }
    }

    static var trustedContacts: Set<String> {
        get { Set(Preferences.string(contactsKey, default: "").split(separator: ",").map(String.init)) }
        set { Preferences.set(newValue.sorted().joined(separator: ","), contactsKey) }
    }

    static func domain(of address: String) -> String {
        address.split(separator: "@").last.map { $0.lowercased() } ?? address.lowercased()
    }

    static func isTrusted(_ sender: EmailAddress?) -> Bool {
        guard let sender, !sender.address.isEmpty else { return false }
        let address = sender.address.lowercased()
        if trustedContacts.contains(address) { return true }
        return trustedDomains.contains(domain(of: address))
    }

    static func forget(contact: String) {
        trustedContacts.remove(contact.lowercased())
    }

    static func forget(domain: String) {
        trustedDomains.remove(domain.lowercased())
    }

    /// True when the text of a link does not match where it goes, the classic disguised link.
    /// Checked even for trusted senders, because a trusted account can be compromised.
    static func looksDisguised(text: String?, destination: URL) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
        guard text.contains("."), !text.contains(" ") else { return false }
        var claimed = text.lowercased()
        for prefix in ["https://", "http://", "www."] where claimed.hasPrefix(prefix) {
            claimed = String(claimed.dropFirst(prefix.count))
        }
        claimed = claimed.split(separator: "/").first.map(String.init) ?? claimed
        guard claimed.contains("."), let host = destination.host?.lowercased() else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return !(bare == claimed || bare.hasSuffix("." + claimed) || claimed.hasSuffix("." + bare))
    }

    @MainActor
    static func open(_ url: URL, from sender: EmailAddress?, linkText: String? = nil) {
        let disguised = looksDisguised(text: linkText, destination: url)
        if isTrusted(sender), !disguised {
            NSWorkspace.shared.open(url)
            return
        }
        guard let sender, !sender.address.isEmpty else {
            if confirmUnknown(url, disguised: disguised) { NSWorkspace.shared.open(url) }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Open a link from \(sender.address)?"
        let destination = url.host.map { "It goes to \($0)." } ?? "It goes to \(url.absoluteString)."
        alert.informativeText = disguised
            ? "\(destination) The link is written to look like somewhere else, which is how phishing usually works. Only continue if you were expecting this."
            : "\(destination) Open it only if you trust the sender."
        alert.alertStyle = disguised ? .critical : .warning
        alert.addButton(withTitle: "Open Once")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Always Trust \(domain(of: sender.address))")
        alert.addButton(withTitle: "Always Trust This Sender")
        alert.buttons[1].keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(url)
        case .alertThirdButtonReturn:
            trustedDomains.insert(domain(of: sender.address))
            NSWorkspace.shared.open(url)
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            trustedContacts.insert(sender.address.lowercased())
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }

    @MainActor
    private static func confirmUnknown(_ url: URL, disguised: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Open this link?"
        alert.informativeText = disguised
            ? "It goes to \(url.host ?? url.absoluteString), which is not where the link says it goes."
            : "It goes to \(url.host ?? url.absoluteString)."
        alert.alertStyle = disguised ? .critical : .warning
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum HTMLLinkify {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Turns bare web addresses and email addresses in plain text into real links,
    /// escaping everything else. Plain text mail had no clickable links at all before this.
    static func escapeAndLink(_ text: String) -> String {
        guard let detector else { return HTMLText.escape(text) }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var out = ""
        var cursor = text.startIndex
        for match in detector.matches(in: text, options: [], range: full) {
            guard let range = Range(match.range, in: text), let url = match.url else { continue }
            out += HTMLText.escape(String(text[cursor..<range.lowerBound]))
            let label = HTMLText.escape(String(text[range]))
            let href = HTMLText.escape(url.absoluteString)
            out += "<a href=\"\(href)\">\(label)</a>"
            cursor = range.upperBound
        }
        out += HTMLText.escape(String(text[cursor...]))
        return out
    }
}
