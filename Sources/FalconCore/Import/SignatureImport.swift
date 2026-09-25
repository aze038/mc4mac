import AppKit

/// A signature offered for import, from Legacy Outlook for Mac or from Gmail, before it is a
/// FalconMail signature: its name, its HTML, the pictures that HTML shows by cid:, and which
/// addresses it should start messages from.
public struct SignatureCandidate: Identifiable, Sendable, Equatable {
    public enum Origin: Hashable, Sendable {
        /// From a Legacy Outlook profile, by its name.
        case outlook(profile: String)
        /// From the Gmail settings of a Google account, by its address.
        case gmail(account: String)
    }

    public let id: UUID
    public var name: String
    public var origin: Origin
    public var html: String
    /// The pictures the HTML shows by cid:.
    public var pictures: [MIMEAttachment]
    /// Pictures the HTML shows that could not be found; each is left out.
    public var missingPictures: Int
    /// The addresses whose new messages, replies and forwards the signature should start.
    public var defaultAddresses: [String]
    /// Whether the source says so, as Gmail does for each address, or FalconMail suggests it, as
    /// for Outlook, which keeps that choice where the import does not read.
    public var defaultsKnown: Bool

    public init(id: UUID = UUID(), name: String, origin: Origin, html: String, pictures: [MIMEAttachment] = [],
                missingPictures: Int = 0, defaultAddresses: [String] = [], defaultsKnown: Bool = false) {
        self.id = id
        self.name = name
        self.origin = origin
        self.html = html
        self.pictures = pictures
        self.missingPictures = missingPictures
        self.defaultAddresses = defaultAddresses
        self.defaultsKnown = defaultsKnown
    }

    /// The pictures it would fetch from the web, as a Gmail signature shows its logo.
    public var remoteAddresses: [String] { RemotePictures.addresses(inHTML: html) }

    /// The accounts here that send as one of its default addresses, in the order given.
    public func defaultAccounts(in accounts: [AccountInfo]) -> [UUID] {
        accounts.filter { account in defaultAddresses.contains { account.sends(as: $0) } }.map(\.id)
    }

    /// The FalconMail signature it becomes, under its own name: its HTML read with its fonts,
    /// sizes, colours and links, and its pictures in place at the size the HTML gives them; a
    /// picture from the web is the one `remote` holds for its address, else an empty box that
    /// is sent from there. Text it sets no font or colour for takes `attributes`. Nil when the
    /// HTML cannot be read.
    ///
    /// AppKit reads HTML through WebKit, which must be on the main thread.
    @MainActor
    public func signature(remote: [String: Data] = [:], attributes: [NSAttributedString.Key: Any]) -> Signature? {
        // HTML that can be sent as it is, as Gmail's is, is read as the fragment that is sent,
        // exactly as the same HTML pasted into the signature editor is.
        let source = SignatureSource.sendable(html)
        guard let text = Signature.text(fromHTML: source ?? html, parts: pictures, pictures: remote, attributes: attributes),
              text.length > 0 else { return nil }
        var signature = Signature(name: name)
        signature.setText(text, html: source, plainIn: attributes)
        return signature.isBlank ? nil : signature
    }

    // MARK: - From each source

    /// Every signature of an Outlook profile.
    ///
    /// Outlook keeps each account's choice of default signature with the account's own settings,
    /// which the import does not read, so the defaults are suggested: a profile's only signature
    /// for every account the profile has, as a signature set up in Outlook is for them; with
    /// several signatures, one whose name holds an account's address for that account, and none
    /// for the rest.
    public static func outlook(_ read: OutlookProfileSignatures) -> [SignatureCandidate] {
        let addresses = read.accounts.map(\.email)
        return read.signatures.map { signature in
            let suggested: [String]
            if read.signatures.count == 1 {
                suggested = addresses
            } else {
                suggested = addresses.filter { signature.name.localizedCaseInsensitiveContains($0) }
            }
            return SignatureCandidate(name: signature.name, origin: .outlook(profile: read.profile.name), html: signature.html,
                                      pictures: signature.pictures, missingPictures: signature.missingPictures.count,
                                      defaultAddresses: suggested, defaultsKnown: false)
        }
    }

    /// Each address's Gmail signature, called Gmail – and the address, for that address's
    /// messages. An address without a signature gives none.
    public static func gmail(_ addresses: [GmailSendAs], account: String) -> [SignatureCandidate] {
        addresses.compactMap { entry in
            guard let html = entry.signature, !html.trimmed.isEmpty else { return nil }
            let address = entry.sendAsEmail.trimmed
            return SignatureCandidate(name: "Gmail – \(address)", origin: .gmail(account: account), html: html,
                                      defaultAddresses: [address], defaultsKnown: true)
        }
    }
}

/// What to do with an imported signature whose name one here already has.
public enum SignatureNameClash: String, CaseIterable, Sendable, Codable {
    /// Import it under the next free name, "Main 2".
    case keepBoth
    /// Put its text in place of the one here, which keeps its place as any account's default.
    case replace
    /// Leave it out.
    case skip
}

/// One signature to import, as the owner chose.
public struct SignatureImportItem: Sendable {
    public var signature: Signature
    /// What to do when a signature here has its name; unused when none has.
    public var clash: SignatureNameClash
    /// The accounts whose new messages, replies and forwards it is to start.
    public var defaultFor: [UUID]

    public init(signature: Signature, clash: SignatureNameClash = .keepBoth, defaultFor: [UUID] = []) {
        self.signature = signature
        self.clash = clash
        self.defaultFor = defaultFor
    }
}

/// What an import did, for the owner to be told.
public struct SignatureImportOutcome: Equatable, Sendable {
    public struct Default: Equatable, Sendable {
        public var accountID: UUID
        public var signatureID: UUID
    }

    /// Every signature that came in, made or replaced, in the order of the import.
    public var imported: [UUID] = []
    /// Signatures made, by their ids, under the names they were given.
    public var added: [UUID] = []
    /// Signatures here whose text was replaced.
    public var replaced: [UUID] = []
    /// Names left out.
    public var skipped: [String] = []
    /// Accounts whose new messages, replies and forwards now start with the signature.
    public var defaults: [Default] = []

    public init() {}

    public var isEmpty: Bool { added.isEmpty && replaced.isEmpty }
}

extension SignatureBook {
    /// The signature here with `name`, as names are compared, regardless of case.
    public func signature(named name: String) -> Signature? {
        sorted.first { $0.name.caseInsensitiveCompare(name.trimmed) == .orderedSame }
    }

    /// Whether a signature here already has `name`.
    public func hasSignature(named name: String) -> Bool {
        signature(named: name) != nil
    }

    /// Adds `items` in order. One whose name a signature here already had before the import is
    /// kept beside it under the next free name, put in its place, or left out, as its `clash`
    /// says; two items of the same name both come in, the second under the next free name.
    /// Each item that comes in becomes the signature for new messages and for replies and
    /// forwards of the accounts it is the default for.
    @discardableResult
    public mutating func importing(_ items: [SignatureImportItem]) -> SignatureImportOutcome {
        let before = Set(signatures.map { $0.name.lowercased() })
        var outcome = SignatureImportOutcome()
        for item in items {
            var incoming = item.signature
            let name = incoming.name.trimmed.isEmpty ? "Untitled" : incoming.name.trimmed
            let placed: UUID
            if before.contains(name.lowercased()), item.clash == .skip {
                outcome.skipped.append(name)
                continue
            } else if before.contains(name.lowercased()), item.clash == .replace, let existing = signature(named: name),
                      let index = signatures.firstIndex(where: { $0.id == existing.id }) {
                signatures[index].plain = incoming.plain
                signatures[index].rich = incoming.rich
                signatures[index].html = incoming.html
                placed = existing.id
                if !outcome.replaced.contains(placed) { outcome.replaced.append(placed) }
                if !outcome.imported.contains(placed) { outcome.imported.append(placed) }
            } else {
                incoming.name = uniqueName(name)
                if signatures.contains(where: { $0.id == incoming.id }) { incoming.id = UUID() }
                signatures.append(incoming)
                placed = incoming.id
                outcome.added.append(placed)
                outcome.imported.append(placed)
            }
            for account in item.defaultFor {
                setDefault(placed, for: account, .newMessages)
                setDefault(placed, for: account, .replies)
                outcome.defaults.removeAll { $0.accountID == account }
                outcome.defaults.append(.init(accountID: account, signatureID: placed))
            }
        }
        return outcome
    }
}

extension AccountInfo {
    /// Whether the account sends as `address`, as addresses are compared, regardless of case.
    public func sends(as address: String) -> Bool {
        email.trimmed.caseInsensitiveCompare(address.trimmed) == .orderedSame
    }
}
