import Foundation

public enum SyncEvent: Sendable {
    case started(accountID: UUID)
    case progress(accountID: UUID, text: String)
    case folderSynced(folderID: UUID)
    case newMessages(accountID: UUID, folderID: UUID, messages: [MessageSummary])
    case error(accountID: UUID, message: String)
    case online(accountID: UUID, Bool)
    case finished(accountID: UUID)
}

public actor AccountSyncer {
    public let account: AccountInfo
    private let store: MailStore
    private let tokens: TokenStore
    private let rules: RuleStore
    private let indexer: SpotlightIndexer
    private let events: AsyncStream<SyncEvent>.Continuation
    private var syncClient: IMAPClient?
    private var opClient: IMAPClient?
    private var loopTask: Task<Void, Never>?
    private var syncRequested = false
    private var backoff: TimeInterval = 5
    public var initialWindow = 1000
    public var bodyPrefetch = 150
    public var maxOfflineBodyBytes = 5 * 1024 * 1024
    private let batchSize = 100

    public init(account: AccountInfo, store: MailStore, tokens: TokenStore, rules: RuleStore, indexer: SpotlightIndexer,
                events: AsyncStream<SyncEvent>.Continuation) {
        self.account = account
        self.store = store
        self.tokens = tokens
        self.rules = rules
        self.indexer = indexer
        self.events = events
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
                try await syncAll(client)
                events.yield(.finished(accountID: account.id))
                try await idleLoop(client)
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                events.yield(.error(accountID: account.id, message: error.localizedDescription))
                events.yield(.online(accountID: account.id, false))
                await syncClient?.logout()
                syncClient = nil
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 300)
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
            events.yield(.progress(accountID: account.id, text: "Syncing \(f.name)"))
            try await syncFolder(f, client: client)
        }
    }

    private func idleLoop(_ client: IMAPClient) async throws {
        guard let inbox = await store.folder(accountID: account.id, role: .inbox) else { return }
        while !Task.isCancelled {
            _ = try await client.select(inbox.path)
            let changed = try await client.idle(maxWait: 25 * 60)
            if changed || syncRequested {
                if syncRequested {
                    try await syncAll(client)
                } else if let fresh = await store.folder(inbox.id) {
                    try await syncFolder(fresh, client: client)
                }
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
                uids = try await client.uidSearch("UID \(folder.lastSyncedUID + 1):*").filter { $0 > folder.lastSyncedUID }
            }
            var start = 0
            while start < uids.count {
                try Task.checkCancellation()
                let batch = Array(uids[start..<min(start + batchSize, uids.count)])
                let envelopes = try await client.fetchEnvelopes(uids: batch)
                var summaries = await AccountSyncer.thread(envelopes.map { AccountSyncer.summary(from: $0, accountID: account.id, folderID: folder.id) }, in: fs)
                for i in summaries.indices { summaries[i].hasBody = await fs.hasBody(uid: summaries[i].uid) }
                try await fs.upsert(summaries)
                newMessages.append(contentsOf: summaries)
                folder.lastSyncedUID = max(folder.lastSyncedUID, batch.max() ?? 0)
                start += batchSize
                await store.notifyMessagesChanged(folderID: folder.id)
            }
            if folder.oldestSyncedUID == 0 { folder.oldestSyncedUID = uids.first ?? folder.lastSyncedUID }
        }

        if folder.oldestSyncedUID > 0 {
            let flags = try await client.fetchFlags(uidRange: "\(folder.oldestSyncedUID):*")
            let known = await fs.uids()
            let serverUIDs = Set(flags.map { $0.uid })
            let updates = flags.map { (uid: $0.uid, flags: MessageFlags(imapFlags: $0.flags)) }
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

        if !newMessages.isEmpty {
            await indexer.index(newMessages)
            if folder.role == .inbox, input.lastSyncedUID > 0 {
                events.yield(.newMessages(accountID: account.id, folderID: folder.id, messages: newMessages))
            }
        }

        try await prefetchBodies(folder: folder, fs: fs, client: client, preferred: newMessages)
        if folder.role == .inbox, input.lastSyncedUID > 0, !newMessages.isEmpty {
            await applyRules(to: newMessages, folder: folder, fs: fs, client: client)
        }
    }

    private func prefetchBodies(folder: FolderInfo, fs: FolderStore, client: IMAPClient, preferred: [MessageSummary]) async throws {
        let all = await fs.all().sorted { $0.date > $1.date }
        if (try? await fs.pruneBodies(keepingNewest: bodyPrefetch)) ?? 0 > 0 { await store.notifyMessagesChanged(folderID: folder.id) }
        let candidates = all.prefix(bodyPrefetch).filter { !$0.hasBody && $0.size <= maxOfflineBodyBytes }
        guard !candidates.isEmpty else { return }
        var texts: [String: String] = [:]
        var updated: [MessageSummary] = []
        for m in candidates {
            try Task.checkCancellation()
            guard let raw = try? await client.fetchMessage(uid: m.uid) else { continue }
            let parsed = MIMEParser.parse(raw)
            try await fs.storeBody(uid: m.uid, raw: raw, snippet: parsed.snippet, hasAttachments: !parsed.attachments.isEmpty, searchText: parsed.bestText)
            if let s = await fs.message(uid: m.uid) { updated.append(s); texts[s.id] = parsed.bestText }
        }
        await indexer.index(updated, bodies: texts)
        await store.notifyMessagesChanged(folderID: folder.id)
    }

    private func applyRules(to messages: [MessageSummary], folder: FolderInfo, fs: FolderStore, client: IMAPClient) async {
        let defs = await rules.all().filter { $0.isEnabled }
        guard !defs.isEmpty else { return }
        for m in messages {
            let bodyText = await fs.body(uid: m.uid).map { MIMEParser.parse($0).bestText } ?? ""
            let actions = RuleEngine.actions(for: defs, accountID: account.id, subject: RuleSubject(summary: m, body: bodyText))
            for a in actions {
                do {
                    switch a.kind {
                    case .markRead: try await client.store(uids: [m.uid], add: true, flags: ["\\Seen"])
                    case .flag: try await client.store(uids: [m.uid], add: true, flags: ["\\Flagged"])
                    case .delete:
                        if let trash = await store.folder(accountID: account.id, role: .trash) { try await client.move(uids: [m.uid], to: trash.path) }
                    case .archive:
                        try await archiveOnServer(uids: [m.uid], client: client)
                    case .moveToFolder:
                        if !a.value.isEmpty { try await client.move(uids: [m.uid], to: a.value) }
                    case .copyToFolder:
                        if !a.value.isEmpty { try await client.copy(uids: [m.uid], to: a.value) }
                    case .stopProcessing: break
                    }
                } catch {
                    events.yield(.error(accountID: account.id, message: "Rule failed: \(error.localizedDescription)"))
                }
            }
        }
        if let fresh = await store.folder(folder.id), !messages.isEmpty, client === syncClient {
            try? await syncFolder(fresh, client: client)
        }
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
        let raw = try await client.fetchMessage(uid: message.uid)
        let parsed = MIMEParser.parse(raw)
        try await fs.storeBody(uid: message.uid, raw: raw, snippet: parsed.snippet, hasAttachments: !parsed.attachments.isEmpty, searchText: parsed.bestText)
        if let s = await fs.message(uid: message.uid) { await indexer.index([s], bodies: [s.id: parsed.bestText]) }
        await store.notifyMessagesChanged(folderID: folder.id)
        return raw
    }

    public func setFlag(_ flag: MessageFlags, on messages: [MessageSummary], enabled: Bool) async throws {
        for (folderID, group) in Dictionary(grouping: messages, by: { $0.folderID }) {
            guard let folder = await store.folder(folderID) else { continue }
            let fs = try await store.folderStore(folder)
            var updates: [(uid: UInt32, flags: MessageFlags)] = []
            for m in group {
                var f = m.flags
                if enabled { f.insert(flag) } else { f.remove(flag) }
                updates.append((m.uid, f))
            }
            _ = try await fs.setFlags(updates)
            await store.notifyMessagesChanged(folderID: folderID)
            try await store.refreshCounts(folderID: folderID)
            let client = try await connectedOpClient()
            if await client.selectedMailbox != folder.path { _ = try await client.select(folder.path) }
            try await client.store(uids: group.map { $0.uid }, add: enabled, flags: flag.imapFlags)
        }
    }

    public func move(_ messages: [MessageSummary], to destination: FolderInfo) async throws {
        for (folderID, group) in Dictionary(grouping: messages, by: { $0.folderID }) where folderID != destination.id {
            guard let folder = await store.folder(folderID) else { continue }
            let fs = try await store.folderStore(folder)
            let client = try await connectedOpClient()
            if await client.selectedMailbox != folder.path { _ = try await client.select(folder.path) }
            try await client.move(uids: group.map { $0.uid }, to: destination.path)
            try await fs.remove(uids: group.map { $0.uid })
            await indexer.remove(ids: group.map { $0.id })
            await store.notifyMessagesChanged(folderID: folderID)
            try await store.refreshCounts(folderID: folderID)
        }
        await requestSync()
    }

    public func delete(_ messages: [MessageSummary]) async throws {
        guard let trash = await store.folder(accountID: account.id, role: .trash) else {
            throw FalconError.storage("No trash folder on this account")
        }
        let alreadyTrashed = messages.filter { $0.folderID == trash.id }
        let rest = messages.filter { $0.folderID != trash.id }
        if !rest.isEmpty { try await move(rest, to: trash) }
        if !alreadyTrashed.isEmpty {
            let fs = try await store.folderStore(trash)
            let client = try await connectedOpClient()
            if await client.selectedMailbox != trash.path { _ = try await client.select(trash.path) }
            try await client.store(uids: alreadyTrashed.map { $0.uid }, add: true, flags: ["\\Deleted"])
            try await client.expunge()
            try await fs.remove(uids: alreadyTrashed.map { $0.uid })
            await store.notifyMessagesChanged(folderID: trash.id)
            try await store.refreshCounts(folderID: trash.id)
        }
    }

    public func archive(_ messages: [MessageSummary]) async throws {
        for (folderID, group) in Dictionary(grouping: messages, by: { $0.folderID }) {
            guard let folder = await store.folder(folderID) else { continue }
            let fs = try await store.folderStore(folder)
            let client = try await connectedOpClient()
            if await client.selectedMailbox != folder.path { _ = try await client.select(folder.path) }
            try await archiveOnServer(uids: group.map { $0.uid }, client: client)
            try await fs.remove(uids: group.map { $0.uid })
            await indexer.remove(ids: group.map { $0.id })
            await store.notifyMessagesChanged(folderID: folderID)
            try await store.refreshCounts(folderID: folderID)
        }
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
            let summaries = await AccountSyncer.thread(envelopes.map { AccountSyncer.summary(from: $0, accountID: account.id, folderID: folder.id) }, in: fs)
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
