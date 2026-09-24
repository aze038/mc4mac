import Foundation
import CryptoKit

/// Takes out of diagnostic text everything that is the person's rather than FalconMail's:
/// addresses and the names beside them, subjects, folder names, file names, secrets, the home
/// folder's path and client IP addresses. What is left says what went wrong, not to whom.
/// The rules are listed in docs/DIAGNOSTICS.md; every one of them runs before an event is queued.
public struct DiagnosticsRedactor: Sendable {
    public let salt: Data
    public let homePath: String
    /// Host names and IP literals of the configured servers, which are kept.
    public var serverHosts: Set<String>
    /// Folder names from the person's accounts, taken out wherever they appear in free text.
    public var labels: [String] {
        didSet { labels = DiagnosticsRedactor.usableLabels(labels) }
    }

    public init(salt: Data, homePath: String = NSHomeDirectory(), serverHosts: Set<String> = [], labels: [String] = []) {
        self.salt = salt
        self.homePath = homePath
        self.serverHosts = Set(serverHosts.map { $0.lowercased() })
        self.labels = DiagnosticsRedactor.usableLabels(labels)
    }

    // MARK: References

    /// Eight hex characters of HMAC-SHA256 under this install's salt: the same value always
    /// gives the same reference here, and nothing outside this Mac can turn it back.
    public func ref(_ value: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.lowercased().utf8), using: SymmetricKey(data: salt))
        return mac.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public func addressRef(_ address: String) -> String {
        "<addr:\(ref(address))>"
    }

    /// A standard folder keeps its name; any other becomes a reference.
    public func label(_ name: String) -> String {
        DiagnosticsRedactor.isStandardMailbox(name) ? name : "<label:\(ref("label:" + name))>"
    }

    static let standardMailboxes: Set<String> = [
        "inbox", "sent", "sent mail", "sent items", "sent messages", "drafts", "trash", "bin", "deleted items",
        "deleted messages", "junk", "junk e-mail", "junk email", "spam", "archive", "archives", "all mail",
        "starred", "important",
    ]

    public static func isStandardMailbox(_ name: String) -> Bool {
        var bare = name.trimmingCharacters(in: .whitespaces)
        for prefix in ["[Gmail]/", "[Google Mail]/", "INBOX.", "INBOX/"] where bare.count > prefix.count
            && bare.lowercased().hasPrefix(prefix.lowercased()) {
            bare = String(bare.dropFirst(prefix.count))
        }
        return standardMailboxes.contains(bare.lowercased())
    }

    /// A name without a letter, such as a folder called 2024, would take dates and counts out
    /// of messages with it, so only names with a letter are looked for.
    private static func usableLabels(_ names: [String]) -> [String] {
        Array(Set(names.filter { $0.count >= 3 && $0.contains(where: \.isLetter) && !isStandardMailbox($0) }))
            .sorted { $0.count > $1.count }
    }

    // MARK: Redaction

    public func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var s = text
        if s.contains("{") { s = stripLiterals(s) }
        if s.contains(":") { s = stripURLs(s) }
        s = stripSecrets(s)
        if s.contains("/") { s = stripHome(s) }
        if s.contains("=?") { s = Rx.encodedWord.replace(in: s) { _, _ in "<text>" } }
        if s.contains(":") { s = stripHeaderLines(s) }
        s = stripIMAPArguments(s)
        if s.contains("@") { s = stripAddresses(s) }
        if s.contains("\"") || s.contains("“") { s = stripQuoted(s) }
        if !labels.isEmpty { s = stripLabels(s) }
        s = stripIPs(s)
        return s
    }

    /// Every string in the value, and any key that could hold an address or a path.
    public func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): return .string(redact(s))
        case .array(let a): return .array(a.map(redact))
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                let key = k.contains("@") || k.contains("/") ? redact(k) : k
                out[key] = redact(v)
            }
            return .object(out)
        default: return value
        }
    }

    // MARK: IMAP literals

    /// A literal's announced size says how much follows it; all of that goes, whatever it is.
    private func stripLiterals(_ text: String) -> String {
        let ns = text as NSString
        let out = NSMutableString()
        var cursor = 0
        while cursor < ns.length,
              let m = Rx.literal.firstMatch(in: text, range: NSRange(location: cursor, length: ns.length - cursor)) {
            out.append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            let size = Int(ns.substring(with: m.range(at: 1))) ?? 0
            out.append("{\(size)}<literal>")
            var end = min(ns.length, m.range.location + m.range.length + size)
            if end < ns.length { end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: max(end - 1, 0))) }
            cursor = max(end, m.range.location + m.range.length)
        }
        if cursor < ns.length { out.append(ns.substring(from: cursor)) }
        return out as String
    }

    // MARK: Secrets

    private func stripSecrets(_ text: String) -> String {
        var s = text
        s = Rx.authenticate.replace(in: s) { m, ns in "\(ns.substring(with: m.range(at: 1))) \(ns.substring(with: m.range(at: 2))) <redacted>" }
        s = Rx.login.replace(in: s) { m, ns in "\(ns.substring(with: m.range(at: 1)))LOGIN <redacted>" }
        s = Rx.xoauthUser.replace(in: s) { m, ns in
            let user = ns.substring(with: m.range(at: 1))
            let shown = Rx.address.firstMatch(in: user, range: NSRange(location: 0, length: (user as NSString).length)) != nil
                ? addressRef(user) : "<redacted>"
            return "user=\(shown)\u{01}auth=Bearer <token>"
        }
        s = Rx.bearer.replace(in: s) { m, ns in "\(ns.substring(with: m.range(at: 1))) <token>" }
        for rx in Rx.tokens { s = rx.replace(in: s) { _, _ in "<token>" } }
        s = Rx.clientSecret.replace(in: s) { _, _ in "<secret>" }
        s = Rx.jsonSecret.replace(in: s) { m, ns in "\(ns.substring(with: m.range(at: 1)))\"<redacted>\"" }
        s = Rx.keyValueSecret.replace(in: s) { m, ns in "\(ns.substring(with: m.range(at: 1)))=<redacted>" }
        s = Rx.authorizationHeader.replace(in: s) { m, ns in "\(ns.substring(with: m.range(at: 1))) <redacted>" }
        s = Rx.base64.replace(in: s) { m, ns in
            let blob = ns.substring(with: m.range)
            return DiagnosticsRedactor.looksEncoded(blob) ? "<base64>" : blob
        }
        return s
    }

    /// Long runs of mixed case and digits are secrets or encoded data; a Swift symbol or a
    /// path has long runs of plain lower-case words instead.
    static func looksEncoded(_ blob: String) -> Bool {
        var upper = false, lower = false, digit = false
        var run = 0, longestLowerRun = 0
        for c in blob.unicodeScalars {
            switch c {
            case "A"..."Z": upper = true; run = 0
            case "a"..."z": lower = true; run += 1; longestLowerRun = max(longestLowerRun, run)
            case "0"..."9": digit = true; run = 0
            default: run = 0
            }
        }
        return upper && lower && digit && longestLowerRun < 7
    }

    // MARK: URLs, paths

    private func stripURLs(_ text: String) -> String {
        var s = Rx.mailto.replace(in: text) { m, ns in "mailto:" + ns.substring(with: m.range(at: 1)) }
        s = Rx.url.replace(in: s) { m, ns in
            let scheme = ns.substring(with: m.range(at: 1))
            var rest = ns.substring(with: m.range(at: 2))
            if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = String(rest[..<cut]) }
            let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            if let at = rest[..<authorityEnd].lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
            return "\(scheme)://\(rest)"
        }
        return s
    }

    private func stripHome(_ text: String) -> String {
        var s = text
        let home = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        if home.count > 1, s.contains(home) {
            var out = ""
            var rest = s[...]
            while let r = rest.range(of: home) {
                out += rest[rest.startIndex..<r.lowerBound]
                let next = r.upperBound < rest.endIndex ? rest[r.upperBound] : nil
                let whole = next.map { !($0.isLetter || $0.isNumber || "._-".contains($0)) } ?? true
                out += whole ? "~" : String(rest[r])
                rest = rest[r.upperBound...]
            }
            s = out + rest
        }
        return Rx.otherHome.replace(in: s) { _, _ in "~" }
    }

    // MARK: Headers and IMAP commands

    private func stripHeaderLines(_ text: String) -> String {
        Rx.subjectLine.replace(in: text) { m, ns in "\(ns.substring(with: m.range(at: 1))) <text>" }
    }

    private func stripIMAPArguments(_ text: String) -> String {
        guard Rx.imapAny.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil else { return text }
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let range = NSRange(location: 0, length: (line as NSString).length)
            if Rx.imapContent.firstMatch(in: line, range: range) != nil {
                var l = Rx.quoted.replace(in: line) { _, _ in "\"…\"" }
                l = Rx.searchCriterion.replace(in: l) { m, ns in "\(ns.substring(with: m.range(at: 1))) …" }
                l = Rx.searchHeader.replace(in: l) { m, ns in "\(ns.substring(with: m.range(at: 1))) …" }
                return stripGmailLabels(l)
            }
            if Rx.imapMailbox.firstMatch(in: line, range: range) != nil {
                var l = Rx.quoted.replace(in: line) { m, ns in
                    let name = ns.substring(with: m.range(at: 1))
                    return name.count <= 1 ? "\"\(name)\"" : "\"\(labelOnce(name))\""
                }
                l = Rx.mailboxAtom.replace(in: l) { m, ns in "\(ns.substring(with: m.range(at: 1)))\(labelOnce(ns.substring(with: m.range(at: 2))))" }
                l = Rx.moveTarget.replace(in: l) { m, ns in "\(ns.substring(with: m.range(at: 1)))\(labelOnce(ns.substring(with: m.range(at: 2))))" }
                return stripGmailLabels(l)
            }
            return stripGmailLabels(line)
        }
        return lines.joined(separator: "\n")
    }

    /// A name already made a reference stays as it is, so redacting twice changes nothing.
    private func labelOnce(_ name: String) -> String {
        Rx.isPlaceholder(name) ? name : label(name)
    }

    private func stripGmailLabels(_ line: String) -> String {
        Rx.gmailLabels.replace(in: line) { m, ns in
            let atoms = ns.substring(with: m.range(at: 2)).split(separator: " ").map { atom -> String in
                atom.hasPrefix("\\") || atom.hasPrefix("\"") ? String(atom) : labelOnce(String(atom))
            }
            return ns.substring(with: m.range(at: 1)) + atoms.joined(separator: " ") + ")"
        }
    }

    // MARK: Addresses and the names beside them

    private static let refOpen = "\u{E000}", refClose = "\u{E001}"

    private func stripAddresses(_ text: String) -> String {
        var s = Rx.bracketedAddress.replace(in: text) { m, ns in
            DiagnosticsRedactor.refOpen + ref(ns.substring(with: m.range(at: 1))) + DiagnosticsRedactor.refClose
        }
        if s.contains(DiagnosticsRedactor.refOpen) { s = removeDisplayNames(s) }
        s = Rx.address.replace(in: s) { m, ns in addressRef(ns.substring(with: m.range)) }
        return s.replacingOccurrences(of: DiagnosticsRedactor.refOpen, with: "<addr:")
            .replacingOccurrences(of: DiagnosticsRedactor.refClose, with: ">")
    }

    /// The name written before `<address>`. A quoted one always goes. An unquoted one goes
    /// whole where a list or header puts it, after a separator, or when every word of it is
    /// capitalised; otherwise only its trailing capitalised words do, so "Could not reach
    /// Ana Lima <…>" keeps "Could not reach".
    private func removeDisplayNames(_ text: String) -> String {
        var s = text
        var searchEnd = s.endIndex
        let separators: Set<Character> = [",", ";", ":", "(", "[", "\"", "\n", "\r", "\t", "=", ">", Character(DiagnosticsRedactor.refClose)]
        while let hit = s.range(of: DiagnosticsRedactor.refOpen, options: .backwards, range: s.startIndex..<searchEnd) {
            searchEnd = hit.lowerBound
            var start = hit.lowerBound
            while start > s.startIndex, s[s.index(before: start)] == " " { start = s.index(before: start) }
            let before = s[s.startIndex..<start]
            if before.hasSuffix("\""), let open = quotedStart(in: before) {
                s.replaceSubrange(open..<hit.lowerBound, with: "")
                searchEnd = open
                continue
            }
            let separator = before.lastIndex(where: { separators.contains($0) })
            let segmentStart = separator.map { before.index(after: $0) } ?? before.startIndex
            let words = before[segmentStart...].split(separator: " ")
            guard !words.isEmpty else { continue }
            if words.count <= 4, separator != nil || words.allSatisfy(DiagnosticsRedactor.isNameWord) {
                let spaced = separator.map { s[$0] != "\n" && s[$0] != "\r" } ?? false
                s.replaceSubrange(segmentStart..<hit.lowerBound, with: spaced ? " " : "")
                searchEnd = segmentStart
                continue
            }
            var cut = start
            for word in words.reversed().prefix(4) {
                guard DiagnosticsRedactor.isNameWord(word) else { break }
                cut = word.startIndex
            }
            if cut < start {
                s.replaceSubrange(cut..<hit.lowerBound, with: "")
                searchEnd = cut
            }
        }
        return s
    }

    private static func isNameWord(_ word: Substring) -> Bool {
        guard let first = word.first else { return false }
        return first.isUppercase || (first.isLetter && !first.isCased)
    }

    private func quotedStart(in text: Substring) -> String.Index? {
        var i = text.index(before: text.endIndex)
        while i > text.startIndex {
            i = text.index(before: i)
            if text[i] == "\"", i == text.startIndex || text[text.index(before: i)] != "\\" { return i }
        }
        return nil
    }

    // MARK: Quoted text, folder names, IP addresses

    /// Quoted text in a message is nearly always the person's: a name, a subject, a file. What
    /// is kept is only what reads like a code, such as `"invalid_grant"`.
    private func stripQuoted(_ text: String) -> String {
        var s = Rx.quoted.replace(in: text) { m, ns in
            let inner = ns.substring(with: m.range(at: 1))
            return DiagnosticsRedactor.keepsQuoted(inner) ? ns.substring(with: m.range) : "\"…\""
        }
        s = Rx.curlyQuoted.replace(in: s) { m, ns in
            let inner = ns.substring(with: m.range(at: 1))
            return Rx.isPlaceholder(inner) ? ns.substring(with: m.range) : "“…”"
        }
        return s
    }

    static func keepsQuoted(_ inner: String) -> Bool {
        if inner.isEmpty || inner == "…" || Rx.isPlaceholder(inner) || isStandardMailbox(inner) { return true }
        return inner.count <= 40 && inner.unicodeScalars.allSatisfy { Rx.codeCharacters.contains($0) }
    }

    private func stripLabels(_ text: String) -> String {
        var s = text
        for name in labels where s.contains(name) {
            var out = ""
            var rest = s[...]
            while let r = rest.range(of: name) {
                let before = r.lowerBound > rest.startIndex ? rest[rest.index(before: r.lowerBound)] : nil
                let after = r.upperBound < rest.endIndex ? rest[r.upperBound] : nil
                let bounded = !(before?.isLetter ?? false) && !(before?.isNumber ?? false)
                    && !(after?.isLetter ?? false) && !(after?.isNumber ?? false)
                out += rest[rest.startIndex..<r.lowerBound]
                out += bounded ? label(name) : String(rest[r])
                rest = rest[r.upperBound...]
            }
            s = out + rest
        }
        return s
    }

    private func stripIPs(_ text: String) -> String {
        var s = text
        if s.contains(".") {
            s = Rx.ipv4.replace(in: s) { m, ns in
                let ip = ns.substring(with: m.range)
                return serverHosts.contains(ip) ? ip : "<ip>"
            }
        }
        if s.contains(":") {
            s = Rx.ipv6Candidate.replace(in: s) { m, ns in
                let candidate = ns.substring(with: m.range)
                guard DiagnosticsRedactor.isIPv6(candidate), !serverHosts.contains(candidate.lowercased()) else { return candidate }
                return "<ip>"
            }
        }
        return s
    }

    static func isIPv6(_ s: String) -> Bool {
        let colons = s.filter { $0 == ":" }.count
        guard colons >= 2, s.contains("::") || colons == 7 else { return false }
        let groups = s.split(separator: ":", omittingEmptySubsequences: true)
        return !groups.isEmpty && groups.allSatisfy { $0.count <= 4 && $0.allSatisfy(\.isHexDigit) }
    }
}

// MARK: - Patterns

private enum Rx {
    static let literal = rx(#"\{(\d{1,9})\+?\}(?:\r?\n)?"#)
    static let authenticate = rx(#"\b(AUTHENTICATE|AUTH)\s+(XOAUTH2|XOAUTH|OAUTHBEARER|PLAIN|LOGIN|CRAM-MD5|NTLM|GSSAPI)\s+(?!<redacted>)\S+"#, [.caseInsensitive])
    static let login = rx(#"(^|\s)LOGIN\s+(?!<redacted>)(?:"(?:[^"\\]|\\.)*"|\S+)\s+(?:"(?:[^"\\]|\\.)*"|\S+)"#, [.anchorsMatchLines])
    static let xoauthUser = rx("user=([^\u{01}\\s]*)\u{01}auth=[^\u{01}]*")
    static let bearer = rx(#"\b(Bearer|Basic)\s+(?!<token>)[A-Za-z0-9._~+/=-]{6,}"#, [.caseInsensitive])
    static let tokens = [
        rx(#"\bya29\.[A-Za-z0-9._-]+"#),
        rx(#"(?<![A-Za-z0-9])1//[A-Za-z0-9._-]{10,}"#),
        rx(#"\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*"#),
        rx(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
        rx(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#),
    ]
    static let clientSecret = rx(#"GOCSPX-[A-Za-z0-9_-]+|\bAIza[0-9A-Za-z_-]{30,}"#)
    static let jsonSecret = rx(#"("(?:access_token|refresh_token|id_token|client_secret|password|passwd|pwd|secret|api_key|apikey|auth_token|token|authorization|key)"\s*:\s*)"(?:[^"\\]|\\.)*""#, [.caseInsensitive])
    static let keyValueSecret = rx(#"\b(access_token|refresh_token|id_token|client_secret|password|passwd|pwd|secret|api_key|apikey|auth_token)\s*[=:]\s*(?:"(?:[^"\\]|\\.)*"|'[^']*'|(?!<redacted>)[^\s&,;"']+)"#, [.caseInsensitive])
    static let authorizationHeader = rx(#"^(\s*(?:Proxy-)?Authorization\s*:).*$"#, [.caseInsensitive, .anchorsMatchLines])
    static let base64 = rx(#"(?<![A-Za-z0-9+/=_.~-])[A-Za-z0-9+/]{32,}={0,2}(?![A-Za-z0-9+/=_-])"#)

    static let mailto = rx(#"mailto:([^\s?"'<>]*)(?:\?[^\s"'<>]*)?"#, [.caseInsensitive])
    static let url = rx(#"\b([A-Za-z][A-Za-z0-9+.-]{1,15})://([^\s"'<>]+)"#)
    static let otherHome = rx(#"/Users/(?!Shared(?:/|\b))[^/\s"'<>:,;)\]}]+"#)

    static let encodedWord = rx(#"=\?[^?\s]{1,40}\?[BbQq]\?[^?\s]*\?="#)
    static let subjectLine = rx(#"^([ \t]*(?:Subject|Thread-Topic|Content-Description|Content-Disposition)[ \t]*:).*$"#, [.caseInsensitive, .anchorsMatchLines])

    static let imapAny = rx(#"\b(FETCH|SEARCH|APPEND|SELECT|EXAMINE|STATUS|CREATE|DELETE|RENAME|SUBSCRIBE|UNSUBSCRIBE|MOVE|COPY|LIST|LSUB|X-GM-LABELS)\b"#, [.caseInsensitive])
    static let imapContent = rx(#"\b(FETCH|SEARCH|APPEND)\b"#, [.caseInsensitive])
    static let imapMailbox = rx(#"\b(SELECT|EXAMINE|STATUS|CREATE|DELETE|RENAME|SUBSCRIBE|UNSUBSCRIBE|MOVE|COPY|LIST|LSUB)\b"#)
    static let searchCriterion = rx(#"\b(SUBJECT|BODY|TEXT|FROM|TO|CC|BCC|KEYWORD|UNKEYWORD|X-GM-RAW)\s+(?!"…")[^\s()]+"#)
    static let searchHeader = rx(#"\b(HEADER\s+[^\s()"]+)\s+(?!"…")[^\s()]+"#)
    static let mailboxAtom = rx(#"\b((?:SELECT|EXAMINE|STATUS|CREATE|DELETE|RENAME|SUBSCRIBE|UNSUBSCRIBE)\s+)([^\s"(){}]+)"#)
    static let moveTarget = rx(#"\b((?:MOVE|COPY)\s+[0-9:,*]+\s+)([^\s"(){}]+)"#)
    static let gmailLabels = rx(#"(X-GM-LABELS\s*\()([^)]*)\)"#, [.caseInsensitive])

    static let address = rx(#"(?<![\p{L}\p{N}\p{M}._%+\-!#$&'*?^`{|}~])(?:"[^"\r\n]{1,64}"|[\p{L}\p{N}\p{M}!#$%&'*+?^_`{|}~-]+(?:\.[\p{L}\p{N}\p{M}!#$%&'*+?^_`{|}~-]+)*)@(?:\[[0-9A-Fa-f:.]+\]|(?:[\p{L}\p{N}\p{M}](?:[\p{L}\p{N}\p{M}-]{0,61}[\p{L}\p{N}\p{M}])?\.)+[\p{L}\p{M}][\p{L}\p{N}\p{M}-]*[\p{L}\p{N}\p{M}])"#)
    static let bracketedAddress = rx(#"<\s*((?:"[^"\r\n]{1,64}"|[\p{L}\p{N}\p{M}!#$%&'*+?^_`{|}~.-]+)@[^\s<>]+?)\s*>"#)

    static let quoted = rx(#""((?:[^"\\\r\n]|\\.){0,500})""#)
    static let curlyQuoted = rx(#"“([^”\r\n]{0,500})”"#)
    static let ipv4 = rx(#"(?<!\d)(?<!\d\.)(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?!\d|\.\d)"#)
    static let ipv6Candidate = rx(#"(?<![0-9A-Za-z:.])[0-9A-Fa-f:]{2,39}(?![0-9A-Za-z:])"#)

    static let placeholder = rx(#"^<[a-z0-9]+(?::[0-9a-f]{8})?>$"#)
    static let codeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.:/-")

    static func isPlaceholder(_ s: String) -> Bool {
        placeholder.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constants, so a bad one is a programming error the tests catch at once.
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}

extension NSRegularExpression {
    /// Every match replaced by what `transform` returns for it, last match first so earlier
    /// ranges stay valid.
    func replace(in text: String, _ transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = text as NSString
        let matches = self.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for m in matches.reversed() { out.replaceCharacters(in: m.range, with: transform(m, ns)) }
        return out as String
    }
}
