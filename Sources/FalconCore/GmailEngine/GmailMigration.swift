import Foundation

// Moving a Google account from v1.10's IMAP engine to the Gmail engine, and back (§12).
//
// The owner's rule of 25 September: Google accounts use the Gmail API only, never IMAP or SMTP,
// so the switch is on by default for every account signed in with Google. Settings → Accounts
// keeps a switch per account ("Use the Gmail API (recommended)") that returns it to IMAP.
//
// Nothing the owner has is deleted or written over by a switch. The account's IMAP store,
// `folders.json` and folder directories under `Accounts/<id>/`, stays exactly as it was, so an
// earlier FalconMail can take the account back at any time; the Gmail engine keeps its own
// files under `Accounts/<id>/Gmail/` only. What the owner made on this Mac (categories, mutes,
// the Outbox, drafts and the session) is kept, with Gmail's ids added beside the old ones.

// MARK: - The switch

/// Where the owner's choice for each account is kept: the app's preferences, which an earlier
/// FalconMail never reads.
public protocol GmailEngineSwitchStore: AnyObject, Sendable {
    /// The owner's choice for the account; nil when he never changed it, which means on.
    func choice(for accountID: UUID) -> Bool?
    func setChoice(_ on: Bool, for accountID: UUID)
}

/// The switch kept in `UserDefaults`, as `gmailEngine.<account id>`.
public final class DefaultsGmailEngineSwitchStore: GmailEngineSwitchStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func key(_ accountID: UUID) -> String { "gmailEngine.\(accountID.uuidString)" }

    public func choice(for accountID: UUID) -> Bool? {
        defaults.object(forKey: DefaultsGmailEngineSwitchStore.key(accountID)) as? Bool
    }

    public func setChoice(_ on: Bool, for accountID: UUID) {
        defaults.set(on, forKey: DefaultsGmailEngineSwitchStore.key(accountID))
    }
}

/// The switch kept in memory, for tests.
public final class MemoryGmailEngineSwitchStore: GmailEngineSwitchStore, @unchecked Sendable {
    private let lock = NSLock()
    private var choices: [UUID: Bool]

    public init(_ choices: [UUID: Bool] = [:]) {
        self.choices = choices
    }

    public func choice(for accountID: UUID) -> Bool? { lock.withLock { choices[accountID] } }
    public func setChoice(_ on: Bool, for accountID: UUID) { lock.withLock { choices[accountID] = on } }
}

public enum GmailEngineSwitch {
    /// Signed in with Google, as every gmail.com, googlemail.com and Google Workspace account
    /// added with Sign in with Google is: the Gmail API can serve it.
    public static func isEligible(_ account: AccountInfo) -> Bool {
        account.provider == "google" && !account.usesPassword
    }

    /// Whether the account is meant to be on the Gmail API: every eligible account unless the
    /// owner turned its switch off.
    public static func isOn(_ account: AccountInfo, in store: any GmailEngineSwitchStore) -> Bool {
        isEligible(account) && (store.choice(for: account.id) ?? true)
    }

    /// A Google account set up with an app password on Google's IMAP and SMTP servers, before
    /// this build. It stays on IMAP until the owner signs in with Google, and Settings says so.
    public static func usesGoogleIMAP(_ account: AccountInfo) -> Bool {
        !isEligible(account) && (TransportGuard.isGoogleHost(account.imapHost) || TransportGuard.isGoogleHost(account.smtpHost))
    }

    /// Settings' line for such an account.
    public static func googleIMAPNotice(_ account: AccountInfo) -> String {
        "\(account.email) uses Gmail through IMAP. Sign in with Google to use the Gmail API."
    }

    /// Why an account stays on IMAP although its switch is on.
    public static func waitingNotice(_ email: String) -> String {
        "\(email) has changes waiting to reach Gmail. It will switch once they have gone."
    }

    /// Why the switch could not be turned off.
    public static func cannotTurnOffNotice(_ email: String) -> String {
        "\(email) has changes waiting to reach Gmail. Try again when you're online."
    }
}

// MARK: - What the move has done, per account

/// `Gmail/migration.json`: how far moving the account to the Gmail engine has got. An earlier
/// FalconMail never reads it.
public struct GmailMigrationRecord: Codable, Equatable, Sendable {
    /// When the account first moved to the Gmail API on this Mac.
    public var firstSwitchedAt: Date?
    /// Since when it runs on the Gmail API; nil while it is on IMAP.
    public var switchedAt: Date?
    /// When the owner last turned the switch off.
    public var switchedOffAt: Date?
    /// The account's entries from the IMAP store were taken out of Spotlight at this switch.
    public var spotlightCleared: Bool?
    /// Category keys of the IMAP store already looked at, matched or not.
    public var categoryKeysDone: [String]?
    /// Those that matched no single Gmail message. They stay as they are and are never applied
    /// to a Gmail row.
    public var legacyCategoryKeys: [String]?
    /// The read-only part of the probe ran for this account, and what it found.
    public var probeRanAt: Date?
    public var probe: GmailProbeFindings?

    public init() {}

    public var isOnGmail: Bool { switchedAt != nil }
}

/// What the probe's read-only part found that the engine depends on (§14.4), without its timings.
public struct GmailProbeFindings: Codable, Equatable, Sendable {
    public var snippetWithMetadata: Bool?
    public var listNewestFirst: Bool?
    public var beforeEpochMatchesInternalDate: Bool?
    public var messageAddedCarriesLabels: Bool?
    public var batchAddress: String?
    public var labelTotalsCountJunkAndDeleted: Bool?
    public var profileTotalCountsJunkAndDeleted: Bool?
    public var listReturnsChats: Bool?
    public var units: Int?

    public init() {}

    public init(_ report: GmailProbe.Report) {
        snippetWithMetadata = report.snippetWithMetadata
        listNewestFirst = report.listNewestFirst
        beforeEpochMatchesInternalDate = report.beforeEpochMatchesInternalDate
        messageAddedCarriesLabels = report.messageAddedCarriesLabels
        batchAddress = report.batchAddress
        labelTotalsCountJunkAndDeleted = report.labelTotalsCountJunkAndDeleted
        profileTotalCountsJunkAndDeleted = report.profileTotalCountsJunkAndDeleted
        listReturnsChats = report.listReturnsChats
        units = report.units
    }

    /// The engine's settings with the documented fallbacks the findings call for: counts compared
    /// by the rule Gmail follows for Junk Email and Deleted Items, and chats listed so that they
    /// are left out of every view. What was not found keeps the setting as it was.
    public func adapted(_ settings: GmailEngineSettings) -> GmailEngineSettings {
        var adapted = settings
        if let labels = labelTotalsCountJunkAndDeleted { adapted.countRule.labelTotalsCountJunkAndDeleted = labels }
        if let profile = profileTotalCountsJunkAndDeleted { adapted.countRule.profileTotalCountsJunkAndDeleted = profile }
        if let chats = listReturnsChats { adapted.listsChats = chats }
        return adapted
    }

    /// One line for the app's log: yes-or-no findings and counts, never a subject or an address.
    public var logLine: String {
        func say(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "unknown" }
        return "snippet=\(say(snippetWithMetadata)) newestFirst=\(say(listNewestFirst)) beforeEpoch=\(say(beforeEpochMatchesInternalDate)) "
            + "addedLabels=\(say(messageAddedCarriesLabels)) batch=\(batchAddress ?? "unknown") "
            + "labelTotalsJunkDeleted=\(say(labelTotalsCountJunkAndDeleted)) profileTotalJunkDeleted=\(say(profileTotalCountsJunkAndDeleted)) "
            + "chats=\(say(listReturnsChats)) units=\(units ?? 0)"
    }
}

/// `Gmail/migration.json` on disk.
public struct GmailMigrationFile: Sendable {
    public let url: URL

    public init(files: GmailFiles) {
        url = files.migration
    }

    public func load() -> GmailMigrationRecord {
        AtomicFile.readJSON(GmailMigrationRecord.self, from: url) ?? GmailMigrationRecord()
    }

    public func save(_ record: GmailMigrationRecord) {
        do {
            try AtomicFile.writeJSON(record, to: url)
        } catch {
            Log.warning("gmail", "the record of the move to the Gmail API could not be saved", error: error, code: "gmailFileUnwritable")
        }
    }

    public func update(_ change: (inout GmailMigrationRecord) -> Void) {
        var record = load()
        change(&record)
        save(record)
    }
}

// MARK: - Reading the IMAP store without writing it

/// What v1.10's IMAP store kept for an account, read without ever writing it. No `FolderStore`
/// is opened, since opening one creates folders, compacts its journal and sets unreadable files
/// aside: the store must stay exactly as it was, for going back.
public final class LegacyStoreReader: @unchecked Sendable {
    public let layout: FileLayout
    public let accountID: UUID
    private let lock = NSLock()
    private var folderRows: [UUID: [UInt32: MessageSummary]] = [:]

    public init(layout: FileLayout, accountID: UUID) {
        self.layout = layout
        self.accountID = accountID
    }

    /// The account's folders as `folders.json` lists them.
    public func folders() -> [FolderInfo] {
        AtomicFile.readJSON([FolderInfo].self, from: layout.foldersFile(accountID)) ?? []
    }

    /// The stored row a key names, `"<account>:<folder>:<uid>"`, as the store last kept it.
    public func message(id: String) -> MessageSummary? {
        let parts = id.split(separator: ":").map(String.init)
        guard parts.count == 3, UUID(uuidString: parts[0]) == accountID, let folderID = UUID(uuidString: parts[1]),
              let uid = UInt32(parts[2]) else { return nil }
        return rows(of: folderID)[uid]
    }

    /// Every row a folder kept: its index, with its journal applied.
    public func rows(of folderID: UUID) -> [UInt32: MessageSummary] {
        if let known = lock.withLock({ folderRows[folderID] }) { return known }
        let directory = layout.folderDirectory(accountID: accountID, folderID: folderID)
        var rows: [UInt32: MessageSummary] = [:]
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.plist")),
           let list = try? PropertyListDecoder().decode([MessageSummary].self, from: data) {
            for row in list { rows[row.uid] = row }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("journal.jsonl")) {
            let decoder = JSONDecoder()
            for line in data.split(separator: 0x0A) {
                guard let op = try? decoder.decode(FolderJournalOp.self, from: line) else { continue }
                switch op {
                case .upsert(let m): rows[m.uid] = m
                case .flags(let uid, let flags): rows[uid]?.apply(flags: flags)
                case .remove(let uids): for uid in uids { rows[uid] = nil }
                case .body(let uid, let snippet, let hasAttachments):
                    rows[uid]?.snippet = snippet
                    rows[uid]?.hasAttachments = hasAttachments
                case .threadKey(let uid, let key): rows[uid]?.threadKey = key
                case .bodyRemoved(let uid): rows[uid]?.hasBody = false
                }
            }
        }
        lock.withLock { folderRows[folderID] = rows }
        return rows
    }
}

// MARK: - Re-keying by Message-ID

/// Finds the Gmail message a row of the IMAP store was, by its Message-ID, as safely as v1.10's
/// search does (§12.2): only a usable Message-ID is trusted (not `<>`, and with a domain), a
/// candidate counts only when its subject or its date agrees too, and when more than one message
/// still matches nothing is guessed.
public struct GmailMessageMatcher: Sendable {
    public let accountID: UUID
    public let transport: any GmailTransport
    public let work: WorkClass

    public init(accountID: UUID, transport: any GmailTransport, work: WorkClass = .background(.index)) {
        self.accountID = accountID
        self.transport = transport
        self.work = work
    }

    /// A stored Message-ID as a header holds it, in angle brackets, which v1.10 keeps them in.
    static func header(_ messageID: String) -> String? {
        let trimmed = messageID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("<") ? trimmed : "<\(trimmed)>"
    }

    public enum Match: Equatable, Sendable {
        case one(GmailMessageID)
        /// No usable Message-ID, or no message agrees.
        case none
        /// More than one message agrees, as when a sender reused a Message-ID or an import
        /// duplicated one.
        case several
    }

    /// The one Gmail message `stored` was: `messages.list q="rfc822msgid:<id>"` (5 units), then
    /// each candidate's headers (20 units each). Throws only when Gmail could not be asked, so
    /// the caller can try again later rather than record no match.
    public func match(_ stored: MessageSummary) async throws -> Match {
        guard let usable = GmailAccountSearch.usableMessageID(GmailMessageMatcher.header(stored.messageID)),
              let bare = GmailSender.bare(usable) else { return .none }
        let page = try await transport.list(GmailListQuery(query: "rfc822msgid:\(bare)", includeSpamTrash: true, maxResults: 5), work: work)
        var agreeing: [GmailMessageID] = []
        for ref in page.refs {
            let message: GmailMessage
            do {
                message = try await transport.message(ref.id, format: .row, work: work)
            } catch let error as GoogleAPIError where error.kind == .notFound {
                continue
            }
            let candidate = GmailServerRow.summary(for: message, accountID: accountID)
            if GmailAccountSearch.sameMessage(stored, candidate) { agreeing.append(ref.id) }
        }
        switch agreeing.count {
        case 0: return .none
        case 1: return .one(agreeing[0])
        default: return .several
        }
    }
}

/// What re-keying Outlook's colour categories did.
public struct GmailCategoryRekeying: Equatable, Sendable {
    /// New keys `"<account>:gm:<hex>"`, each with the categories of the old key it matched. They
    /// are added beside the old keys, which stay.
    public var added: [String: [String]] = [:]
    /// Old keys looked at, matched or not; they are never looked at again.
    public var done: [String] = []
    /// Old keys with no single match, kept as they are and never applied to a Gmail row.
    public var legacy: [String] = []
    /// Gmail could not be asked: the rest are tried again later.
    public var interrupted = false

    public init() {}
}

/// Outlook's colour categories are kept on this Mac by the row's id, `"<account>:<folder>:<uid>"`
/// for a stored message. Once the account is on the Gmail engine, each old key's message is
/// found by its Message-ID and its categories are added under the Gmail row's id too (§12.2).
/// Old keys are never removed, so going back to an earlier FalconMail finds them as they were.
public struct GmailCategoryRekeyer: Sendable {
    public let accountID: UUID
    public let reader: LegacyStoreReader
    public let matcher: GmailMessageMatcher

    public init(accountID: UUID, reader: LegacyStoreReader, matcher: GmailMessageMatcher) {
        self.accountID = accountID
        self.reader = reader
        self.matcher = matcher
    }

    /// The old keys of this account's stored rows among `assignments`, less those in `done`.
    public func keysToRekey(in assignments: [String: [String]], done: Set<String>) -> [String] {
        let prefix = accountID.uuidString + ":"
        return assignments.keys.filter { key in
            key.hasPrefix(prefix) && !done.contains(key) && !(RowKey(string: key)?.isGmail ?? true)
        }.sorted()
    }

    /// Re-keys up to `limit` keys, in batches of 50 between which it yields.
    public func rekey(_ assignments: [String: [String]], done: Set<String>, limit: Int = .max) async -> GmailCategoryRekeying {
        var result = GmailCategoryRekeying()
        let keys = keysToRekey(in: assignments, done: done).prefix(limit)
        for (index, key) in keys.enumerated() {
            if index > 0, index % 50 == 0 { await Task.yield() }
            guard let names = assignments[key], !names.isEmpty else {
                result.done.append(key)
                continue
            }
            guard let stored = reader.message(id: key) else {
                result.done.append(key)
                result.legacy.append(key)
                continue
            }
            do {
                switch try await matcher.match(stored) {
                case .one(let id):
                    let newKey = RowKey.gmail(account: accountID, id: id).stringValue
                    result.added[newKey] = Array(Set((result.added[newKey] ?? []) + names)).sorted()
                case .none, .several:
                    result.legacy.append(key)
                }
                result.done.append(key)
            } catch {
                result.interrupted = true
                break
            }
        }
        return result
    }

    /// `assignments` with `rekeying`'s new keys added, their categories joined with any the Gmail
    /// row already has. No key is removed.
    public static func merged(_ assignments: [String: [String]], with rekeying: GmailCategoryRekeying) -> [String: [String]] {
        var out = assignments
        for (key, names) in rekeying.added {
            out[key] = Array(Set((out[key] ?? []) + names)).sorted()
        }
        return out
    }
}

// MARK: - The session

/// Keeps `session.json` readable by an earlier FalconMail (§5.9, §12.2): rows of Google accounts
/// on the Gmail engine (`"<account>:gm:<hex>"`) never go into the lists it reads, and what it
/// wrote there for such an account, which this build cannot show, is carried forward untouched.
public enum SessionCarryForward {
    /// The message a row id names: a conversation's message line is tagged `child:<id>`.
    static func messageID(_ id: String) -> String {
        id.hasPrefix(ReadMarking.messageLineTag) ? String(id.dropFirst(ReadMarking.messageLineTag.count)) : id
    }

    /// Splits ids into those an earlier FalconMail can read and the Gmail engine's own.
    public static func split(_ ids: [String]) -> (earlier: [String], gmail: [String]) {
        var earlier: [String] = []
        var gmail: [String] = []
        for id in ids {
            if RowKey(string: messageID(id))?.isGmail == true { gmail.append(id) } else { earlier.append(id) }
        }
        return (earlier, gmail)
    }

    /// Ids of the last session that belonged to accounts now on the Gmail engine: this build does
    /// not show them, so it writes them back as they were, after its own.
    public static func carried(_ previous: [String], engineAccounts: Set<UUID>) -> [String] {
        previous.filter { id in
            guard let key = RowKey(string: messageID(id)), !key.isGmail, let account = key.accountID else { return false }
            return engineAccounts.contains(account)
        }
    }

    /// `current` for the earlier build's list: without Gmail rows, with `previous`' entries of
    /// accounts on the Gmail engine carried forward, and without repeats.
    public static func earlierList(_ current: [String], previous: [String], engineAccounts: Set<UUID>) -> [String] {
        var seen = Set<String>()
        return (split(current).earlier + carried(previous, engineAccounts: engineAccounts)).filter { seen.insert($0).inserted }
    }
}

// MARK: - Drafts' links to Gmail

/// The link between a message being written on this Mac and its Gmail draft (§8.4, §12.2): what
/// Gmail's drafts already know of it, or else the Gmail draft it was reopened from, found by its
/// Gmail id or, for a draft saved over IMAP before the switch, by its Message-ID. Later saves
/// then update that draft rather than adding a second one beside it; when nothing is found the
/// message is saved as a new draft.
public enum GmailDraftLinking {
    /// One Message-ID for every save of a draft, from its id on this Mac.
    public static func stableMessageID(for localID: UUID, email: String) -> String {
        let domain = email.split(separator: "@").last.map(String.init) ?? "falconmail.local"
        return "<draft.\(localID.uuidString.lowercased())@\(domain)>"
    }

    public static func ref(localID: UUID, accountID: UUID, email: String, threadID: GmailThreadID?, reopenedFrom source: MessageSummary?,
                           drafts: GmailDrafts) async -> DraftRef {
        if var known = await drafts.link(localID) {
            if known.threadID == nil { known.threadID = threadID }
            return known
        }
        var ref = DraftRef(localID: localID, accountID: accountID, threadID: threadID ?? source?.gmailThreadID,
                           stableMessageID: stableMessageID(for: localID, email: email))
        guard let source, source.accountID == accountID else { return ref }
        if let gmailID = source.gmailID ?? source.rowKey.gmailID {
            if let draftID = try? await drafts.draftID(forMessage: gmailID) {
                ref.gmailDraftID = draftID
                ref.gmailMessageID = gmailID
            }
        } else if let usable = GmailAccountSearch.usableMessageID(GmailMessageMatcher.header(source.messageID)),
                  let found = try? await drafts.draft(forMessageID: usable) {
            ref.gmailDraftID = found.draftID
            ref.gmailMessageID = found.message
            // The draft keeps the Message-ID it had over IMAP.
            ref.stableMessageID = usable.hasPrefix("<") ? usable : "<\(usable)>"
        }
        return ref
    }
}
