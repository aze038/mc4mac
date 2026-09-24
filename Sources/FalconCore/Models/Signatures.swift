import AppKit

/// A signature as Legacy Outlook keeps one: a named piece of rich text that belongs to no
/// account. Accounts only choose which signature, if any, their new messages and their replies
/// start with (see SignatureBook).
public struct Signature: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// The words alone, pictures left out. A signature carried over from an account has only
    /// this until it is first edited.
    public var plain: String
    /// The formatted text as flat RTFD, which unlike RTF keeps pictures.
    public var rich: Data?

    public init(id: UUID = UUID(), name: String, plain: String = "", rich: Data? = nil) {
        self.id = id
        self.name = name
        self.plain = plain
        self.rich = rich
    }

    /// The signature as it is drawn. Plain text carries no formatting of its own, so it takes
    /// the formatting of wherever it is put.
    public var text: NSAttributedString {
        guard let rich, let text = try? NSAttributedString(data: rich, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                            documentAttributes: nil) else {
            return NSAttributedString(string: plain)
        }
        return text
    }

    public mutating func setText(_ text: NSAttributedString) {
        plain = text.string.replacingOccurrences(of: Signature.pictureMark, with: "")
        rich = text.rtfd(from: NSRange(location: 0, length: text.length),
                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    /// Nothing to put in a message: no words and no pictures, as with an account's signature of
    /// only spaces, which was never inserted either.
    public var isBlank: Bool {
        plain.trimmed.isEmpty && !text.string.contains(Signature.pictureMark)
    }

    /// Where a picture sits in the text.
    static let pictureMark = "\u{FFFC}"

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
    /// Accounts whose own signature, from before signatures had names, has been carried over.
    /// Each is carried over once, so a signature deleted here never comes back, while an account
    /// added since, even by an older build, is still picked up.
    public var adoptedAccounts: [UUID]

    public init(signatures: [Signature] = [], defaults: [SignatureDefaults] = [], adoptedAccounts: [UUID] = []) {
        version = SignatureBook.currentVersion
        self.signatures = signatures
        self.defaults = defaults
        self.adoptedAccounts = adoptedAccounts
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

    /// A new, empty signature called Untitled, or Untitled 2 and on when that is taken.
    @discardableResult
    public mutating func add() -> Signature {
        let signature = Signature(name: uniqueName("Untitled"))
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

    public mutating func setText(_ text: NSAttributedString, of id: UUID) {
        guard let i = signatures.firstIndex(where: { $0.id == id }) else { return }
        signatures[i].setText(text)
    }

    /// Carries over the one plain signature each account kept before signatures had names. An
    /// account's signature was put into every new message, reply and forward from it, so the
    /// signature made from it becomes both its defaults; an account without one gets None and
    /// no signature. Returns whether anything changed.
    @discardableResult
    public mutating func adopt(_ accounts: [AccountInfo]) -> Bool {
        var changed = false
        for account in accounts where !adoptedAccounts.contains(account.id) {
            adoptedAccounts.append(account.id)
            changed = true
            guard !account.signature.trimmed.isEmpty else { continue }
            let named = account.displayName.trimmed
            let signature = Signature(name: uniqueName(named.isEmpty ? account.email : named, orElse: account.email),
                                      plain: account.signature)
            signatures.append(signature)
            setDefault(signature.id, for: account.id, .newMessages)
            setDefault(signature.id, for: account.id, .replies)
        }
        return changed
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

    /// The stored book, and whether it may be written back. A file this build cannot read is
    /// moved aside whole and a new book begun, whose accounts' own signatures are then carried
    /// over again, so nothing is lost. A file from a newer build is read but never written over.
    public func open() -> (book: SignatureBook, writable: Bool) {
        guard FileManager.default.fileExists(atPath: file.path) else { return (SignatureBook(), true) }
        guard let book = AtomicFile.readJSON(SignatureBook.self, from: file) else {
            setAside()
            return (SignatureBook(), true)
        }
        return (book, book.version <= SignatureBook.currentVersion)
    }

    public func save(_ book: SignatureBook) throws {
        try AtomicFile.writeJSON(book, to: file)
    }

    private func setAside() {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = file.deletingLastPathComponent().appendingPathComponent("signatures-unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: file, to: aside)
    }
}
