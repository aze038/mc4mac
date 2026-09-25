import Foundation

// Every entry point that acts on an account, routed by its engine (§7.7): a Google account on the
// Gmail API through its Gmail engine alone, every other account through the IMAP engine. An
// account with neither running is told plainly, and never skipped in silence.

/// What a new-mail notification's buttons do.
public enum MailNotificationVerb: String, Sendable, CaseIterable {
    case archive, delete, markRead, flag

    public var actionVerb: MailActionRequest.Verb {
        switch self {
        case .archive: return .archive
        case .delete: return .delete
        case .markRead: return .markRead
        case .flag: return .flag
        }
    }
}

/// Where a notification's message is, on a Google account on the Gmail API: the account's Inbox,
/// which new mail is announced from, and whether the message is still there.
public struct GmailNotificationTarget: Sendable {
    public var accountID: UUID
    public var key: RowKey
    public var inbox: FolderInfo
    public var view: ListView
    public var availability: RowAvailability
}

extension SyncCoordinator {
    private func running(_ accountID: UUID, _ what: String) async throws -> GmailAccountAssembly {
        if let assembly = assembly(for: accountID) { return assembly }
        let email = await store.account(accountID)?.email ?? "This account"
        throw GmailEngineUnavailable(email: email, what: what)
    }

    // MARK: - Actions

    /// A change to messages of a Google account on the Gmail API, shown at once and held for the
    /// undo window before it goes to Gmail.
    public func perform(_ request: MailActionRequest, accountID: UUID) async throws -> ActionReceipt {
        let assembly = try await running(accountID, "this")
        return try await assembly.engine.perform(request)
    }

    public func undo(_ receiptID: UUID, accountID: UUID) async -> Bool {
        guard let assembly = assembly(for: accountID) else { return false }
        return await assembly.engine.undo(receiptID)
    }

    /// New Folder: `labels.create` on the Gmail API, `CREATE` over IMAP for every other account.
    /// Returns the new folder as the sidebar shows it, for the Gmail engine.
    @discardableResult
    public func createFolder(named name: String, in account: AccountInfo) async throws -> FolderInfo? {
        if usesGmail(account.id) {
            return try await running(account.id, "New Folder").engine.createFolder(named: name, parent: nil)
        }
        guard let syncer = syncer(for: account.id) else { throw GmailEngineUnavailable(email: account.email, what: "New Folder") }
        try await syncer.createMailbox(named: name)
        return nil
    }

    /// Run Rules Now on the account's Inbox: the mail kept on the Mac for the Gmail engine.
    public func runRulesOnInbox(_ account: AccountInfo) async throws {
        if usesGmail(account.id) {
            try await running(account.id, "rules").engine.runRulesOnInbox()
            return
        }
        guard let syncer = syncer(for: account.id) else { return }
        try await syncer.runRulesOnInbox()
    }

    // MARK: - Imports and the archive job

    /// Imports .eml and .mbox files into a folder: with `messages.import` for a Google account on
    /// the Gmail API, each message placed from Gmail's answer; over IMAP for every other account.
    public func importFiles(_ urls: [URL], into folder: FolderInfo,
                            progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> FileImport.Outcome {
        if usesGmail(folder.accountID) {
            var outcome = FileImport.Outcome()
            do {
                let assembly = try await running(folder.accountID, "imports")
                let label = folder.role == .all ? nil : folder.gmailLabelID
                let done = try await assembly.importer.run(files: urls, into: label) { step in
                    if case .imported(let count, _) = step { progress(count) }
                }
                outcome.imported = done.imported
                outcome.failures = done.failures.map { GmailImportFailed(failure: $0) }
            } catch {
                outcome.failures.append(error)
            }
            return outcome
        }
        guard let syncer = syncer(for: folder.accountID) else {
            var outcome = FileImport.Outcome()
            outcome.failures.append(GmailEngineUnavailable(email: await store.account(folder.accountID)?.email ?? "This account",
                                                           what: "imports"))
            return outcome
        }
        return await FileImport.run(urls, into: folder, syncer: syncer)
    }

    /// Where the archive job reads the account's mail from: its Gmail labels through the Gmail
    /// API for a Google account on it, its IMAP folders otherwise.
    public func archiveSource(for account: AccountInfo) async throws -> any ArchiveMailSource {
        if usesGmail(account.id) {
            let assembly = try await running(account.id, "the archive")
            var labels: [String: GmailLabelID?] = [:]
            for folder in await assembly.engine.folders() where folder.isSelectable {
                labels[folder.path] = folder.role == .all ? .some(nil) : folder.gmailLabelID
            }
            return GmailArchiveSource(transport: assembly.transport, folders: labels)
        }
        guard let syncer = syncer(for: account.id) else { throw GmailEngineUnavailable(email: account.email, what: "the archive") }
        return syncer.archiveSource()
    }

    // MARK: - Notifications

    /// A notification's message on a Google account on the Gmail API, found through its engine's
    /// list in the account's Inbox. Nil for a message of any other account, which the stored rows
    /// answer, or when its account's engine is not running.
    public func notificationTarget(messageID: String) async -> GmailNotificationTarget? {
        guard let key = RowKey(string: messageID), key.isGmail, let accountID = key.accountID,
              let assembly = assembly(for: accountID),
              let inbox = await assembly.engine.folders().first(where: { $0.role == .inbox }) else { return nil }
        let view = ListView(scope: .folder(inbox.id), conversations: false)
        let availability = await assembly.list.summary(for: key, in: view)
        return GmailNotificationTarget(accountID: accountID, key: key, inbox: inbox, view: view, availability: availability)
    }

    /// A notification's button on a message of a Google account on the Gmail API: the change goes
    /// through the Gmail engine, as if made in the Inbox, and can be undone as any other.
    public func actOnNotification(_ verb: MailNotificationVerb, messageID: String) async throws -> ActionReceipt? {
        guard let target = await notificationTarget(messageID: messageID) else { return nil }
        switch target.availability {
        case .gone:
            throw GmailMessageGone()
        case .unavailable(let reason):
            throw GmailMessageUnavailable(reason: reason)
        case .available:
            let request = MailActionRequest(verb: verb.actionVerb, targets: .items([.message(target.key)]), context: target.view)
            return try await perform(request, accountID: target.accountID)
        }
    }

    // MARK: - Search

    /// Searches every Google account on the Gmail API among `accounts` on Gmail, the hits showing
    /// as the view `.search(id)`: while the owner types, ids only (5 units); with `fetchRows`, the
    /// text of the first hits not known yet too. Returns the accounts searched.
    @discardableResult
    public func search(_ query: String, id: UUID, accounts: Set<UUID>, fetchRows: Bool) async -> Set<UUID> {
        var searched = Set<UUID>()
        for accountID in accounts {
            guard let assembly = assembly(for: accountID) else { continue }
            searched.insert(accountID)
            do {
                try await assembly.engine.search(query, id: id, fetchRows: fetchRows)
            } catch {
                Log.info("search", "\(assembly.engine.account.email): the Gmail search stopped: \(error.localizedDescription)")
            }
        }
        return searched
    }

    public func endSearch(_ id: UUID, accounts: Set<UUID>) async {
        for accountID in accounts {
            await assembly(for: accountID)?.engine.endSearch(id)
        }
    }
}

/// Gmail answered that the message is gone.
public struct GmailMessageGone: Error, LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? { "This message was moved or deleted on another device." }
}

/// The message cannot be reached now, as while offline; it is still there.
public struct GmailMessageUnavailable: Error, LocalizedError, Equatable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// One message or file an import on the Gmail API could not bring in, in the sentence to show.
public struct GmailImportFailed: Error, LocalizedError, Equatable {
    public var failure: GmailImportFailure
    public init(failure: GmailImportFailure) { self.failure = failure }
    public var errorDescription: String? { failure.sentence }
}
