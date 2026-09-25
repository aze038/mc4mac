import Foundation

/// A switched Google account's drafts on Gmail, behind the owner's rule of 25 September:
/// closing a message saves it to Drafts, and Discard throws it away, with Undo (§8.4).
///
/// Three rules keep a draft's text safe and single:
/// 1. **The copy on the Mac goes only once Gmail has the draft.** `save` returns only then; it
///    throws `GmailDraftDeferred` while Gmail cannot be reached, and the draft waits here as a
///    provisional row in Drafts until Gmail takes it. Gmail's draft id is written down before
///    `save` returns, so a draft left over at launch updates that draft instead of adding one.
/// 2. **Discard deletes Gmail's copy only after the undo window.** A marker in `drafts.json`
///    stands for it meanwhile, so a quit during the window finishes the delete at quit or at
///    the next launch, and never saves the message back to Drafts. Undo keeps the link to
///    Gmail's copy.
/// 3. **A save never makes a second draft.** Every save carries the draft's one Message-ID and
///    an `X-FalconMail-Draft` header. One save per draft is in flight at a time, and a newer one
///    waits, the latest content winning. A create whose answer never came is looked for in the
///    history before another is made.
public actor GmailDrafts {
    public nonisolated let accountID: UUID
    public nonisolated let email: String
    private let transport: any GmailTransport
    private let placer: (any GmailUploadPlacing)?
    private let file: URL
    private let cursor: @Sendable () async -> HistoryID?
    private let now: @Sendable () -> Date
    private let autosaveInterval: TimeInterval
    private let retryInterval: TimeInterval

    private var state: GmailDraftsState
    /// False when `drafts.json` is there but could not be read: it is left as it is.
    private let canSave: Bool
    /// The draft message ids Gmail lists may be out of date, as after Drafts changed elsewhere.
    private var mapStale = true

    private var queued: [UUID: QueuedSave] = [:]
    private var working: [UUID: Task<Void, Never>] = [:]
    /// Saves Gmail could not take yet, tried again by themselves. The copy on the Mac is the
    /// app's, which keeps it until `events` says the save went.
    private var waiting: [UUID: QueuedSave] = [:]
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval
    private var discardTimers: [UUID: Task<Void, Never>] = [:]
    /// Drafts whose Gmail copy an automatic save of this session made, which a quiet close
    /// deletes again.
    private var autosavedThisSession: Set<UUID> = []
    private var lastAttempt: [UUID: Date] = [:]
    private var listeners: [UUID: AsyncStream<GmailDraftEvent>.Continuation] = [:]

    public static let draftHeader = "X-FalconMail-Draft"
    /// A link to a draft closed this long ago goes: a draft left over after a crash is saved
    /// again at the next launch, well within it.
    static let closedLinksKept: TimeInterval = 7 * 24 * 3600
    static let unclosedLinksKept: TimeInterval = 30 * 24 * 3600

    /// - Parameters:
    ///   - file: `drafts.json` in the account's Gmail folder.
    ///   - cursor: the engine's position in the history, where a create's echo is looked for.
    ///   - autosaveInterval: automatic saves come at most this often per draft (open question 14).
    ///   - retryInterval: the first wait before a save Gmail could not take is tried again.
    public init(accountID: UUID, email: String, transport: any GmailTransport, placer: (any GmailUploadPlacing)? = nil,
                file: URL, cursor: @escaping @Sendable () async -> HistoryID?,
                now: @escaping @Sendable () -> Date = { Date() }, autosaveInterval: TimeInterval = 60,
                retryInterval: TimeInterval = 30) {
        self.accountID = accountID
        self.email = email
        self.transport = transport
        self.placer = placer
        self.file = file
        self.cursor = cursor
        self.now = now
        self.autosaveInterval = autosaveInterval
        self.retryInterval = retryInterval
        self.retryDelay = retryInterval
        let stored = AtomicFile.loadJSON(GmailDraftsState.self, from: file, what: "the list of Gmail drafts")
        var loaded = stored.value ?? GmailDraftsState()
        let cutoff = now()
        loaded.links = loaded.links.filter { key, link in
            if loaded.discarded[key] != nil { return true }
            if let closed = link.closedAt { return cutoff.timeIntervalSince(closed) < GmailDrafts.closedLinksKept }
            return cutoff.timeIntervalSince(link.lastSaved ?? cutoff) < GmailDrafts.unclosedLinksKept
        }
        state = loaded
        canSave = stored.canSave
    }

    /// Carries on from the last session: a discard whose undo window ended while FalconMail was
    /// not running is finished now, and the others when their windows end.
    public func start() async {
        for (key, marker) in state.discarded {
            guard let localID = UUID(uuidString: key) else { continue }
            scheduleDiscard(localID, at: marker.deleteAt)
        }
    }

    public init(files: GmailFiles, accountID: UUID, email: String, transport: any GmailTransport,
                            placer: (any GmailUploadPlacing)? = nil, cursor: @escaping @Sendable () async -> HistoryID?) {
        self.init(accountID: accountID, email: email, transport: transport, placer: placer, file: files.drafts, cursor: cursor)
    }

    // MARK: - Saving

    /// Saves the draft to Gmail: created the first time, updated after, always the same draft.
    /// The copy on the Mac may be deleted only once this returns (rule 1). `bcc` goes into
    /// Gmail's copy only, since the .eml the app builds has none.
    ///
    /// Throws `GmailDraftDeferred` when Gmail cannot take it now: the draft then shows in Drafts
    /// as provisional and goes to Gmail by itself, and `events` says when. Throws
    /// `GmailDraftRefused` when Gmail refused it, and `GmailDraftDiscarded` for a draft that was
    /// discarded, which is never saved back.
    @discardableResult
    public func save(_ raw: Data, as ref: DraftRef, bcc: [EmailAddress] = [], reason: DraftSaveReason = .close) async throws -> DraftRef {
        guard state.discarded[ref.localID.uuidString] == nil else { throw GmailDraftDiscarded() }
        lastAttempt[ref.localID] = now()
        return try await withCheckedThrowingContinuation { continuation in
            enqueue(QueuedSave(raw: raw, ref: ref, bcc: bcc, reason: reason), waiter: continuation)
        }
    }

    /// The automatic save while the owner writes, only on the Gmail engine: at most once per
    /// `autosaveInterval` for each draft, and never beside a save already on its way. Nil when
    /// it was not made; the next one, or closing, brings the latest content.
    public func autosave(_ raw: Data, as ref: DraftRef, bcc: [EmailAddress] = []) async throws -> DraftRef? {
        if let last = lastAttempt[ref.localID], now().timeIntervalSince(last) < autosaveInterval { return nil }
        if working[ref.localID] != nil || state.discarded[ref.localID.uuidString] != nil { return nil }
        return try await save(raw, as: ref, bcc: bcc, reason: .autosave)
    }

    /// A message closed untouched since it opened, or blank: nothing is saved, as before. If an
    /// automatic save of this session made a Gmail draft for it, that draft is deleted again,
    /// so no stray copy stays in Drafts.
    public func closeWithoutSaving(_ ref: DraftRef) async {
        let localID = ref.localID
        dropQueued(localID)
        await settle(localID)
        waiting[localID] = nil
        state.provisional[localID.uuidString] = nil
        let link = state.links[localID.uuidString]
        if autosavedThisSession.remove(localID) != nil, let draftID = link?.ref.gmailDraftID {
            do {
                try await deleteOnGmail(draftID, message: link?.ref.gmailMessageID)
            } catch {
                // Offline: the delete is finished later, as a discard whose window is over.
                state.discarded[localID.uuidString] = GmailDiscardMarker(ref: link?.ref ?? ref, deleteAt: now())
                persist()
                scheduleRetry()
                emitProvisional()
                return
            }
        }
        state.links[localID.uuidString] = nil
        persist()
        emitProvisional()
    }

    /// The message goes to the Outbox: any save on its way is let finish, later ones are
    /// dropped, and the link to Gmail's draft is returned for the Outbox item, which deletes
    /// the draft once the send is confirmed.
    public func handOver(_ localID: UUID) async -> DraftRef? {
        dropQueued(localID)
        await settle(localID)
        waiting[localID] = nil
        state.provisional[localID.uuidString] = nil
        var link = state.links[localID.uuidString]
        link?.closedAt = now()
        state.links[localID.uuidString] = link
        persist()
        emitProvisional()
        return link?.ref
    }

    // MARK: - Discard, with Undo

    /// Discard: the window has closed, and Gmail's copy is deleted when `undoWindow` ends. The
    /// marker is on disk before this returns, so a quit meanwhile finishes the delete at quit
    /// or at the next launch and never saves the message back.
    public func discard(_ ref: DraftRef, undoWindow: TimeInterval) async {
        let localID = ref.localID
        dropQueued(localID)
        waiting[localID] = nil
        state.provisional[localID.uuidString] = nil
        let known = state.links[localID.uuidString]?.ref
        let deleteAt = now().addingTimeInterval(max(0, undoWindow))
        state.discarded[localID.uuidString] = GmailDiscardMarker(ref: known.map { merged($0, ref) } ?? ref, deleteAt: deleteAt)
        persist()
        emitProvisional()
        scheduleDiscard(localID, at: deleteAt)
    }

    /// Undo within the window: nothing is deleted, and the window comes back with its link to
    /// Gmail's copy. Nil once the window is over.
    public func undoDiscard(_ localID: UUID) async -> DraftRef? {
        // Once the window is over the delete may already be on its way, so Undo is too late.
        guard let marker = state.discarded[localID.uuidString], now() < marker.deleteAt else { return nil }
        state.discarded[localID.uuidString] = nil
        discardTimers.removeValue(forKey: localID)?.cancel()
        persist()
        return state.links[localID.uuidString]?.ref ?? marker.ref
    }

    /// Deletes Gmail's copy at once, for good: Gmail keeps nothing in Deleted Items. For a
    /// caller that has already waited out the undo window itself.
    public func delete(_ ref: DraftRef) async throws {
        let localID = ref.localID
        dropQueued(localID)
        await settle(localID)
        waiting[localID] = nil
        state.provisional[localID.uuidString] = nil
        let link = state.links[localID.uuidString].map { merged($0.ref, ref) } ?? ref
        if let draftID = link.gmailDraftID {
            try await deleteOnGmail(draftID, message: link.gmailMessageID)
        }
        state.links[localID.uuidString] = nil
        persist()
        emitProvisional()
    }

    /// A message written in a draft went, as Gmail confirmed: the draft goes too.
    public func sent(_ draftID: String) async throws {
        let message = state.links.values.first { $0.ref.gmailDraftID == draftID }?.ref.gmailMessageID
            ?? state.drafts.first { $0.value == draftID }.flatMap { GmailMessageID(hex: $0.key) }
        try await deleteOnGmail(draftID, message: message)
        state.links = state.links.filter { $0.value.ref.gmailDraftID != draftID }
        persist()
    }

    // MARK: - Opening drafts

    /// The Gmail draft a message in Drafts is, from Gmail's list of drafts, which is fetched
    /// again only when Drafts has changed.
    public func draftID(forMessage id: GmailMessageID) async throws -> String? {
        if !mapStale, let known = state.drafts[id.hex] { return known }
        try await listDrafts()
        return state.drafts[id.hex]
    }

    /// The Gmail draft that a draft saved before the switch became, found by its Message-ID.
    public func draft(forMessageID messageID: String) async throws -> (draftID: String, message: GmailMessageID)? {
        guard let wanted = GmailSender.bare(messageID) else { return nil }
        let page = try await transport.list(GmailListQuery(query: "rfc822msgid:\(wanted) in:drafts", maxResults: 10), work: .interactive)
        for ref in page.refs {
            if let draftID = try await draftID(forMessage: ref.id) { return (draftID, ref.id) }
        }
        return nil
    }

    /// The draft on this Mac already writing to `draftID`, whose window comes forward instead
    /// of a second one opening.
    public func openDraft(_ draftID: String) -> UUID? {
        state.links.first { $0.value.ref.gmailDraftID == draftID && $0.value.closedAt == nil }.flatMap { UUID(uuidString: $0.key) }
    }

    /// Drafts changed on Gmail, as the index's DRAFT bits show: the list is fetched again when
    /// next needed.
    public func draftsChanged() {
        mapStale = true
    }

    /// What this Mac knows of a draft.
    public func link(_ localID: UUID) -> DraftRef? {
        state.links[localID.uuidString]?.ref
    }

    // MARK: - Drafts Gmail has not got yet

    /// Drafts saved on this Mac while Gmail could not take them, oldest first. Drafts shows each
    /// as a provisional row, and counts it.
    public func provisionalDrafts() -> [GmailProvisionalDraft] {
        state.provisional.values.sorted { $0.savedAt < $1.savedAt }
    }

    public func events() -> AsyncStream<GmailDraftEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.onTermination = { _ in Task { await self.removeListener(id) } }
        }
    }

    /// Tries at once what waits for Gmail, as when the network comes back.
    public func retryWaiting() async {
        retryTask?.cancel()
        retryTask = nil
        retryDelay = retryInterval
        await retryNow()
    }

    /// At quit: every discard's window ends now and its delete is made, and saves on their way
    /// are waited for, for at most `seconds`. True when nothing is left undone.
    public func flush(within seconds: TimeInterval) async -> Bool {
        await GmailDrafts.first(within: seconds) { await self.finishEverything() }
    }

    // MARK: - The queue of saves

    private struct QueuedSave {
        var raw: Data
        var ref: DraftRef
        var bcc: [EmailAddress]
        var reason: DraftSaveReason
        var waiters: [CheckedContinuation<DraftRef, Error>] = []
        /// A save tried again by itself, whose success `events` announces.
        var announces = false
    }

    private func enqueue(_ save: QueuedSave, waiter: CheckedContinuation<DraftRef, Error>?) {
        let localID = save.ref.localID
        var next = save
        if let earlier = queued[localID] {
            // Superseded content is never sent: its callers get the newer content's result.
            next.waiters = earlier.waiters
            next.announces = earlier.announces || save.announces
        }
        if let waiter { next.waiters.append(waiter) }
        queued[localID] = next
        guard working[localID] == nil else { return }
        working[localID] = Task { await self.work(localID) }
    }

    private func work(_ localID: UUID) async {
        while let job = queued.removeValue(forKey: localID) {
            do {
                let saved = try await perform(job)
                for waiter in job.waiters { waiter.resume(returning: saved) }
                if job.announces { emit(.saved(saved)) }
            } catch {
                for waiter in job.waiters { waiter.resume(throwing: error) }
            }
        }
        working[localID] = nil
    }

    private func dropQueued(_ localID: UUID) {
        guard let dropped = queued.removeValue(forKey: localID) else { return }
        for waiter in dropped.waiters { waiter.resume(throwing: GmailDraftDiscarded()) }
    }

    /// Waits for the save of `localID` on its way, if any.
    private func settle(_ localID: UUID) async {
        while let running = working[localID] { await running.value }
    }

    private func perform(_ job: QueuedSave) async throws -> DraftRef {
        let localID = job.ref.localID
        guard state.discarded[localID.uuidString] == nil else { throw GmailDraftDiscarded() }
        var link = state.links[localID.uuidString] ?? GmailDraftLink(ref: job.ref)
        link.ref = merged(link.ref, job.ref)
        if link.ref.stableMessageID.isEmpty {
            link.ref.stableMessageID = OutgoingMessage.generateMessageID(domain: email.split(separator: "@").last.map(String.init) ?? "falconmail.local")
        }
        let body = GmailDrafts.stamped(job.raw, ref: link.ref, bcc: job.bcc)
        var created = false
        let answer: GmailDraft
        do {
            if link.ref.gmailDraftID == nil, link.creating == true, let found = try await findCreated(link) {
                // An earlier create that never answered did make the draft.
                link.ref.gmailDraftID = found.draftID
                link.ref.gmailMessageID = found.message
            }
            if let draftID = link.ref.gmailDraftID {
                do {
                    answer = try await transport.updateDraft(draftID, raw: body, threadID: link.ref.threadID, work: .interactive)
                } catch let refusal as GoogleAPIError where refusal.kind == .notFound {
                    // Sent or deleted on another device: a new draft, so the text is never dropped.
                    state.drafts = state.drafts.filter { $0.value != draftID }
                    link.ref.gmailDraftID = nil
                    link.ref.gmailMessageID = nil
                    answer = try await create(&link, body)
                    created = true
                }
            } else {
                answer = try await create(&link, body)
                created = true
            }
        } catch {
            throw failed(error, job: job, link: link)
        }
        let previous = link.ref.gmailMessageID
        let message = answer.message.flatMap { GmailMessageID.fromGmail($0.id, in: "drafts") }
        link.ref.gmailDraftID = answer.id
        link.ref.gmailMessageID = message
        link.creating = nil
        link.createSince = nil
        link.lastSaved = now()
        link.closedAt = job.reason.closes ? now() : nil
        if let previous { state.drafts[previous.hex] = nil }
        if let message { state.drafts[message.hex] = answer.id }
        state.provisional[localID.uuidString] = nil
        state.links[localID.uuidString] = link
        waiting[localID] = nil
        persist()
        emitProvisional()
        if created, job.reason == .autosave {
            autosavedThisSession.insert(localID)
        } else if job.reason != .autosave {
            // Saved on purpose, so a quiet close afterwards keeps it.
            autosavedThisSession.remove(localID)
        }
        if let placer, let saved = answer.message {
            await placer.placeUploaded(saved, labels: saved.labels.isEmpty ? [.draft] : saved.labels, raw: body,
                                       replacing: previous, messageID: nil)
        }
        return link.ref
    }

    /// Asks Gmail for a new draft. The link says a create is on its way before it is asked, so
    /// that if no answer comes, even across a crash, the draft is looked for before another is
    /// made.
    private func create(_ link: inout GmailDraftLink, _ body: Data) async throws -> GmailDraft {
        let before = (link.creating, link.createSince)
        link.creating = true
        if link.createSince == nil {
            if let known = await cursor() {
                link.createSince = known
            } else {
                link.createSince = try? await transport.profile(work: .interactive).historyID
            }
        }
        state.links[link.ref.localID.uuidString] = link
        persist()
        do {
            return try await transport.createDraft(body, threadID: link.ref.threadID, work: .interactive)
        } catch let refusal as GoogleAPIError where refusal.kind == .notFound && link.ref.threadID != nil {
            // The conversation is gone; the draft stands on its own, and its headers still
            // thread it once sent.
            link.ref.threadID = nil
            state.links[link.ref.localID.uuidString] = link
            return try await transport.createDraft(body, threadID: nil, work: .interactive)
        } catch let refusal as GoogleAPIError where (refusal.kind == .offline && refusal.delivery != .unknown)
                    || (400..<500).contains(refusal.httpStatus) {
            // No connection was made, or Gmail refused it: this create made no draft, so only
            // an earlier unanswered one, if any, is still looked for. A connection that dropped
            // during the upload may have made one, which is looked for like any unanswered create.
            (link.creating, link.createSince) = before
            state.links[link.ref.localID.uuidString] = link
            persist()
            throw refusal
        }
    }

    /// What a failed save leaves: waiting for Gmail, or refused.
    private func failed(_ error: Error, job: QueuedSave, link: GmailDraftLink) -> Error {
        let localID = job.ref.localID
        let refusal = error as? GoogleAPIError
        var link = link
        if job.reason.closes { link.closedAt = now() }
        state.links[localID.uuidString] = link
        if let sentence = GmailDrafts.refusalSentence(refusal, email: email) {
            persist()
            Log.error("Save", "\(email): Gmail refused a draft save: \(refusal?.kind.rawValue ?? "local")", error: refusal)
            return GmailDraftRefused(sentence: sentence, cause: refusal)
        }
        var kept = job
        kept.waiters = []
        kept.announces = true
        kept.ref = link.ref
        waiting[localID] = kept
        let headers = MIMEParser.parseHeaders(job.raw)
        state.provisional[localID.uuidString] = GmailProvisionalDraft(
            localID: localID, subject: RFC2047.decode(headers.first("Subject") ?? ""),
            to: AddressParser.parse(headers.first("To")).map(\.address), savedAt: now())
        persist()
        emitProvisional()
        scheduleRetry(after: refusal?.retryAfter)
        // Offline is ordinary: the provisional row says so, and it is no failure to report.
        Log.info("drafts", "\(email): a draft waits for Gmail: \(refusal?.kind.rawValue ?? String(describing: type(of: error)))")
        return GmailDraftDeferred(ref: link.ref, sentence: GmailDrafts.waitingSentence(refusal, email: email), cause: refusal)
    }

    // MARK: - Finding a draft whose create never answered

    /// The draft an unanswered create made, if it made one: the newest draft added to the
    /// history since the create began that carries this draft's header or Message-ID. Where the
    /// history has gone, Drafts is searched by Message-ID instead.
    private func findCreated(_ link: GmailDraftLink) async throws -> (draftID: String, message: GmailMessageID)? {
        var candidates: [GmailMessageID] = []
        var fromHistory = false
        if let since = link.createSince {
            do {
                var token: String?
                repeat {
                    let page = try await transport.history(since: since, types: [.messageAdded], label: .draft, pageToken: token,
                                                           work: .interactive)
                    for record in page.records { candidates += record.messagesAdded.map(\.ref.id) }
                    token = page.nextPageToken
                } while token != nil && candidates.count < 500
                fromHistory = true
            } catch let refusal as GoogleAPIError where refusal.kind == .historyExpired {
                // Searched below.
            }
        }
        if !fromHistory, let wanted = GmailSender.bare(link.ref.stableMessageID) {
            let page = try await transport.list(GmailListQuery(query: "rfc822msgid:\(wanted) in:drafts", maxResults: 10), work: .interactive)
            candidates = page.refs.map(\.id).reversed()
        }
        let header = link.ref.localID.uuidString.lowercased()
        let wanted = GmailSender.bare(link.ref.stableMessageID)
        // Newest first, since a later save of the same draft replaced the earlier message.
        let ordered = Array(candidates.reversed())
        var start = 0
        while start < ordered.count {
            let chunk = Array(ordered[start..<min(start + 25, ordered.count)])
            let parts = chunk.map { GmailBatchPart.message($0, .metadata(headers: [GmailDrafts.draftHeader, "Message-ID"])) }
            let answers = try await transport.batch(parts, work: .interactive)
            for (id, part) in zip(chunk, parts) {
                guard case .success(let answer)? = answers[part], let m = answer.message else { continue }
                let ours = m.header(GmailDrafts.draftHeader)?.trimmed.lowercased() == header
                    || (wanted != nil && GmailSender.bare(m.header("Message-ID")) == wanted)
                guard ours else { continue }
                if let draftID = try await draftID(forMessage: id) { return (draftID, id) }
            }
            start += 25
        }
        return nil
    }

    private func listDrafts() async throws {
        var map: [String: String] = [:]
        var token: String?
        repeat {
            let page = try await transport.drafts(pageToken: token, work: .interactive)
            for draft in page.drafts ?? [] {
                guard let message = draft.message, let id = GmailMessageID.fromGmail(message.id, in: "drafts.list") else { continue }
                map[id.hex] = draft.id
            }
            token = page.nextPageToken
        } while token != nil
        state.drafts = map
        mapStale = false
        persist()
    }

    // MARK: - Deleting

    private func deleteOnGmail(_ draftID: String, message: GmailMessageID?) async throws {
        do {
            try await transport.deleteDraft(draftID, work: .interactive)
        } catch let refusal as GoogleAPIError where refusal.kind == .notFound {
            // Already gone.
        }
        state.drafts = state.drafts.filter { $0.value != draftID }
        if let message { await placer?.forget([message]) }
    }

    private func scheduleDiscard(_ localID: UUID, at date: Date) {
        discardTimers[localID]?.cancel()
        let wait = max(0, date.timeIntervalSince(now()))
        discardTimers[localID] = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            _ = await self?.finishDiscard(localID)
        }
    }

    /// Deletes Gmail's copy of a discarded draft. False when Gmail could not be reached; the
    /// marker stays, and it is tried again later, at quit or at the next launch.
    private func finishDiscard(_ localID: UUID) async -> Bool {
        discardTimers[localID] = nil
        guard state.discarded[localID.uuidString] != nil else { return true }
        await settle(localID)
        guard let marker = state.discarded[localID.uuidString] else { return true }
        var ref = state.links[localID.uuidString].map { merged($0.ref, marker.ref) } ?? marker.ref
        do {
            if ref.gmailDraftID == nil, let link = state.links[localID.uuidString], link.creating == true,
               let found = try await findCreated(link) {
                ref.gmailDraftID = found.draftID
                ref.gmailMessageID = found.message
            }
            if let draftID = ref.gmailDraftID {
                try await deleteOnGmail(draftID, message: ref.gmailMessageID)
            }
        } catch {
            Log.info("drafts", "\(email): a discarded draft is not deleted on Gmail yet: \(error.localizedDescription)")
            scheduleRetry()
            return false
        }
        state.discarded[localID.uuidString] = nil
        state.links[localID.uuidString] = nil
        persist()
        return true
    }

    // MARK: - Trying again

    private func scheduleRetry(after seconds: TimeInterval? = nil) {
        guard retryTask == nil else { return }
        let wait = max(seconds ?? 0, retryDelay)
        retryDelay = min(600, retryDelay * 2)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.retryFired()
        }
    }

    private func retryFired() async {
        retryTask = nil
        await retryNow()
    }

    private func retryNow() async {
        for (localID, save) in waiting where queued[localID] == nil {
            waiting[localID] = nil
            enqueue(save, waiter: nil)
        }
        for key in state.discarded.keys {
            guard let localID = UUID(uuidString: key), let marker = state.discarded[key], marker.deleteAt <= now(),
                  discardTimers[localID] == nil else { continue }
            _ = await finishDiscard(localID)
        }
        for localID in Array(working.keys) { await settle(localID) }
        if waiting.isEmpty && !state.discarded.values.contains(where: { $0.deleteAt <= now() }) {
            retryDelay = retryInterval
        } else {
            scheduleRetry()
        }
    }

    private func finishEverything() async -> Bool {
        for localID in Array(working.keys) { await settle(localID) }
        var done = true
        for key in Array(state.discarded.keys) {
            guard let localID = UUID(uuidString: key) else { continue }
            discardTimers.removeValue(forKey: localID)?.cancel()
            if !(await finishDiscard(localID)) { done = false }
        }
        return done && working.isEmpty
    }

    // MARK: - Saving the state

    private func persist() {
        guard canSave else { return }
        do {
            try AtomicFile.writeJSON(state, to: file)
        } catch {
            Log.error("Store", "\(email): could not save the list of Gmail drafts: \(error.localizedDescription)", error: error)
        }
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    private func emit(_ event: GmailDraftEvent) {
        for listener in listeners.values { listener.yield(event) }
    }

    private func emitProvisional() {
        emit(.provisional(provisionalDrafts()))
    }

    // MARK: - Helpers

    /// What this Mac knows, with what the caller knows filled in: a Gmail draft id found
    /// earlier wins, since only it names the draft every save updates.
    private func merged(_ known: DraftRef, _ given: DraftRef) -> DraftRef {
        var out = known
        if out.gmailDraftID == nil, let draftID = given.gmailDraftID {
            out.gmailDraftID = draftID
            out.gmailMessageID = given.gmailMessageID ?? out.gmailMessageID
        }
        if let thread = given.threadID { out.threadID = thread }
        if out.stableMessageID.isEmpty { out.stableMessageID = given.stableMessageID }
        return out
    }

    /// The bytes of one save: the draft's one Message-ID, its header, and Bcc, which Gmail
    /// keeps in a draft, so the draft opens again, and is sent, with its Bcc recipients, as a
    /// draft saved to an IMAP Drafts folder keeps them (MIMEBuilder's `keepingBcc`). A Bcc header
    /// already in `raw` stays when `bcc` is empty; `bcc` given replaces it, each address once,
    /// with its name.
    static func stamped(_ raw: Data, ref: DraftRef, bcc: [EmailAddress]) -> Data {
        let stable = ref.stableMessageID.hasPrefix("<") ? ref.stableMessageID : "<\(ref.stableMessageID)>"
        var fields: [(name: String, value: String)] = [("Message-ID", stable), (draftHeader, ref.localID.uuidString.lowercased())]
        var names: Set<String> = ["Message-ID", draftHeader]
        var seen = Set<String>()
        let blind = bcc.filter { !$0.address.trimmed.isEmpty && seen.insert($0.address.trimmed.lowercased()).inserted }
        if !blind.isEmpty {
            fields.append(("Bcc", blind.map(MIMEBuilder.encodeAddress).joined(separator: ", ")))
            names.insert("Bcc")
        }
        return RawHeaders.setting(fields, removing: names, in: raw)
    }

    /// A refusal that no retry can change, or nil for a save worth trying again.
    static func refusalSentence(_ refusal: GoogleAPIError?, email: String) -> String? {
        guard let refusal else { return nil }
        switch refusal.kind {
        case .offline, .temporary, .rateLimited, .uploadLimit, .downloadLimit, .quotaExhausted, .apiDisabled, .needsSignIn,
             .notFound, .historyExpired:
            return nil
        case .tooLarge:
            return "Gmail can't keep a draft with more than 25 MB of attachments. Remove some, or share them from Google Drive."
        case .clientRejected, .insufficientPermissions, .domainPolicy, .gmailNotEnabled:
            return "Gmail refused to save the draft for \(email). \(refusal.localizedDescription)"
        case .other:
            return (400..<500).contains(refusal.httpStatus) ? "Gmail refused to save the draft. Details are in the log." : nil
        case .sendingLimit:
            return nil
        }
    }

    static func waitingSentence(_ refusal: GoogleAPIError?, email: String) -> String {
        let until = refusal?.retryAfter.map { GoogleAPIError.timeText(Date().addingTimeInterval($0)) }
        switch refusal?.kind {
        case .uploadLimit?:
            return "Saved to Drafts. Gmail has paused uploads for \(email)\(until.map { " until \($0)" } ?? ""); an import may be using the allowance. It goes to Gmail then."
        case .rateLimited?, .quotaExhausted?, .downloadLimit?, .apiDisabled?:
            return "Saved to Drafts. Gmail asked FalconMail to wait, so it goes to Gmail \(until.map { "at \($0)" } ?? "shortly")."
        case .needsSignIn?:
            return "Saved to Drafts. It goes to Gmail once you sign in to \(email) again."
        default:
            return "Saved to Drafts. It goes to Gmail when you're back online."
        }
    }

    /// Whichever comes first: `work` finishing, or `seconds` passing, which counts as not done.
    static func first(within seconds: TimeInterval, _ work: @escaping @Sendable () async -> Bool) async -> Bool {
        let once = FirstAnswer()
        return await withCheckedContinuation { continuation in
            Task {
                let done = await work()
                if once.claim() { continuation.resume(returning: done) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }
}

/// Why a draft is saved, which decides what a later quiet close does.
public enum DraftSaveReason: String, Sendable, Codable {
    /// The window, tab or tray chip was closed with something written in it.
    case close
    /// Save Draft in the compose title row.
    case saveButton
    /// The automatic save while writing.
    case autosave
    /// A draft left from the last session, saved at launch.
    case leftover

    /// Whether the window is gone after this save.
    var closes: Bool { self == .close || self == .leftover }
}

/// A draft saved on this Mac that Gmail has not got yet. Drafts shows it at once as a
/// provisional row with its subject, and counts it, so closing offline visibly saved the
/// message (§8.4). Double-clicking it reopens the copy on the Mac.
public struct GmailProvisionalDraft: Codable, Hashable, Sendable {
    public var localID: UUID
    public var subject: String
    public var to: [String]
    public var savedAt: Date

    public init(localID: UUID, subject: String, to: [String], savedAt: Date) {
        self.localID = localID
        self.subject = subject
        self.to = to
        self.savedAt = savedAt
    }
}

public enum GmailDraftEvent: Sendable {
    /// A save that had waited reached Gmail: the copy on the Mac may go now.
    case saved(DraftRef)
    /// The drafts Gmail has not got yet, whenever they change.
    case provisional([GmailProvisionalDraft])
}

/// Gmail could not take the draft now. It is kept, shown in Drafts as provisional, and goes to
/// Gmail by itself; the copy on the Mac must stay until it has.
public struct GmailDraftDeferred: Error, LocalizedError, Sendable {
    public var ref: DraftRef
    /// For the status line, such as "Saved to Drafts. It goes to Gmail when you're back online."
    public var sentence: String
    public var cause: GoogleAPIError?

    public var errorDescription: String? { sentence }
}

/// Gmail refused the draft, and trying again would not change that.
public struct GmailDraftRefused: Error, LocalizedError, Sendable {
    public var sentence: String
    public var cause: GoogleAPIError?

    public var errorDescription: String? { sentence }
}

/// The draft was discarded, so it is never saved back to Drafts.
public struct GmailDraftDiscarded: Error, LocalizedError, Sendable {
    public var errorDescription: String? { "The draft was discarded." }
}

/// `drafts.json`: what this Mac knows of the account's drafts. An earlier build never reads it.
struct GmailDraftsState: Codable, Sendable {
    /// Drafts written on this Mac, by their local id.
    var links: [String: GmailDraftLink] = [:]
    /// Gmail's draft id for each draft message id, from `drafts.list`.
    var drafts: [String: String] = [:]
    /// Discards whose undo window, or delete, is not over.
    var discarded: [String: GmailDiscardMarker] = [:]
    var provisional: [String: GmailProvisionalDraft] = [:]
}

struct GmailDraftLink: Codable, Sendable {
    var ref: DraftRef
    /// Set just before a create is asked for and cleared by Gmail's answer. A link found with
    /// it may have a draft on Gmail already, looked for after `createSince` before another is
    /// made.
    var creating: Bool?
    var createSince: HistoryID?
    var lastSaved: Date?
    /// When the window went, after which the link is kept only long enough for a draft left
    /// over after a crash to find it.
    var closedAt: Date?

    init(ref: DraftRef) {
        self.ref = ref
    }
}

struct GmailDiscardMarker: Codable, Sendable {
    var ref: DraftRef
    var deleteAt: Date
}

/// Lets exactly one of several racing tasks answer.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false

    func claim() -> Bool {
        lock.withLock {
            guard !answered else { return false }
            answered = true
            return true
        }
    }
}
