import Foundation

/// The Bcc recipients of the messages sent from this Mac, by Message-ID. What goes out never
/// names them, so the copy Gmail files in Sent Mail does not either; they are written down here
/// as a message is sent, so that FalconMail can show them on it in Sent and in its conversation,
/// as Outlook shows Bcc on a message its owner sent. Kept in a file of its own, sentBcc.json,
/// which earlier builds never read.
public final class SentBccStore: @unchecked Sendable {
    struct Entry: Codable, Hashable {
        var messageID: String
        var bcc: [EmailAddress]
        var sentAt: Date
    }

    private struct File: Codable {
        var entries: [Entry]
    }

    /// The oldest are let go beyond this many, which is years of mail for anyone.
    static let limit = 5000

    public let file: URL
    private let lock = NSLock()
    private var entries: [String: Entry]?

    public init(file: URL) {
        self.file = file
    }

    private static let registryLock = NSLock()
    private static var registry: [URL: SentBccStore] = [:]

    /// The one store for `file` in this process, so that the Outbox, which the reader asks, and
    /// the Gmail engine's sender, which writes down what goes by Gmail's own send, share what they
    /// have read and written rather than each keeping a copy of its own.
    public static func shared(file: URL) -> SentBccStore {
        let key = file.standardizedFileURL
        return registryLock.withLock {
            if let known = registry[key] { return known }
            let made = SentBccStore(file: key)
            registry[key] = made
            return made
        }
    }

    /// Writes down the Bcc recipients of the message sent as `messageID`; none, nothing.
    public func record(messageID: String, bcc: [EmailAddress], at date: Date = Date()) {
        let key = SentBccStore.key(messageID)
        var seen = Set<String>()
        let bcc = bcc.filter { !$0.address.trimmed.isEmpty && seen.insert($0.address.trimmed.lowercased()).inserted }
        guard !key.isEmpty, !bcc.isEmpty else { return }
        lock.withLock {
            var all = loaded()
            all[key] = Entry(messageID: messageID, bcc: bcc, sentAt: date)
            if all.count > SentBccStore.limit {
                let oldest = all.values.sorted { $0.sentAt < $1.sentAt }.prefix(all.count - SentBccStore.limit)
                for e in oldest { all[SentBccStore.key(e.messageID)] = nil }
            }
            entries = all
            save(all)
        }
    }

    /// Forgets a message that never went, as one cancelled in the Outbox.
    public func forget(messageID: String) {
        let key = SentBccStore.key(messageID)
        lock.withLock {
            var all = loaded()
            guard all.removeValue(forKey: key) != nil else { return }
            entries = all
            save(all)
        }
    }

    /// The Bcc recipients written down for `messageID`, or none.
    public func bcc(forMessageID messageID: String) -> [EmailAddress] {
        let key = SentBccStore.key(messageID)
        guard !key.isEmpty else { return [] }
        return lock.withLock { loaded()[key]?.bcc ?? [] }
    }

    /// The Bcc line of a message: what its own Bcc header names, as the copy another program
    /// keeps in Sent or a draft has, and what was written down here as it was sent, each
    /// address once.
    public static func shown(header: String?, recorded: [EmailAddress]) -> [EmailAddress] {
        var seen = Set<String>()
        return (AddressParser.parse(header) + recorded).filter { !$0.address.isEmpty && seen.insert($0.address.lowercased()).inserted }
    }

    /// A Message-ID as written, with or without its angle brackets, in any case.
    static func key(_ messageID: String) -> String {
        messageID.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased()
    }

    private func loaded() -> [String: Entry] {
        if let entries { return entries }
        let stored = AtomicFile.readJSON(File.self, from: file)?.entries ?? []
        let all = Dictionary(stored.map { (SentBccStore.key($0.messageID), $0) }, uniquingKeysWith: { $1 })
        entries = all
        return all
    }

    private func save(_ all: [String: Entry]) {
        let sorted = all.values.sorted { $0.sentAt < $1.sentAt }
        do {
            try AtomicFile.writeJSON(File(entries: sorted), to: file)
        } catch {
            Log.warning("Outbox", "could not write down a sent message's Bcc recipients: \(error.localizedDescription)", logAs: "send")
        }
    }
}

/// The To, Cc and Bcc lines the reader shows for a message, the same for a message the Mac
/// stores and for a Google message on the Gmail API (`<account>:gm:<hex>`). The row's own
/// addresses come first; a row that stands in before Gmail has answered knows none, and then its
/// body's headers give them. Bcc is what the message's own Bcc header names, what its copy in
/// Sent kept on its row, and what was written down as it was sent (see SentBccStore), looked up
/// by the row's Message-ID or, when the row has none yet, its body's.
public struct ReaderRecipients: Equatable, Sendable {
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]

    public init(_ message: MessageSummary, parsed: MIMEMessage?, recorded: (String) -> [EmailAddress]) {
        to = message.to.isEmpty ? (parsed?.to ?? []) : message.to
        cc = message.cc.isEmpty ? (parsed?.cc ?? []) : message.cc
        let messageID = message.messageID.trimmed.isEmpty
            ? (AddressParser.messageIDs(parsed?.headers.first("Message-ID")).first ?? "")
            : message.messageID
        bcc = SentBccStore.shown(header: parsed?.headers.first("Bcc"), recorded: (message.bcc ?? []) + recorded(messageID))
    }
}

/// The copy of a sent message kept in the account's own Sent folder, where the server does not
/// file one itself. It carries a Bcc header naming everyone the envelope named whom the To and
/// Cc headers do not, as Outlook's copy in Sent does: only its owner ever sees it.
public enum SentCopy {
    public static func addingBcc(to raw: Data, envelope: [String]) -> Data {
        let headers = MIMEHeaders.parse(raw)
        guard headers.first("Bcc") == nil else { return raw }
        let shown = Set((AddressParser.parse(headers.first("To")) + AddressParser.parse(headers.first("Cc"))).map { $0.address.lowercased() })
        var seen = Set<String>()
        let hidden = envelope.filter { !shown.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
        guard !hidden.isEmpty else { return raw }
        return Data("Bcc: \(hidden.joined(separator: ",\r\n "))\r\n".utf8) + raw
    }
}

extension OutboxItem {
    /// Who the message goes to, box by box, by name where it has one: "To: Ana Lee, Bob Stone;
    /// Cc: Cy; Bcc: Dee". An item an earlier build queued knows only its addresses, all together.
    public var recipientSummary: String {
        guard to != nil || cc != nil || bcc != nil else { return recipients.joined(separator: ", ") }
        let boxes: [(String, [EmailAddress])] = [("To", to ?? []), ("Cc", cc ?? []), ("Bcc", bcc ?? [])]
        return boxes.filter { !$0.1.isEmpty }
            .map { "\($0.0): " + $0.1.map(\.displayName).joined(separator: ", ") }
            .joined(separator: "; ")
    }
}
