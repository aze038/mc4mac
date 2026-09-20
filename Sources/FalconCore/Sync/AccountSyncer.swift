import Foundation

public enum SyncEvent: Sendable {
    case started(accountID: UUID)
    case progress(accountID: UUID, text: String)
    case folderSynced(folderID: UUID)
    case newMessages(accountID: UUID, folderID: UUID, messages: [MessageSummary])
    case error(accountID: UUID, message: String)
    case actionFailed(accountID: UUID, message: String)
    case online(accountID: UUID, Bool)
    case finished(accountID: UUID)
}

public actor AccountSyncer {
    public let account: AccountInfo
    private let store: MailStore
    private let tokens: TokenStore
    private let rules: RuleStore
    private let mutes: MuteStore
    private let indexer: SpotlightIndexer
    private let pendingActions: PendingActionStore
    private let events: AsyncStream<SyncEvent>.Continuation
    private var syncClient: IMAPClient?
    private var opClient: IMAPClient?
    private var loopTask: Task<Void, Never>?
    private var syncRequested = false
    private var backoff: TimeInterval = 5
    public var initialWindow = 1000
    public var catchUpWindow = 2000
    public var bodyPrefetch = 150
    public var maxOfflineBodyBytes = 5 * 1024 * 1024
    public var bodyPrefetchBudget = 64 * 1024 * 1024
    /// Google allows 2,500 MB of IMAP download per account per day and suspends the account past it.
    /// Eager prefetching stops well below that; opening a message by hand may go a little further.
    public var dailyPrefetchBudget = 900 * 1024 * 1024
    public var dailyHardCeiling = 1_800 * 1024 * 1024
    public var maxEagerPrefetchBytes = 1024 * 1024
    private let meter = BandwidthMeter.shared
    private var budgetNoticeGiven = false
    private var pendingCatchUp = false

    static func isThrottled(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("bandwidth limit") || text.contains("command or bandwidth")
            || text.contains("too many simultaneous") || text.contains("lockdown")
            || text.contains("try again later") || text.contains("bandwidth limits")
    }
    public var undoWindow: TimeInterval = 5
    private let batchSize = 100
    private var held: [UUID: HeldAction] = [:]
    private var suppressedUIDs: [UUID: [UInt32: Int]] = [:]
    private static let staleOperationAge: TimeInterval = 24 * 60 * 60

    private struct HeldAction {
        let record: MailActionRecord
        let pending: PendingServerOperation
        var task: Task<Void, Never>?
    }

    public init(account: AccountInfo, store: MailStore, tokens: TokenStore, rules: RuleStore, mutes: MuteStore,
                indexer: SpotlightIndexer, pendingActions: PendingActionStore, events: AsyncStream<SyncEvent>.Continuation) {
        self.account = account
        self.store = store
        self.tokens = tokens
        self.rules = rules
        self.mutes = mutes
        self.indexer = indexer
        self.pendingActions = pendingActions
        self.events = events
    }

    public func setUndoWindow(_ seconds: TimeInterval) {
        undoWindow = max(0, seconds)
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.loop()
        }
    }

    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
        for action in held.values { action.task?.cancel() }
        held.removeAll()
        suppressedUIDs.removeAll()
        try? await syncClient?.finishIdle()
        await syncClient?.logout()
        await opClient?.logout()
        syncClient = nil
        opClient = nil
    }

    public func requestSync() async {
        syncRequested = true
        try? await syncClient?.finishIdle()
    }

    private func loop() async {
        while !Task.isCancelled {
            do {
                let client = try await connectedSyncClient()
                events.yield(.online(accountID: account.id, true))
                backoff = 5
                await replayPendingOperations()
                try await syncAll(client)
                lastFullSync = Date()
                await meter.persist()
                events.yield(.finished(accountID: account.id))
                if pendingCatchUp {
                    pendingCatchUp = false
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                try await idleLoop(client)
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                Log.info("sync", "\(account.email): \(error.localizedDescription)")
                if AccountSyncer.isThrottled(error) {
                    backoff = max(backoff * 2, 1800)
                    backoff = min(backoff, 7200)
                    let minutes = Int(backoff / 60)
                    events.yield(.error(accountID: account.id,
                                        message: "Google paused mail access for \(account.email) because too much was downloaded at once. Waiting \(minutes) minutes, then continuing on its own."))
                } else {
                    events.yield(.error(accountID: account.id, message: error.localizedDescription))
                    backoff = min(max(backoff * 2, 5), 300)
                }
                events.yield(.online(accountID: account.id, false))
                await syncClient?.logout()
                syncClient = nil
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }

    private func connectedSyncClient() async throws -> IMAPClient {
        if let c = syncClient, await c.isConnected { return c }
        let c = try await makeClient()
        syncClient = c
        return c
    }

    private func connectedOpClient() async throws -> IMAPClient {
        if let c = opClient, await c.isConnected { return c }
        let c = try await makeClient()
        opClient = c
        return c
    }

    private func makeClient() async throws -> IMAPClient {
        let c = IMAPClient(host: account.imapHost, port: account.imapPort)
        try await c.connect()
        if account.usesPassword {
            try await c.login(user: account.loginName, password: try await tokens.password(for: account.id))
        } else {
            let token = try await tokens.validAccessToken(for: account.id)
            try await c.authenticateXOAuth2(user: account.email, accessToken: token)
        }
        return c
    }

    private func syncAll(_ client: IMAPClient) async throws {
        events.yield(.started(accountID: account.id))
        syncRequested = false
        let listed = try await client.listFolders()
        let folders = try await store.reconcileFolders(accountID: account.id, listed: listed)
        for f in folders where f.isSelectable && f.role != .all {
            try Task.checkCancellation()
            events.yield(.progress(accountID: account.id, text: "Checking \(f.name) in \(account.email)"))
            try await syncFolder(f, client: client)
        }
    }

    public var fullSyncInterval: TimeInterval = 5 * 60
    private var lastFullSync = Date()

    private func idleLoop(_ client: IMAPClient) async throws {
        guard let inbox = await store.folder(accountID: account.id, role: .inbox) else { return }
        while !Task.isCancelled {
            _ = try await client.select(inbox.path)
            let wait = max(30, fullSyncInterval - Date().timeIntervalSince(lastFullSync))
            let changed = try await client.idle(maxWait: min(wait, 20 * 60))
            let due = Date().timeIntervalSince(lastFullSync) >= fullSyncInterval
            if syncRequested || due {
                try await syncAll(client)
                lastFullSync = Date()
                events.yield(.finished(accountID: account.id))
            } else if changed, let fresh = await store.folder(inbox.id) {
                try await syncFolder(fresh, client: client)
                events.yield(.finished(accountID: account.id))
            }
        }
    }

    public func syncFolder(_ input: FolderInfo, client: IMAPClient) async throws {
        var folder = input
        let status = try await client.select(folder.path)
        let fs = try await store.folderStore(folder)
        if folder.uidValidity != 0, folder.uidValidity != status.uidValidity {
            try await fs.removeAll()
            folder.lastSyncedUID = 0
            folder.oldestSyncedUID = 0
        }
        folder.uidValidity = status.uidValidity
        folder.uidNext = status.uidNext

        var newMessages: [MessageSummary] = []
        if status.exists > 0 {
            var uids: [UInt32]
            if folder.lastSyncedUID == 0 {
                let all = try await client.uidSearch("ALL")
                uids = Array(all.suffix(initialWindow))
                folder.oldestSyncedUID = uids.first ?? 0
            } else {
                let fresh = try await client.uidSearch("UID \(folder.lastSyncedUID + 1):*").filter { $0 > folder.lastSyncedUID }.sorted()
                if fresh.count > catchUpWindow {
                    uids = Array(fresh.prefix(catchUpWindow))
                    pendingCatchUp = true
                    Log.info("sync", "\(account.email) \(folder.path): \(fresh.count) new messages, taking \(uids.count) this pass")
                } else {
                    uids = fresh
                }
            }
            var start = 0
            while start < uids.count {
                try Task.checkCancellation()
                let batch = Array(uids[start..<min(start + batchSize, uids.count)])
                let envelopes = try await client.fetchEnvelopes(uids: batch)
                var summaries = await AccountSyncer.thread(envelopes.map { AccountSyncer.summary(from: $0, accountID: account.id, folderID: folder.id) }, in: fs)
                summaries.removeAll { isSuppressed(folderID: folder.id, uid: $0.uid) }
                for i in summaries.indices { summaries[i].hasBody = await fs.hasBody(uid: summaries[i].uid) }
                try await fs.upsert(summaries)
                newMessages.append(contentsOf: summaries)
                folder.lastSyncedUID = max(folder.lastSyncedUID, batch.max() ?? 0)
                start += batchSize
                await store.notifyMessagesChanged(folderID: folder.id)
            }
            if folder.oldestSyncedUID == 0 { folder.oldestSyncedUID = uids.first ?? folder.lastSyncedUID }
        }

        if folder.role == .inbox, !newMessages.isEmpty {
            newMessages = await withoutMuted(newMessages, folder: folder, fs: fs, client: client)
        }

        if folder.oldestSyncedUID > 0 {
            let flags = try await client.fetchFlags(uidRange: "\(folder.oldestSyncedUID):*")
            let known = await fs.uids()
            let serverUIDs = Set(flags.map { $0.uid })
            let live = flags.filter { !isSuppressed(folderID: folder.id, uid: $0.uid) }
            let updates = live.map { (uid: $0.uid, flags: MessageFlags(imapFlags: $0.flags)) }
            _ = try await fs.setFlags(updates)
            let gone = known.filter { $0 >= folder.oldestSyncedUID && !serverUIDs.contains($0) }
            if !gone.isEmpty {
                try await fs.remove(uids: Array(gone))
                await indexer.remove(ids: gone.map { MessageSummary.makeID(accountID: account.id, folderID: folder.id, uid: $0) })
            }
        } else if status.exists == 0 {
            let known = await fs.uids()
            if !known.isEmpty { try await fs.remove(uids: Array(known)) }
        }

        folder.lastSyncDate = Date()
        try await store.updateFolder(folder)
        try await store.refreshCounts(folderID: folder.id)
        await store.notifyMessagesChanged(folderID: folder.id)
        events.yield(.folderSynced(folderID: folder.id))

        if !newMessages.isEmpty { await indexer.index(newMessages) }

        try await prefetchBodies(folder: folder, fs: fs, client: client, preferred: newMessages)

        var survivors = newMessages
        if folder.role == .inbox, input.lastSyncedUID > 0, !newMessages.isEmpty {
            let relocated = await applyRules(to: newMessages, folder: folder, fs: fs, client: client)
            survivors.removeAll { relocated.contains($0.uid) }
        }
        if folder.role == .inbox, input.lastSyncedUID > 0, !survivors.isEmpty {
            events.yield(.newMessages(accountID: account.id, folderID: folder.id, messages: survivors))
        }
    }

    private func prefetchBodies(folder: FolderInfo, fs: FolderStore, client: IMAPClient, preferred: [MessageSummary]) async throws {
        guard folder.role == .inbox || preferred.count <= bodyPrefetch else { return }
        let all = await fs.all().sorted { $0.date > $1.date }
        if (try? await fs.pruneBodies(keepingNewest: bodyPrefetch)) ?? 0 > 0 { await store.notifyMessagesChanged(folderID: folder.id) }
        let candidates = all.prefix(bodyPrefetch).filter { !$0.hasBody && $0.size <= min(maxOfflineBodyBytes, maxEagerPrefetchBytes) }
        guard !candidates.isEmpty else { return }
        var texts: [String: String] = [:]
        var updated: [MessageSummary] = []
        var spent = 0
        for m in candidates {
            try Task.checkCancellation()
            guard spent + m.size <= bodyPrefetchBudget else { break }
            guard await meter.allows(m.size, for: account.id, budget: dailyPrefetchBudget) else {
                if !budgetNoticeGiven {
                    budgetNoticeGiven = true
                    let used = await meter.spentToday(account.id) / 1_000_000
                    Log.info("sync", "\(account.email): \(used) MB downloaded today, pausing offline copies until tomorrow")
                    events.yield(.progress(accountID: account.id, text: "\(account.email) has downloaded \(used) MB today; new mail still arrives and messages open on demand"))
                }
                break
            }
            guard let raw = try? await client.fetchMessage(uid: m.uid) else { continue }
            await meter.record(raw.count, for: account.id)
            spent += raw.count
            let parsed = MIMEParser.parse(raw)
            try await fs.storeBody(uid: m.uid, raw: raw, snippet: parsed.snippet, hasAttachments: !parsed.attachments.isEmpty, searchText: parsed.bestText)
            if let s = await fs.message(uid: m.uid) { updated.append(s); texts[s.id] = parsed.bestText }
        }
        await indexer.index(updated, bodies: texts)
        await store.notifyMessagesChanged(folderID: folder.id)
    }

    @discardableResult
    private func applyRules(to messages: [MessageSummary], folder: FolderInfo, fs: FolderStore, client: IMAPClient) async -> Set<UInt32> {
        let defs = await rules.all().filter { $0.isEnabled }
        guard !defs.isEmpty else { return [] }
        var relocated = Set<UInt32>()
        for m in messages {
            let bodyText = await fs.body(uid: m.uid).map { MIMEParser.parse($0).bestText } ?? ""
            let actions = RuleEngine.actions(for: defs, accountID: account.id, subject: RuleSubject(summary: m, body: bodyText))
            var flags = m.flags
            var flagsChanged = false
            var moved = false
            for a in actions {
                do {
                    switch a.kind {
                    case .markRead:
                        try await client.store(uids: [m.uid], add: true, flags: ["\\Seen"])
                        flags.insert(.seen)
                        flagsChanged = true
                    case .flag:
                        try await client.store(uids: [m.uid], add: true, flags: ["\\Flagged"])
                        flags.insert(.flagged)
                        flagsChanged = true
                    case .delete:
                        if let trash = await store.folder(accountID: account.id, role: .trash) {
                            try await client.move(uids: [m.uid], to: trash.path)
                            moved = true
                        }
                    case .archive:
                        try await archiveOnServer(uids: [m.uid], client: client)
                        moved = true
                    case .moveToFolder:
                        if !a.value.isEmpty {
                            try await client.move(uids: [m.uid], to: a.value)
                            moved = true
                        }
                    case .copyToFolder:
                        if !a.value.isEmpty { try await client.copy(uids: [m.uid], to: a.value) }
                    case .stopProcessing: break
                    }
                } catch {
                    events.yield(.error(accountID: account.id, message: "Rule failed: \(error.localizedDescription)"))
                }
                if moved { break }
            }
            if moved {
                relocated.insert(m.uid)
            } else if flagsChanged {
                _ = try? await fs.setFlags([(uid: m.uid, flags: flags)])
            }
        }
        guard !relocated.isEmpty else { return relocated }
        try? await fs.remove(uids: Array(relocated))
        await indexer.remove(ids: relocated.map { MessageSummary.makeID(accountID: account.id, folderID: folder.id, uid: $0) })
        try? await store.refreshCounts(folderID: folder.id)
        await store.notifyMessagesChanged(folderID: folder.id)
        await requestSync()
        return relocated
    }

    private func withoutMuted(_ messages: [MessageSummary], folder: FolderInfo, fs: FolderStore,
                              client: IMAPClient) async -> [MessageSummary] {
        let records = await mutes.all()
        guard !records.isEmpty else { return messages }
        var kept: [MessageSummary] = []
        var muted: [MessageSummary] = []
        for m in messages {
            guard let hit = MuteStore.match(in: records, accountID: account.id, threadKey: m.threadKey, messageID: m.messageID,
                                            references: m.references, inReplyTo: m.inReplyTo) else {
                kept.append(m)
                continue
            }
            muted.append(m)
            await mutes.remember(messageID: m.messageID, accountID: hit.accountID, threadKey: hit.threadKey)
        }
        guard !muted.isEmpty else { return kept }
        let uids = muted.map { $0.uid }
        do {
            try await client.store(uids: uids, add: true, flags: ["\\Seen"])
            try await archiveOnServer(uids: uids, client: client)
            try await fs.remove(uids: uids)
        } catch {
            events.yield(.error(accountID: account.id, message: "Could not file a muted conversation: \(error.localizedDescription)"))
            return messages
        }
        await indexer.remove(ids: muted.map { $0.id })
        await store.notifyMessagesChanged(folderID: folder.id)
        return kept
    }

    private func archiveOnServer(uids: [UInt32], client: IMAPClient) async throws {
        if account.provider == "google", let all = await store.folder(accountID: account.id, role: .all) {
            try await client.move(uids: uids, to: all.path)
        } else if let archive = await store.folder(accountID: account.id, role: .archive) {
            try await client.move(uids: uids, to: archive.path)
        } else {
            try await client.createFolder("Archive")
            try await client.move(uids: uids, to: "Archive")
        }
    }

    static func thread(_ batch: [MessageSummary], in fs: FolderStore) async -> [MessageSummary] {
        let ids = Array(Set(batch.flatMap { $0.references + [$0.inReplyTo, $0.messageID] }.filter { !$0.isEmpty }))
        var known = await fs.threadKeys(for: ids)
        var out: [MessageSummary] = []
        for var s in batch.sorted(by: { $0.date < $1.date }) {
            s.threadKey = ConversationThreader.threadKey(messageID: s.messageID, inReplyTo: s.inReplyTo, references: s.references,
                                                         subject: s.subject) { known[$0] }
            if !s.messageID.isEmpty { known[s.messageID] = s.threadKey }
            out.append(s)
        }
        return out
    }

    static func summary(from e: IMAPMessageEnvelope, accountID: UUID, folderID: UUID) -> MessageSummary {
        let h = MIMEParser.parseHeaders(e.header)
        let ct = ContentType.parse(h.first("Content-Type"))
        let looksAttached = ct.mimeType == "multipart/mixed" || ct.type == "application"
        return MessageSummary(
            accountID: accountID, folderID: folderID, uid: e.uid,
            messageID: AddressParser.messageIDs(h.first("Message-ID")).first ?? "",
            inReplyTo: AddressParser.messageIDs(h.first("In-Reply-To")).first ?? "",
            references: AddressParser.messageIDs(h.first("References")),
            subject: RFC2047.decode(h.first("Subject") ?? ""),
            from: AddressParser.parse(h.first("From")).first ?? EmailAddress(address: ""),
            to: AddressParser.parse(h.first("To")),
            cc: AddressParser.parse(h.first("Cc")),
            date: h.first("Date").flatMap(RFC5322Date.parse) ?? Date(),
            flags: MessageFlags(imapFlags: e.flags),
            size: e.size,
            hasAttachments: looksAttached
        )
    }

    public func body(for message: MessageSummary) async throws -> Data {
        guard let folder = await store.folder(message.folderID) else { throw FalconError.storage("folder missing") }
        let fs = try await store.folderStore(folder)
        if let cached = await fs.body(uid: message.uid) { return cached }
        let client = try await connectedOpClient()
        if await client.selectedMailbox != folder.path { _ = try await client.select(folder.path) }
        guard await meter.allows(message.size, for: account.id, budget: dailyHardCeiling) else {
            throw MigrationErrorShim.overBudget(account.email)
        }
        let raw = try await client.fetchMessage(uid: message.uid)
        await meter.record(raw.count, for: account.id)
        let parsed = MIMEParser.parse(raw)
        try await fs.storeBody(uid: message.uid, raw: raw, snippet: parsed.snippet, hasAttachments: !parsed.attachments.isEmpty, searchText: parsed.bestText)
        if let s = await fs.message(uid: message.uid) { await indexer.index([s], bodies: [s.id: parsed.bestText]) }
        await store.notifyMessagesChanged(folderID: folder.id)
        return raw
    }

    public func parsedMessage(for message: MessageSummary) async throws -> MIMEMessage {
        let raw = try await body(for: message)
        return MIMEParser.parse(raw)
    }

    @discardableResult
    public func setFlag(_ flag: MessageFlags, on messages: [MessageSummary], enabled: Bool,
                        silent: Bool = false) async throws -> [MailActionRecord] {
        var records: [MailActionRecord] = []
        for (folderID, group) in Dictionary(grouping: messages, by: { $0.folderID }) {
            guard let folder = await store.folder(folderID) else { continue }
            let fs = try await store.folderStore(folder)
            var updates: [(uid: UInt32, flags: MessageFlags)] = []
            for m in group {
                var f = m.flags
                if enabled { f.insert(flag) } else { f.remove(flag) }
                updates.append((m.uid, f))
            }
            let pending = PendingServerOperation(accountID: account.id, folderID: folder.id, verb: .store,
                                                 uids: group.map { $0.uid }, uidValidity: folder.uidValidity,
                                                 flagNames: flag.imapFlags, enabled: enabled)
            await pendingActions.add(pending)
            suppress(pending)
            do {
                _ = try await fs.setFlags(updates)
            } catch {
                unsuppress(pending)
                await pendingActions.remove(pending.id)
                throw error
            }
            await store.notifyMessagesChanged(folderID: folderID)
            try? await store.refreshCounts(folderID: folderID)
            let kind = MailActionKind.forFlag(flag, enabled: enabled)
            let record = MailActionRecord(id: pending.id, kind: kind, accountID: account.id, folderID: folder.id,
                                          messages: group, destinationName: "", date: Date(), isAutomatic: silent)
            records.append(record)
            hold(record: record, pending: pending)
        }
        return records
    }

    @discardableResult
    public func move(_ messages: [MessageSummary], to destination: FolderInfo) async throws -> [MailActionRecord] {
        try await move(messages, to: destination, kind: .move)
    }

    private func move(_ messages: [MessageSummary], to destination: FolderInfo, kind: MailActionKind) async throws -> [MailActionRecord] {
        var records: [MailActionRecord] = []
        for (folderID, group) in Dictionary(grouping: messages, by: { $0.folderID }) where folderID != destination.id {
            guard let folder = await store.folder(folderID) else { continue }
            records.append(try await removeLocally(group, in: folder, kind: kind, verb: .move,
                                                   destinationPath: destination.path, destinationName: destination.name))
        }
        return records
    }

    @discardableResult
    public func delete(_ messages: [MessageSummary]) async throws -> [MailActionRecord] {
        guard let trash = await store.folder(accountID: account.id, role: .trash) else {
            throw FalconError.storage("No trash folder on this account")
        }
        let alreadyTrashed = messages.filter { $0.folderID == trash.id }
        let rest = messages.filter { $0.folderID != trash.id }
        var records: [MailActionRecord] = []
        if !rest.isEmpty { records.append(contentsOf: try await move(rest, to: trash, kind: .delete)) }
        if !alreadyTrashed.isEmpty {
            records.append(try await removeLocally(alreadyTrashed, in: trash, kind: .delete, verb: .expunge,
                                                   destinationPath: "", destinationName: trash.name))
        }
        return records
    }

    @discardableResult
    public func purge(_ messages: [MessageSummary]) async throws -> [MailActionRecord] {
        var records: [MailActionRecord] = []
        for (folderID, group) in Dictionary(grouping: messages, by: { $0.folderID }) {
            guard let folder = await store.folder(folderID) else { continue }
            records.append(try await removeLocally(group, in: folder, kind: .delete, verb: .expunge,
                                                   destinationPath: "", destinationName: folder.name))
        }
        return records
    }

    @discardableResult
    public func archive(_ messages: [MessageSummary]) async throws -> [MailActionRecord] {
        let name = await archiveDestinationName()
        var records: [MailActionRecord] = []
        for (folderID, group) in Dictionary(grouping: messages, by: { $0.folderID }) {
            guard let folder = await store.folder(folderID) else { continue }
            records.append(try await removeLocally(group, in: folder, kind: .archive, verb: .archive,
                                                   destinationPath: "", destinationName: name))
        }
        return records
    }

    private func removeLocally(_ group: [MessageSummary], in folder: FolderInfo, kind: MailActionKind,
                               verb: PendingServerVerb, destinationPath: String,
                               destinationName: String) async throws -> MailActionRecord {
        let fs = try await store.folderStore(folder)
        let pending = PendingServerOperation(accountID: account.id, folderID: folder.id, verb: verb,
                                             uids: group.map { $0.uid }, uidValidity: folder.uidValidity,
                                             destinationPath: destinationPath)
        await pendingActions.add(pending)
        suppress(pending)
        do {
            try await fs.remove(uids: pending.uids)
        } catch {
            unsuppress(pending)
            await pendingActions.remove(pending.id)
            throw error
        }
        await indexer.remove(ids: group.map { $0.id })
        await store.notifyMessagesChanged(folderID: folder.id)
        try? await store.refreshCounts(folderID: folder.id)
        let record = MailActionRecord(id: pending.id, kind: kind, accountID: account.id, folderID: folder.id,
                                      messages: group, destinationName: destinationName, date: Date())
        hold(record: record, pending: pending)
        return record
    }

    private func hold(record: MailActionRecord, pending: PendingServerOperation) {
        held[record.id] = HeldAction(record: record, pending: pending, task: nil)
        let nanoseconds = UInt64(max(0, undoWindow) * 1_000_000_000)
        held[record.id]?.task = Task { [weak self] in
            _ = try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.commit(record.id)
        }
    }

    private func commit(_ id: UUID) async {
        guard let action = held.removeValue(forKey: id) else { return }
        do {
            try await run(action.pending)
            unsuppress(action.pending)
            await pendingActions.remove(action.pending.id)
            if action.pending.verb == .move { await requestSync() }
        } catch {
            unsuppress(action.pending)
            await pendingActions.remove(action.pending.id)
            guard !action.record.isAutomatic else { return }
            await restore(action.record)
            events.yield(.actionFailed(accountID: account.id,
                                       message: "\(action.record.failurePrefix): \(error.localizedDescription) Restored."))
        }
    }

    public func undo(_ recordID: UUID) async -> Bool {
        guard let action = held.removeValue(forKey: recordID) else { return false }
        action.task?.cancel()
        unsuppress(action.pending)
        await restore(action.record)
        await pendingActions.remove(action.pending.id)
        return true
    }

    public func flushPending() async {
        for id in Array(held.keys) {
            held[id]?.task?.cancel()
            await commit(id)
        }
    }

    private func run(_ pending: PendingServerOperation) async throws {
        guard let folder = await store.folder(pending.folderID) else { return }
        guard pending.appliesTo(folder) else {
            throw FalconError.storage("The mailbox was rebuilt on the server, so that action no longer applies")
        }
        let client = try await connectedOpClient()
        if await client.selectedMailbox != folder.path { _ = try await client.select(folder.path) }
        switch pending.verb {
        case .archive:
            try await archiveOnServer(uids: pending.uids, client: client)
        case .move:
            try await client.move(uids: pending.uids, to: pending.destinationPath)
        case .expunge:
            try await client.store(uids: pending.uids, add: true, flags: ["\\Deleted"])
            try await client.expunge()
        case .store:
            try await client.store(uids: pending.uids, add: pending.enabled, flags: pending.flagNames)
        }
    }

    private func restore(_ record: MailActionRecord) async {
        guard let folder = await store.folder(record.folderID), let fs = try? await store.folderStore(folder) else { return }
        switch record.kind {
        case .flag, .unflag, .read, .unread:
            let previous: [(uid: UInt32, flags: MessageFlags)] = record.messages.map { (uid: $0.uid, flags: $0.flags) }
            _ = try? await fs.setFlags(previous)
        case .archive, .delete, .move:
            var rows = record.messages
            for i in rows.indices { rows[i].hasBody = false }
            try? await fs.upsert(rows)
            await indexer.index(rows)
        }
        await store.notifyMessagesChanged(folderID: folder.id)
        try? await store.refreshCounts(folderID: folder.id)
    }

    private func replayPendingOperations() async {
        let stored = await pendingActions.all()
        for pending in stored where pending.accountID == account.id && held[pending.id] == nil {
            if await mailboxWasRebuilt(pending) {
                await pendingActions.remove(pending.id)
                continue
            }
            if Date().timeIntervalSince(pending.date) > AccountSyncer.staleOperationAge {
                await pendingActions.remove(pending.id)
                await restoreRows(for: pending)
                continue
            }
            do {
                try await run(pending)
                await pendingActions.remove(pending.id)
            } catch {
                events.yield(.actionFailed(accountID: account.id,
                                           message: "Could not finish an action from the last session: \(error.localizedDescription)"))
            }
        }
    }

    private func mailboxWasRebuilt(_ pending: PendingServerOperation) async -> Bool {
        guard let folder = await store.folder(pending.folderID) else { return true }
        return !pending.appliesTo(folder)
    }

    private func restoreRows(for pending: PendingServerOperation) async {
        guard pending.verb != .store, !pending.uids.isEmpty else { return }
        guard let folder = await store.folder(pending.folderID), let fs = try? await store.folderStore(folder) else { return }
        do {
            let client = try await connectedOpClient()
            if await client.selectedMailbox != folder.path { _ = try await client.select(folder.path) }
            let envelopes = try await client.fetchEnvelopes(uids: pending.uids)
            guard !envelopes.isEmpty else { return }
            let rows = envelopes.map { AccountSyncer.summary(from: $0, accountID: account.id, folderID: folder.id) }
            let summaries = await AccountSyncer.thread(rows, in: fs)
            try await fs.upsert(summaries)
            await indexer.index(summaries)
            try await store.refreshCounts(folderID: folder.id)
            await store.notifyMessagesChanged(folderID: folder.id)
        } catch {
            events.yield(.error(accountID: account.id, message: error.localizedDescription))
        }
    }

    private func suppress(_ pending: PendingServerOperation) {
        for uid in pending.uids { suppressedUIDs[pending.folderID, default: [:]][uid, default: 0] += 1 }
    }

    private func unsuppress(_ pending: PendingServerOperation) {
        guard var counts = suppressedUIDs[pending.folderID] else { return }
        for uid in pending.uids {
            guard let remaining = counts[uid] else { continue }
            if remaining <= 1 { counts[uid] = nil } else { counts[uid] = remaining - 1 }
        }
        suppressedUIDs[pending.folderID] = counts.isEmpty ? nil : counts
    }

    private func isSuppressed(folderID: UUID, uid: UInt32) -> Bool {
        (suppressedUIDs[folderID]?[uid] ?? 0) > 0
    }

    private func archiveDestinationName() async -> String {
        if account.provider == "google", let all = await store.folder(accountID: account.id, role: .all) { return all.name }
        if let archive = await store.folder(accountID: account.id, role: .archive) { return archive.name }
        return "Archive"
    }

    public func append(raw: Data, to folder: FolderInfo, flags: MessageFlags, date: Date?) async throws {
        let client = try await connectedOpClient()
        try await client.append(mailbox: folder.path, message: raw, flags: flags.imapFlags, date: date)
        await requestSync()
    }

    public func loadOlder(folder input: FolderInfo, count: Int = 1000) async throws {
        var folder = input
        guard folder.oldestSyncedUID > 1 else { return }
        let client = try await connectedOpClient()
        _ = try await client.select(folder.path)
        let uids = try await client.uidSearch("UID 1:\(folder.oldestSyncedUID - 1)")
        let window = Array(uids.suffix(count))
        guard !window.isEmpty else { return }
        let fs = try await store.folderStore(folder)
        var start = 0
        while start < window.count {
            let batch = Array(window[start..<min(start + batchSize, window.count)])
            let envelopes = try await client.fetchEnvelopes(uids: batch)
            var summaries = await AccountSyncer.thread(envelopes.map { AccountSyncer.summary(from: $0, accountID: account.id, folderID: folder.id) }, in: fs)
            summaries.removeAll { isSuppressed(folderID: folder.id, uid: $0.uid) }
            try await fs.upsert(summaries)
            await indexer.index(summaries)
            start += batchSize
        }
        folder.oldestSyncedUID = window.first ?? folder.oldestSyncedUID
        try await store.updateFolder(folder)
        try await store.refreshCounts(folderID: folder.id)
        await store.notifyMessagesChanged(folderID: folder.id)
    }

    public func setBodyPrefetch(_ count: Int, maxBytes: Int? = nil) {
        bodyPrefetch = count
        if let maxBytes { maxOfflineBodyBytes = maxBytes }
    }

    public func runRulesOnInbox() async throws {
        guard let inbox = await store.folder(accountID: account.id, role: .inbox) else { return }
        let fs = try await store.folderStore(inbox)
        let client = try await connectedOpClient()
        _ = try await client.select(inbox.path)
        let all = await fs.all()
        await applyRules(to: all, folder: inbox, fs: fs, client: client)
        await requestSync()
    }

    public func openArchiveSourceClient() async throws -> IMAPClient {
        try await makeClient()
    }
}


enum MigrationErrorShim {
    static func overBudget(_ email: String) -> FalconError {
        .network("\(email) has reached today's safe download limit. Mail already on this Mac stays available, and downloading resumes tomorrow.")
    }
}
