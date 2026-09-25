import AppKit

/// A signature as Legacy Outlook keeps one: a named piece of rich text that belongs to no
/// account. Accounts only choose which signature, if any, their new messages and their replies
/// start with (see SignatureBook).
public struct Signature: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// The words alone, pictures left out. A signature without formatting of its own, as one
    /// carried over from an account is, has only this.
    public var plain: String
    /// The formatted text as flat RTFD, which unlike RTF keeps pictures.
    public var rich: Data?
    /// The HTML the signature was made from, as its owner made it in Gmail or on a web page and
    /// it was imported or pasted, kept while its text is as that HTML reads, so that it is what
    /// is sent (see SignatureSource). Nil for a signature written or changed here, and absent
    /// from what an earlier build kept, which ignores it.
    public var html: String?

    public init(id: UUID = UUID(), name: String, plain: String = "", rich: Data? = nil, html: String? = nil) {
        self.id = id
        self.name = name
        self.plain = plain
        self.rich = rich
        self.html = html
    }

    /// Its HTML as what is sent for it, recognised in a message by its text.
    public var source: SignatureSource? {
        html.map { SignatureSource(html: $0, text: text) }
    }

    /// The signature as it is drawn. Plain text carries no formatting of its own, so it takes
    /// the formatting of wherever it is put.
    public var text: NSAttributedString {
        guard let rich, let text = try? NSAttributedString(data: rich, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                            documentAttributes: nil) else {
            return NSAttributedString(string: plain)
        }
        // RTFD may not keep how a table from the HTML is laid out, so it is laid out again.
        if let html { SignatureTables.honour(html, in: text) }
        return text
    }

    /// Text set throughout in `base`, the formatting a plain signature is shown in, is kept as
    /// plain text alone. It then opens messages exactly as a plain signature does, where RTF would
    /// turn the system font into Helvetica Neue for the whole message and drop carriage returns.
    public mutating func setText(_ text: NSAttributedString, plainIn base: [NSAttributedString.Key: Any] = [:]) {
        setText(text, html: nil, plainIn: base)
    }

    /// The same for text read from `html`, a signature's own HTML as it was imported or pasted,
    /// which is then what is sent for it; nil, as for any text written or changed here, drops
    /// the HTML the signature had, so what is sent is what the editor shows.
    public mutating func setText(_ text: NSAttributedString, html: String?, plainIn base: [NSAttributedString.Key: Any] = [:]) {
        self.html = html
        guard Signature.isSetOnly(in: base, text) else {
            plain = text.string.replacingOccurrences(of: Signature.pictureMark, with: "")
            rich = text.rtfd(from: NSRange(location: 0, length: text.length),
                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            return
        }
        // Words alone go into a message as plain text, which sends no HTML of its own.
        self.html = nil
        plain = text.string
        rich = nil
    }

    /// The text as the signature editor leaves it. The HTML the signature was imported or pasted
    /// with, or `pasted`, HTML just pasted into the editor, is kept, and still sent, only while
    /// the text still reads as that HTML did: the same words, pictures and emphasis. Any other
    /// change makes it a signature written here, sent as the editor shows it.
    public mutating func setEditedText(_ text: NSAttributedString, plainIn base: [NSAttributedString.Key: Any] = [:],
                                       pasted: SignatureSource? = nil) {
        let kept = [pasted, source].compactMap { $0 }.first { $0.matches(text) }
        setText(text, html: kept?.html, plainIn: base)
    }

    /// Whether every run of `text` says no more than `base` does. The plain paragraph style a
    /// text view gives what is typed is no formatting either; a picture or a link always is.
    private static func isSetOnly(in base: [NSAttributedString.Key: Any], _ text: NSAttributedString) -> Bool {
        var plain = true
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { own, _, stop in
            for (key, value) in own {
                if key == .paragraphStyle, let style = value as? NSParagraphStyle, style == NSParagraphStyle.default { continue }
                guard let expected = base[key] as? NSObject, expected.isEqual(value) else {
                    plain = false
                    stop.pointee = true
                    return
                }
            }
        }
        return plain
    }

    /// Nothing to put in a message: no words and no pictures, as with an account's signature of
    /// only spaces, which was never inserted either.
    public var isBlank: Bool {
        plain.trimmed.isEmpty && !text.string.contains(Signature.pictureMark)
    }

    /// Where a picture sits in the text.
    static let pictureMark = "\u{FFFC}"

    private static let htmlTag = try! NSRegularExpression(
        pattern: "<\\s*/?\\s*(br|div|p|img|table|tbody|tr|td|span|a|b|i|u|em|strong|font|html|body|hr|ul|ol|li|h[1-6]|center|small|sup|sub)\\b[^<>]*>",
        options: [.caseInsensitive])

    /// Whether plain text is HTML source, as an account's own signature pasted from a web page
    /// or another mail app can be: it holds at least one of the tags such a signature is made
    /// of. Words that merely use angle brackets, such as an address in <…>, are not HTML.
    public static func looksLikeHTML(_ text: String) -> Bool {
        htmlTag.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// A signature's HTML source as the formatted text it describes, with its pictures: each
    /// given as a data: URI, and each it would fetch from the web that `pictures` holds, by
    /// address; any other stays an empty box that remembers where it lives and is sent from
    /// there. Text it sets no font or colour for takes `attributes`, and the blank lines it
    /// ends with are left out, as the signature's own block adds them. Nil when it cannot be
    /// read.
    ///
    /// Each picture it shows by cid:, as a signature from Outlook shows its own, is the one of
    /// `parts` with that Content-ID, at the size the HTML gives it; one no part answers is left
    /// out.
    @MainActor
    public static func text(fromHTML html: String, parts: [MIMEAttachment] = [], pictures: [String: Data],
                            attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        guard let read = InlinePictures.text(fromHTML: ComposedBody.readingStyle(attributes) + html, parts: parts,
                                             attributes: attributes, remote: pictures) else { return nil }
        let text = NSMutableAttributedString(attributedString: ComposedBody.readable(read, attributes: attributes))
        SignatureTables.honour(html, in: text)
        let string = text.string as NSString
        var end = string.length
        while end > 0, let scalar = Unicode.Scalar(string.character(at: end - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            end -= 1
        }
        text.deleteCharacters(in: NSRange(location: end, length: string.length - end))
        return text
    }

    /// What pasting into the signature editor makes of HTML on `pasteboard`, as a signature
    /// copied from Gmail's settings or a web page comes: exactly what importing that HTML as a
    /// signature makes of it (see SignatureCandidate.signature), its tables as the HTML lays
    /// them out and its pictures at the size the HTML gives them, with the HTML itself to be sent
    /// for it. Nil when the pasteboard holds no HTML, or HTML that is not a signature to send as
    /// it is, such as Word's, which is then pasted as any other rich text is.
    @MainActor
    public static func pasted(from pasteboard: NSPasteboard,
                              attributes: [NSAttributedString.Key: Any]) -> (text: NSAttributedString, html: String)? {
        guard let data = pasteboard.data(forType: .html) else { return nil }
        return fromPastedHTML(String(decoding: data, as: UTF8.self), attributes: attributes)
    }

    /// The same for the HTML itself.
    @MainActor
    public static func fromPastedHTML(_ html: String, attributes: [NSAttributedString.Key: Any]) -> (text: NSAttributedString, html: String)? {
        guard let source = SignatureSource.sendable(html),
              let text = text(fromHTML: source, pictures: [:], attributes: attributes), text.length > 0 else { return nil }
        return (text, source)
    }

    /// What a message gets: the "-- " line other mail apps know a signature by, the signature,
    /// then a blank line. The line and the blank line carry no formatting, so they take the
    /// formatting of wherever the signature goes; for a plain signature the whole block reads
    /// exactly as an account's signature always has.
    public var block: NSAttributedString {
        let block = NSMutableAttributedString(string: "-- \n")
        block.append(text)
        block.append(NSAttributedString(string: "\n\n"))
        return block
    }
}

/// Which messages an account's default signature is for, as Outlook's Signatures pane splits
/// them.
public enum SignatureUse: String, Codable, Sendable, CaseIterable {
    case newMessages, replies
}

/// One account's choice of signatures. Nil is Outlook's None.
public struct SignatureDefaults: Codable, Hashable, Sendable {
    public var accountID: UUID
    public var newMessages: UUID?
    public var replies: UUID?

    public init(accountID: UUID, newMessages: UUID? = nil, replies: UUID? = nil) {
        self.accountID = accountID
        self.newMessages = newMessages
        self.replies = replies
    }
}

/// Every signature and every account's choice of them, kept as one file (see SignatureStore).
public struct SignatureBook: Codable, Hashable, Sendable {
    /// Raised whenever what the file means changes, so a build can tell a file written by a
    /// newer one and leave it alone.
    public static let currentVersion = 1

    public var version: Int
    public var signatures: [Signature]
    public var defaults: [SignatureDefaults]
    /// Each account's own signature, from before signatures had names, as it was carried over.
    /// The same text is carried over once, so a signature deleted here never comes back, while
    /// an account added since, or a signature an older build has set since, is still picked up.
    public var adopted: [Adoption]

    public struct Adoption: Codable, Hashable, Sendable {
        public var accountID: UUID
        /// The account's own signature when it was carried over.
        public var text: String
        /// The signature it became, nil for a blank one.
        public var signatureID: UUID?

        public init(accountID: UUID, text: String, signatureID: UUID?) {
            self.accountID = accountID
            self.text = text
            self.signatureID = signatureID
        }
    }

    public init(signatures: [Signature] = [], defaults: [SignatureDefaults] = [], adopted: [Adoption] = []) {
        version = SignatureBook.currentVersion
        self.signatures = signatures
        self.defaults = defaults
        self.adopted = adopted
    }

    /// By name, as the Signatures pane and the Signature menu list them, "Untitled 2" before
    /// "Untitled 10".
    public var sorted: [Signature] {
        signatures.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    public func signature(_ id: UUID?) -> Signature? {
        guard let id else { return nil }
        return signatures.first { $0.id == id }
    }

    /// The account's choice, or nil for None.
    public func defaultID(for accountID: UUID, _ use: SignatureUse) -> UUID? {
        signature(for: accountID, use)?.id
    }

    /// The signature a message from this account starts with: a new message's for new
    /// messages, a reply's or forward's for those.
    public func signature(for accountID: UUID, _ use: SignatureUse) -> Signature? {
        guard let entry = defaults.first(where: { $0.accountID == accountID }) else { return nil }
        return signature(use == .newMessages ? entry.newMessages : entry.replies)
    }

    public mutating func setDefault(_ id: UUID?, for accountID: UUID, _ use: SignatureUse) {
        let index: Int
        if let found = defaults.firstIndex(where: { $0.accountID == accountID }) {
            index = found
        } else {
            defaults.append(SignatureDefaults(accountID: accountID))
            index = defaults.count - 1
        }
        switch use {
        case .newMessages: defaults[index].newMessages = id
        case .replies: defaults[index].replies = id
        }
    }

    /// A new signature called Untitled, or Untitled 2 and on when that is taken. Outlook starts
    /// one with the writer's name; as plain text it takes the formatting of the message it goes
    /// into, as the composer's own text does.
    @discardableResult
    public mutating func add(startingWith text: String = "") -> Signature {
        let signature = Signature(name: uniqueName("Untitled"), plain: text)
        signatures.append(signature)
        return signature
    }

    /// Accounts that started messages with the signature start them with none.
    public mutating func remove(_ id: UUID) {
        signatures.removeAll { $0.id == id }
        for i in defaults.indices {
            if defaults[i].newMessages == id { defaults[i].newMessages = nil }
            if defaults[i].replies == id { defaults[i].replies = nil }
        }
    }

    /// A name left empty is not taken, so no signature is ever nameless: it keeps its last name
    /// while the field is cleared to type a new one.
    public mutating func rename(_ id: UUID, to name: String) {
        let name = name.trimmed
        guard !name.isEmpty, let i = signatures.firstIndex(where: { $0.id == id }) else { return }
        signatures[i].name = name
    }

    public mutating func setText(_ text: NSAttributedString, of id: UUID, plainIn base: [NSAttributedString.Key: Any] = [:]) {
        guard let i = signatures.firstIndex(where: { $0.id == id }) else { return }
        signatures[i].setText(text, plainIn: base)
    }

    /// The signature editor's text for a signature, which keeps the HTML it was imported or
    /// pasted with while it still reads as that HTML did (see Signature.setEditedText).
    public mutating func setEditedText(_ text: NSAttributedString, of id: UUID, plainIn base: [NSAttributedString.Key: Any] = [:],
                                       pasted: SignatureSource? = nil) {
        guard let i = signatures.firstIndex(where: { $0.id == id }) else { return }
        signatures[i].setEditedText(text, plainIn: base, pasted: pasted)
    }

    /// Carries over the one plain signature each account kept before signatures had names. An
    /// account's signature was put into every new message, reply and forward from it, so the
    /// signature made from it becomes both its defaults; an account without one gets None and
    /// no signature. Returns whether anything changed.
    ///
    /// An older build still sets an account's own signature, and then puts that into its
    /// messages, so a changed one is carried over again as a signature of its own. It takes the
    /// place of the one carried over before only where that is still the default, or there is
    /// none; a default chosen here since is left as it is.
    @discardableResult
    public mutating func adopt(_ accounts: [AccountInfo]) -> Bool {
        var changed = false
        for account in accounts {
            let earlier = adopted.firstIndex { $0.accountID == account.id }
            if let earlier, adopted[earlier].text.trimmed == account.signature.trimmed { continue }
            changed = true
            let made = carryOver(account)
            let adoption = Adoption(accountID: account.id, text: account.signature, signatureID: made?.id)
            guard let earlier else {
                if let made {
                    setDefault(made.id, for: account.id, .newMessages)
                    setDefault(made.id, for: account.id, .replies)
                }
                adopted.append(adoption)
                continue
            }
            for use in SignatureUse.allCases {
                let current = defaultID(for: account.id, use)
                if current == nil || current == adopted[earlier].signatureID, current != made?.id {
                    setDefault(made?.id, for: account.id, use)
                }
            }
            adopted[earlier] = adoption
        }
        return changed
    }

    /// The signatures carried over from an account's own signature that are HTML source, as
    /// one pasted into an older build's account settings from a web page is, and are still
    /// exactly as they were carried over: the owner has not changed them since, and they have
    /// not been read as HTML yet. Each is given with its source.
    public var carriedOverHTML: [(id: UUID, html: String)] {
        adopted.compactMap { adoption -> (id: UUID, html: String)? in
            guard let id = adoption.signatureID, let signature = signature(id), signature.rich == nil,
                  signature.plain == adoption.text, Signature.looksLikeHTML(signature.plain) else { return nil }
            return (id, signature.plain)
        }
    }

    /// Replaces a carried-over signature's HTML source with `text`, the formatted signature it
    /// describes, but only while the signature is still that source and nothing else, so it is
    /// done once and never to a signature the owner has written or changed. Returns whether it
    /// was replaced.
    @discardableResult
    public mutating func replaceCarriedOverHTML(_ id: UUID, source html: String, with text: NSAttributedString,
                                                plainIn base: [NSAttributedString.Key: Any] = [:]) -> Bool {
        guard carriedOverHTML.contains(where: { $0.id == id && $0.html == html }),
              let i = signatures.firstIndex(where: { $0.id == id }) else { return false }
        signatures[i].setText(text, html: SignatureSource.sendable(html), plainIn: base)
        // A signature of words alone keeps them as plain text, which is no longer the source.
        if signatures[i].rich == nil && signatures[i].plain == html { return false }
        return true
    }

    /// The account's own signature as a signature named after the account, or nothing for a
    /// blank one.
    private mutating func carryOver(_ account: AccountInfo) -> Signature? {
        guard !account.signature.trimmed.isEmpty else { return nil }
        let named = account.displayName.trimmed
        let signature = Signature(name: uniqueName(named.isEmpty ? account.email : named, orElse: account.email),
                                  plain: account.signature)
        signatures.append(signature)
        return signature
    }

    /// `base` when no signature has that name, else `alternative`, else the first with a number
    /// after it.
    public func uniqueName(_ base: String, orElse alternative: String? = nil) -> String {
        let candidates = [base, alternative].compactMap { $0?.trimmed }.filter { !$0.isEmpty }
        if let free = candidates.first(where: { !isTaken($0) }) { return free }
        let root = candidates.first ?? "Untitled"
        var number = 2
        while isTaken("\(root) \(number)") { number += 1 }
        return "\(root) \(number)"
    }

    private func isTaken(_ name: String) -> Bool {
        signatures.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Keeps the SignatureBook in signatures.json beside the accounts file, written whole and
/// atomically, so a crash mid-write leaves the last good copy.
public struct SignatureStore: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public init(layout: FileLayout) {
        self.init(file: layout.signaturesFile)
    }

    /// Why the book did not simply come from the file, for the owner to be told.
    public enum Problem: Equatable, Sendable {
        /// Written by a newer build: read as far as this one can, and never written over.
        case newer
        /// There but not readable, as with wrong permissions: left alone and not written over.
        case unreadable
        /// Read but not understood: moved whole to this file, and a new book begun.
        case setAside(URL)
    }

    public struct Opened: Sendable {
        public var book: SignatureBook
        public var problem: Problem?

        /// A file kept for a newer build, or one that could not be read, is never written over.
        public var writable: Bool {
            switch problem {
            case nil, .setAside: return true
            case .newer, .unreadable: return false
            }
        }
    }

    /// The version is read before anything else, because a newer build may have changed the
    /// rest of the file past what this one can decode.
    private struct Header: Decodable {
        let version: Int
    }

    /// The stored book. Only a file of this build's version or older that will not decode is
    /// moved aside, the accounts' own signatures then carried over again into a new book, so
    /// nothing is lost.
    public func open() -> Opened {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Opened(book: SignatureBook(), problem: nil)
        } catch {
            return Opened(book: SignatureBook(), problem: .unreadable)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let header = try? decoder.decode(Header.self, from: data), header.version > SignatureBook.currentVersion {
            return Opened(book: (try? decoder.decode(SignatureBook.self, from: data)) ?? SignatureBook(), problem: .newer)
        }
        if let book = try? decoder.decode(SignatureBook.self, from: data) { return Opened(book: book, problem: nil) }
        guard let aside = setAside() else { return Opened(book: SignatureBook(), problem: .unreadable) }
        return Opened(book: SignatureBook(), problem: .setAside(aside))
    }

    public func save(_ book: SignatureBook) throws {
        try AtomicFile.writeJSON(book, to: file)
    }

    /// Nil when the file could not be moved, which is then left as it is.
    private func setAside() -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = file.deletingLastPathComponent().appendingPathComponent("signatures-unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: file, to: aside)
            return aside
        } catch {
            return nil
        }
    }
}
