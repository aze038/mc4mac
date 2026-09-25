import Foundation

// One check for changes (§4.2): Gmail's history since the cursor, reduced per message, applied to
// the index with the new mail placed, then saved with the cursor in one flush. When the history
// has expired (§4.4) the mailbox is listed again, nothing is removed until confirmed, and new mail
// keeps arriving meanwhile from a look at the top of All Mail.

/// What one check did, for the status line, the sounds and the tests.
public struct GmailCheckReport: Sendable {
    public var reason: PokeReason
    /// Nothing was checked: there is no cursor yet, or a message just went out and the look for
    /// it is due in a moment.
    public var skipped = false
    public var records = 0
    public var placedAtTop: [GmailMessageID] = []
    public var placedDeep: [GmailMessageID] = []
    public var provisional: [GmailMessageID] = []
    public var tombstoned: [GmailMessageID] = []
    public var relabelled: [GmailMessageID] = []
    public var waiting: [GmailMessageID] = []
    /// Mail that arrived now, announced or not.
    public var arrivals: [GmailArrival] = []
    /// What went out as `.newMessages`.
    public var announced: [MessageSummary] = []
    /// The history had expired, or a resync is under way: the top of All Mail was looked at.
    public var lookedAtTop = false
    public var floodBegan = false
    public var failure: GoogleAPIError?
    /// History events per label and messages added or deleted, which a count taken just before
    /// may differ by.
    public var labelEvents: [GmailLabelID: Int] = [:]
    public var messageEvents = 0

    public init(reason: PokeReason, skipped: Bool = false) {
        self.reason = reason
        self.skipped = skipped
    }

    public var changedAnything: Bool {
        !placedAtTop.isEmpty || !placedDeep.isEmpty || !tombstoned.isEmpty || !relabelled.isEmpty || !provisional.isEmpty
    }

    public var foundNewMail: Bool { !announced.isEmpty }
}

// MARK: - Reducing a check

/// A check's history records reduced to what each message ends as (§4.2 step 1). Records come in
/// the order Gmail wrote them, so label changes are applied in order and the last one wins; a
/// message added and deleted again within the check, as every draft autosave on the web or the
/// phone is, is dropped without being fetched.
struct GmailHistoryReduction: Sendable {
    /// Messages to place: added in this check, or changed while the index did not know them, which
    /// means a listing missed them.
    var unknown: [GmailRef] = []
    /// The labels the history gave for those, which only a provisional placement relies on.
    var labelHints: [UInt64: Set<GmailLabelID>] = [:]
    var deleted: [GmailRef] = []
    /// Added and deleted again within the check.
    var vanished: [GmailRef] = []
    var relabels: [(id: GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>)] = []
    var labelEvents: [GmailLabelID: Int] = [:]
    var messageEvents = 0
    /// Every label the records name, so a label Gmail made since the label table was read is
    /// noticed.
    var labelsNamed: Set<GmailLabelID> = []
}

enum GmailHistoryReducer {
    static func reduce(_ records: [GmailHistoryRecord], isKnown: (GmailMessageID) -> Bool) -> GmailHistoryReduction {
        struct Trail {
            var ref: GmailRef
            var seen: Int
            var added = false
            var addedLabels: Set<GmailLabelID> = []
            var deleted = false
            var labels: [GmailLabelID: Bool] = [:]
        }
        var trails: [UInt64: Trail] = [:]
        var out = GmailHistoryReduction()
        func touch(_ ref: GmailRef) {
            if trails[ref.id.raw] == nil { trails[ref.id.raw] = Trail(ref: ref, seen: trails.count) }
        }
        for record in records.sorted(by: { $0.id < $1.id }) {
            for added in record.messagesAdded {
                touch(added.ref)
                trails[added.ref.id.raw]?.added = true
                trails[added.ref.id.raw]?.addedLabels.formUnion(added.labels ?? [])
                out.messageEvents += 1
                for label in added.labels ?? [] { out.labelEvents[label, default: 0] += 1 }
                out.labelsNamed.formUnion(added.labels ?? [])
            }
            for deleted in record.messagesDeleted {
                touch(deleted.ref)
                trails[deleted.ref.id.raw]?.deleted = true
                out.messageEvents += 1
                for label in deleted.labels ?? [] { out.labelEvents[label, default: 0] += 1 }
            }
            for change in record.labelsAdded {
                touch(change.message.ref)
                for label in change.labels {
                    trails[change.message.ref.id.raw]?.labels[label] = true
                    out.labelEvents[label, default: 0] += 1
                }
                out.labelsNamed.formUnion(change.labels)
            }
            for change in record.labelsRemoved {
                touch(change.message.ref)
                for label in change.labels {
                    trails[change.message.ref.id.raw]?.labels[label] = false
                    out.labelEvents[label, default: 0] += 1
                }
                out.labelsNamed.formUnion(change.labels)
            }
        }
        for trail in trails.values.sorted(by: { $0.seen < $1.seen }) {
            let known = isKnown(trail.ref.id)
            let adding = Set(trail.labels.filter(\.value).keys)
            let removing = Set(trail.labels.filter { !$0.value }.keys)
            if trail.deleted {
                if trail.added && !known { out.vanished.append(trail.ref) } else { out.deleted.append(trail.ref) }
            } else if known {
                if !adding.isEmpty || !removing.isEmpty { out.relabels.append((trail.ref.id, adding, removing)) }
            } else {
                out.unknown.append(trail.ref)
                out.labelHints[trail.ref.id.raw] = trail.addedLabels.union(adding).subtracting(removing)
            }
        }
        return out
    }
}

/// What placing a check's added messages decided.
struct GmailPlacementOutcome: Sendable {
    var changes: [GmailChange] = []
    var top: [GmailMessage] = []
    var deep: [GmailMessageID] = []
    var provisional: [GmailMessageID] = []
    var gone: [GmailMessageID] = []
    var waiting: [GmailRef] = []
    var labels: Set<GmailLabelID> = []
    var floodBegan = false
    /// Already in the index, placed meanwhile by a listing or an answer: nothing more to do.
    var settled: [GmailMessageID] = []
}

extension GmailAccountEngine {
    // MARK: - One check

    func performCheck(reason: PokeReason) async -> GmailCheckReport {
        await loadIfNeeded()
        var report = GmailCheckReport(reason: reason)
        if let until = schedule.pausedUntil, until > now() {
            // Google asked FalconMail to wait: nothing is asked of it before then, even for Send &
            // Receive, which would only be refused again. It says nothing, as the pause does.
            report.skipped = true
            report.failure = lastPause?.refusal ?? GoogleAPIError(kind: .rateLimited, retryAfter: until.timeIntervalSince(now()))
            return report
        }
        if reason.reportsProgress { emit(.started(accountID: accountID)) }
        let startedAt = await gmailNow()
        do {
            if resyncBegan == nil, !resyncWanted {
                if let from = cursor {
                    do {
                        try await historyCheck(from: from, startedAt: startedAt, report: &report)
                    } catch let error as GoogleAPIError where error.kind == .historyExpired {
                        Log.warning("gmail", "\(account.email): the change history has expired; listing the mailbox again",
                                    error: error, account: account, code: "historyExpired")
                        resyncWanted = true
                    }
                } else {
                    // Nothing to check from until the first listing has saved its cursor.
                    report.skipped = true
                    schedule.checkEnded(at: now())
                    return report
                }
            }
            if resyncBegan != nil || resyncWanted {
                try await topOfAllMailCheck(startedAt: startedAt, report: &report)
                startResyncIfDue(askedByOwner: reason == .sendAndReceive)
            }
            checkSucceeded(reason: reason, startedAt: startedAt, report: report)
        } catch let error as GoogleAPIError {
            checkFailed(error, report: &report)
        } catch is CancellationError {
            report.skipped = true
        } catch {
            // Only the store throws anything else: nothing the check read is lost, since the
            // cursor was not saved, and the next check reads it again.
            Log.error("gmail", "\(account.email): a check could not be saved", error: error, account: account)
            checkFailed(GoogleAPIError(kind: .temporary, detail: "store: \(error.localizedDescription)"), report: &report)
        }
        schedule.checkEnded(at: now())
        return report
    }

    private func checkSucceeded(reason: PokeReason, startedAt: Date, report: GmailCheckReport) {
        figures.checks += 1
        let outcome = healthTracker.succeeded()
        if let health = outcome.health { setHealth(health) }
        schedule.pause(until: nil)
        schedule.block(until: nil)
        schedule.stop(false)
        schedule.setOffline(false)
        if !report.skipped {
            let first = state.lastCheckStart == nil
            state.lastCheckStart = startedAt
            saveState(force: first)
        }
        if outcome.recovered || report.changedAnything || reason.reportsProgress { emit(.finished(accountID: accountID)) }
        if reason.reportsNewMail { emit(.checked(accountID: accountID, foundNewMail: report.foundNewMail)) }
    }

    private func checkFailed(_ error: GoogleAPIError, report: inout GmailCheckReport) {
        report.failure = error
        figures.failedChecks += 1
        let current = now()
        let pause = currentPause
        let verdict = healthTracker.failed(error, pause: pause, now: current)
        if let health = verdict.health { setHealth(health) }
        if let sentence = verdict.sentence { emit(.error(accountID: accountID, message: sentence)) }
        schedule.pause(until: verdict.pausedUntil)
        schedule.block(until: verdict.blockedUntil)
        schedule.stop(verdict.stops)
        schedule.setOffline(verdict.offline)
        if verdict.health != nil {
            let isError = verdict.stops || verdict.blockedUntil != nil
            let message = "\(account.email): a check failed: \(error.kind.rawValue) \(error.httpStatus) \(error.reason ?? "")"
            if isError {
                Log.error("gmail", message, error: error, account: account, code: error.kind.rawValue)
            } else {
                Log.warning("gmail", message, error: error, account: account, code: error.kind.rawValue)
            }
        } else {
            Log.info("gmail", "\(account.email): a check failed quietly: \(error.kind.rawValue) \(error.httpStatus)")
        }
    }

    /// The last pause the transport reported, read before a failure is judged.
    var currentPause: GmailPause? { lastPause }

    // MARK: - The history

    func historyCheck(from start: HistoryID, startedAt: Date, report: inout GmailCheckReport) async throws {
        lastPause = await transport.pause()
        var records: [GmailHistoryRecord] = []
        var token: String?
        var newest = start
        repeat {
            let page = try await transport.history(since: start, types: Set(GmailHistoryType.allCases), label: nil,
                                                   pageToken: token, work: .checks)
            records += page.records
            newest = max(newest, page.historyID)
            token = page.nextPageToken
        } while token != nil
        report.records = records.count
        // The owner's changes on their way win over what the history says of their labels.
        if let actions = parts.actions { records = await actions.screen(records, engine: self) }

        var ids: Set<UInt64> = []
        for record in records {
            for m in record.messagesAdded + record.messagesDeleted { ids.insert(m.ref.id.raw) }
            for change in record.labelsAdded + record.labelsRemoved { ids.insert(change.message.ref.id.raw) }
        }
        var known: Set<UInt64> = []
        for raw in ids {
            if let record = await store.record(for: GmailMessageID(raw: raw)), !record.attributes.contains(.tombstone) { known.insert(raw) }
        }
        let reduction = GmailHistoryReducer.reduce(records) { known.contains($0.raw) }
        report.labelEvents = reduction.labelEvents
        report.messageEvents = reduction.messageEvents
        noteLabelsNamed(reduction.labelsNamed)

        var changes: [GmailChange] = []
        var touched: Set<GmailMessageID> = []
        var changedLabels: Set<GmailLabelID> = []
        for ref in reduction.deleted {
            let raw = ref.id.raw
            if known.contains(raw) || awaiting[raw] != nil || provisional.contains(raw) {
                if !provisional.contains(raw), let labels = await store.labels(of: ref.id) { changedLabels.formUnion(labels) }
                changes.append(.tombstone(ref.id))
                touched.insert(ref.id)
                report.tombstoned.append(ref.id)
            }
            awaiting[raw] = nil
            provisional.remove(raw)
        }
        for ref in reduction.vanished { awaiting[ref.id.raw] = nil }
        for relabel in reduction.relabels {
            guard !relabel.adding.isEmpty || !relabel.removing.isEmpty else { continue }
            changes.append(.relabel(relabel.id, adding: relabel.adding, removing: relabel.removing))
            touched.insert(relabel.id)
            report.relabelled.append(relabel.id)
            if !provisional.contains(relabel.id.raw) { changedLabels.formUnion(relabel.adding.union(relabel.removing)) }
        }

        var toPlace = reduction.unknown
        let gone = Set(reduction.deleted.map(\.id.raw)).union(reduction.vanished.map(\.id.raw))
        let listed = Set(toPlace.map(\.id.raw))
        for (raw, ref) in awaiting.sorted(by: { $0.key < $1.key }) where !listed.contains(raw) && !gone.contains(raw) {
            toPlace.append(ref)
        }
        let placement = await place(toPlace, hints: reduction.labelHints, startedAt: startedAt, deepAllowed: true)
        changes += placement.changes
        changedLabels.formUnion(placement.labels)

        let next = max(cursor ?? newest, newest)
        if !changes.isEmpty || next != cursor {
            try await store.commit(GmailJournalBatch(changes: changes, cursor: next))
        }
        cursor = next
        applyPlacementBookkeeping(placement, report: &report)
        touched.formUnion(placement.top.compactMap(\.gmailID))
        touched.formUnion(placement.deep)
        touched.formUnion(placement.provisional)
        publishIndexChange(ids: touched)
        await announce(placement.top, gmailNow: startedAt, report: &report)
        refreshCounts(of: changedLabels)
        if changedLabels.contains(.draft), let uploads = parts.uploads { await uploads.draftsChanged(engine: self) }
        if !placement.deep.isEmpty, state.dateGroupsWanted == true {
            let placed = Set(placement.deep.map(\.raw))
            Task { await self.refreshAnchors(near: placed) }
        }
    }

    /// Records what a placement decided in the engine's own memory, once it is journaled.
    func applyPlacementBookkeeping(_ placement: GmailPlacementOutcome, report: inout GmailCheckReport) {
        for id in placement.settled { awaiting[id.raw] = nil }
        for message in placement.top {
            guard let id = message.gmailID else { continue }
            awaiting[id.raw] = nil
            report.placedAtTop.append(id)
            placedDuringRelist?.insert(id.raw)
        }
        for id in placement.deep {
            awaiting[id.raw] = nil
            report.placedDeep.append(id)
            placedDuringRelist?.insert(id.raw)
        }
        for id in placement.provisional {
            awaiting[id.raw] = nil
            provisional.insert(id.raw)
            report.provisional.append(id)
        }
        for id in placement.gone {
            awaiting[id.raw] = nil
            report.tombstoned.append(id)
        }
        for ref in placement.waiting {
            awaiting[ref.id.raw] = ref
            report.waiting.append(ref.id)
        }
        if placement.floodBegan { report.floodBegan = true }
    }

    // MARK: - Placing added mail (§4.3)

    /// Decides where each added message goes. Up to 10 are fetched whole, in one batch, which
    /// gives their receipt time, labels and text at once. More than that are first matched against
    /// one search for mail received since the last check (5 units): only those that arrived now
    /// are fetched whole, and the rest are placed deep one by one, or, when there are more than
    /// flood mode allows, left provisional for the next listing to settle. So another app's import
    /// costs a few units a check instead of 20 a message.
    func place(_ refs: [GmailRef], hints: [UInt64: Set<GmailLabelID>], startedAt: Date,
               deepAllowed: Bool) async -> GmailPlacementOutcome {
        var outcome = GmailPlacementOutcome()
        var seen: Set<UInt64> = []
        var todo: [GmailRef] = []
        for ref in refs where seen.insert(ref.id.raw).inserted {
            if let record = await store.record(for: ref.id), !record.attributes.contains(.tombstone) {
                outcome.settled.append(ref.id)
                continue
            }
            // Placed by FalconMail's own import from its answer: its echo changes nothing.
            if await store.wasImported(ref.id) { continue }
            todo.append(ref)
        }
        guard !todo.isEmpty else { return outcome }
        let current = now()
        let windowStart = GmailArrivalRule.windowStart(lastCheckStart: state.lastCheckStart ?? state.backfill?.startedAt ?? startedAt,
                                                       floodBegan: flood.began)
        let importing = importLog.isImporting(at: current)
        var arrived: [GmailMessage] = []
        var deep: [GmailDeepPlacement] = []
        var deepUnfetched: [GmailRef] = []

        func arrivedNow(_ message: GmailMessage) -> Bool {
            guard let date = message.receivedDate else { return false }
            let ours = importLog.isImporting(messageID: AddressParser.messageIDs(message.header("Message-ID")).first ?? "")
            return GmailArrivalRule.arrivedNow(internalDate: date, windowStart: windowStart, gmailNow: startedAt, importedByFalconMail: ours)
        }

        if todo.count <= settings.fetchedOneByOne && !flood.isActive {
            let answers = await fetch(todo.map(\.id), format: .full, work: .checks)
            for ref in todo {
                switch answers[ref.id.raw] {
                case .success(let message)?:
                    if arrivedNow(message) {
                        arrived.append(message)
                    } else if let date = message.receivedDate {
                        deep.append(GmailDeepPlacement(ref: ref, labels: message.labels, internalDate: date, attributes: Self.attributes(of: message)))
                    } else {
                        outcome.waiting.append(ref)
                    }
                case .failure(let error)? where error.kind == .notFound:
                    outcome.changes.append(.tombstone(ref.id))
                    outcome.gone.append(ref.id)
                default:
                    outcome.waiting.append(ref)
                }
            }
        } else {
            let since: Set<UInt64>
            do {
                since = try await receivedSince(windowStart, gmailNow: startedAt)
            } catch {
                outcome.waiting += todo
                outcome.changes += todo.map { .awaitingPlacement($0) }
                return outcome
            }
            let candidates = todo.filter { since.contains($0.id.raw) }
            deepUnfetched = todo.filter { !since.contains($0.id.raw) }
            let answers = await fetch(candidates.map(\.id), format: .full, work: .checks)
            for ref in candidates {
                switch answers[ref.id.raw] {
                case .success(let message)?:
                    if arrivedNow(message) {
                        arrived.append(message)
                    } else if let date = message.receivedDate {
                        deep.append(GmailDeepPlacement(ref: ref, labels: message.labels, internalDate: date, attributes: Self.attributes(of: message)))
                    }
                case .failure(let error)? where error.kind == .notFound:
                    outcome.changes.append(.tombstone(ref.id))
                    outcome.gone.append(ref.id)
                default:
                    outcome.waiting.append(ref)
                }
            }
        }

        // Deep mail while FalconMail's own import is on its way may be that import's echo: it is
        // placed at the next check, by when the import's answer has placed and logged it, and it
        // never counts towards flood mode.
        if importing {
            outcome.waiting += deep.map(\.ref) + deepUnfetched
            deep = []
            deepUnfetched = []
        } else if deepAllowed {
            let count = deep.count + deepUnfetched.count
            if flood.noteDeep(count, at: current) == .began {
                outcome.floodBegan = true
                await floodBegan(at: current, count: count)
            }
        }

        if flood.isActive && deepAllowed {
            for ref in deepUnfetched + deep.map(\.ref) {
                let labels = deep.first { $0.ref.id == ref.id }?.labels ?? hints[ref.id.raw] ?? []
                outcome.changes.append(.place(ref, order: 0, labels: labels, attributes: .provisional))
                outcome.provisional.append(ref.id)
            }
            deep = []
            deepUnfetched = []
        } else if deepAllowed && !deepUnfetched.isEmpty {
            let answers = await fetch(deepUnfetched.map(\.id), format: .minimal, work: .checks)
            for ref in deepUnfetched {
                switch answers[ref.id.raw] {
                case .success(let message)?:
                    if let date = message.receivedDate {
                        deep.append(GmailDeepPlacement(ref: ref, labels: message.labels, internalDate: date, attributes: Self.attributes(of: message)))
                    } else {
                        outcome.waiting.append(ref)
                    }
                case .failure(let error)? where error.kind == .notFound:
                    outcome.changes.append(.tombstone(ref.id))
                    outcome.gone.append(ref.id)
                default:
                    outcome.waiting.append(ref)
                }
            }
        }

        // Above the top, oldest first, so the newest arrival is the top of the list.
        arrived.sort { ($0.receivedDate ?? .distantPast, $0.gmailID ?? GmailMessageID(raw: 0)) < ($1.receivedDate ?? .distantPast, $1.gmailID ?? GmailMessageID(raw: 0)) }
        let orders = GmailOrderSpace.top(count: arrived.count, above: ceiling)
        for (message, order) in zip(arrived, orders) {
            guard let ref = message.ref else { continue }
            outcome.changes.append(.place(ref, order: order, labels: message.labels, attributes: Self.attributes(of: message)))
            outcome.top.append(message)
            outcome.labels.formUnion(message.labels)
            ceiling = max(ceiling, order)
        }

        if deepAllowed && !deep.isEmpty {
            if allMailComplete {
                let placed = await deepChanges(for: deep, work: .checks)
                outcome.changes += placed.changes
                let waiting = Set(placed.waiting.map(\.id.raw))
                for item in deep where !waiting.contains(item.ref.id.raw) {
                    outcome.deep.append(item.ref.id)
                    outcome.labels.formUnion(item.labels)
                }
                outcome.waiting += placed.waiting
            } else {
                // The listing still running reaches them, or places them once it is done.
                outcome.waiting += deep.map(\.ref)
            }
        }
        outcome.changes += outcome.waiting.map { .awaitingPlacement($0) }
        return outcome
    }

    /// Ids of mail Gmail received from `start` until a day ahead of now, newest first, in every
    /// folder. Gmail reads epoch seconds in a search exactly (§3, S33).
    func receivedSince(_ start: Date, gmailNow: Date) async throws -> Set<UInt64> {
        let after = Int(start.timeIntervalSince1970.rounded(.down))
        let before = Int(gmailNow.addingTimeInterval(GmailArrivalRule.furthestAhead).timeIntervalSince1970.rounded(.up))
        var out: Set<UInt64> = []
        var token: String?
        repeat {
            let page = try await transport.list(GmailListQuery(query: "after:\(after) before:\(before)", includeSpamTrash: true,
                                                               maxResults: settings.pageSize, pageToken: token), work: .checks)
            out.formUnion(page.refs.map(\.id.raw))
            token = page.nextPageToken
        } while token != nil
        return out
    }

    /// Messages fetched in HTTP batches of at most 10 parts, each answered on its own. A batch
    /// that failed as a whole stands for each of its parts.
    func fetch(_ ids: [GmailMessageID], format: GmailFormat, work: WorkClass) async -> [UInt64: Result<GmailMessage, GoogleAPIError>] {
        var out: [UInt64: Result<GmailMessage, GoogleAPIError>] = [:]
        for chunk in ids.chunked(10) {
            do {
                let answers = try await transport.batch(chunk.map { .message($0, format) }, work: work)
                for id in chunk {
                    switch answers[.message(id, format)] {
                    case .success(let answer)?:
                        if let message = answer.message { out[id.raw] = .success(message) } else {
                            out[id.raw] = .failure(GoogleAPIError(kind: .other, detail: "batch part without a message"))
                        }
                    case .failure(let error)?:
                        out[id.raw] = .failure(error)
                    case nil:
                        out[id.raw] = .failure(GoogleAPIError(kind: .temporary, detail: "batch part not answered"))
                    }
                }
            } catch let error as GoogleAPIError {
                for id in chunk { out[id.raw] = .failure(error) }
            } catch {
                for id in chunk { out[id.raw] = .failure(GoogleAPIError(kind: .temporary, detail: error.localizedDescription)) }
            }
        }
        return out
    }

    // MARK: - New mail (§4.7)

    /// Mail that arrived now: rules and mutes see it first, then what is still new goes out as
    /// `.newMessages` for the Inbox, exactly as the IMAP engine sends it, so notifications, the
    /// per-account setting and the sound work unchanged. Then it joins the newest 1,000, whose
    /// text its fetch already gave.
    func announce(_ messages: [GmailMessage], gmailNow: Date, report: inout GmailCheckReport) async {
        guard !messages.isEmpty else { return }
        let inbox = GmailLabelMapping.folderID(for: .inbox, entries: labelEntries, accountID: accountID, hints: folderHints)
        let own = ownAddresses()
        var arrivals: [GmailArrival] = []
        for message in messages {
            guard let ref = message.ref, let summary = GmailMessageBuilder.summary(message, accountID: accountID, folderID: inbox),
                  let date = message.receivedDate else { continue }
            let muted = await isMuted(summary)
            // HTML-only mail gives its text too, so a body condition matches it as on any account.
            let text = GmailMessageContent.textStage(message).message.bestText
            arrivals.append(GmailArrival(
                ref: ref, summary: summary, labels: message.labels, internalDate: date, textPlain: text,
                isAnnounced: GmailArrivalRule.announces(labels: message.labels, internalDate: date, from: summary.from.address,
                                                        gmailNow: gmailNow, ownAddresses: own, muted: muted),
                runsRules: GmailArrivalRule.runsRules(labels: message.labels, internalDate: date, from: summary.from.address,
                                                      gmailNow: gmailNow, ownAddresses: own)))
        }
        if let actions = parts.actions {
            let quiet = await actions.arrived(arrivals, engine: self)
            for i in arrivals.indices where quiet.contains(arrivals[i].ref.id) { arrivals[i].isAnnounced = false }
        }
        report.arrivals += arrivals
        let announced = arrivals.filter(\.isAnnounced).map(\.summary)
        if !announced.isEmpty {
            report.announced += announced
            emit(.newMessages(accountID: accountID, folderID: inbox, messages: announced))
        }
        var rows: [RowKey: MessageRowContent] = [:]
        for message in messages {
            if let row = GmailMessageBuilder.row(message, accountID: accountID) { rows[row.key] = row }
        }
        publishRows(rows)
        await keep(messages, work: .checks, members: nil)
    }

    /// Whether the conversation is muted, which only G5's mutes know; an engine without them
    /// mutes nothing.
    func isMuted(_ summary: MessageSummary) async -> Bool {
        await mutedCheck?(summary) ?? false
    }

    // MARK: - While the history cannot be used

    /// Every check while a resync runs, or waits for the six hours between full relistings: the
    /// newest 100 of All Mail (5 units), with any the index does not know checked for having
    /// arrived now. So new mail keeps arriving and being announced (§4.4 step 6).
    func topOfAllMailCheck(startedAt: Date, report: inout GmailCheckReport) async throws {
        report.lookedAtTop = true
        emit(.progress(accountID: accountID, text: "Checking \(account.email) for changes"))
        let page = try await transport.list(GmailListQuery(includeSpamTrash: true, maxResults: 100), work: .checks)
        var unknown: [GmailRef] = []
        for ref in page.refs {
            if let record = await store.record(for: ref.id), !record.attributes.contains(.tombstone) { continue }
            unknown.append(ref)
        }
        guard !unknown.isEmpty else { return }
        var placement = await place(unknown, hints: [:], startedAt: startedAt, deepAllowed: false)
        // Mail that did not arrive now is left for the listing, which places it where it belongs.
        placement.changes.removeAll { if case .awaitingPlacement = $0 { return true } else { return false } }
        placement.waiting = []
        if !placement.changes.isEmpty {
            try await store.commit(GmailJournalBatch(changes: placement.changes, cursor: cursor))
        }
        applyPlacementBookkeeping(placement, report: &report)
        publishIndexChange(ids: Set(placement.top.compactMap(\.gmailID)))
        await announce(placement.top, gmailNow: startedAt, report: &report)
    }

    /// Starts the listing a resync needs, unless one runs, or the last full relisting was less
    /// than six hours ago and the owner did not ask. A resync that began and was cut off always
    /// goes on, so the gap it covers is never skipped.
    func startResyncIfDue(askedByOwner: Bool) {
        guard relistTask == nil, state.backfill.map({ $0.phase == .complete }) ?? true else { return }
        if resyncBegan == nil {
            let last = state.lastFullRelist ?? .distantPast
            guard askedByOwner || now().timeIntervalSince(last) >= settings.fullRelistEvery else { return }
        }
        relistTask = Task {
            await self.runResync()
            self.relistEnded()
        }
    }

    func relistEnded() {
        relistTask = nil
    }

    /// §4.4: the cursor stays where it was until the listing has ended; removals are confirmed and
    /// journaled only with `resyncEnded`, in the flush that moves the cursor.
    func runResync() async {
        do {
            let target: HistoryID
            if let began = resyncBegan {
                target = began
            } else {
                let profile = try await transport.profile(work: .checks)
                guard let history = profile.historyID else { throw GoogleAPIError(kind: .other, detail: "profile without a history id") }
                target = history
                try await store.commit(GmailJournalBatch(changes: [.resyncBegan(history)], cursor: cursor))
                resyncBegan = history
                state.lastFullRelist = now()
                saveState(force: true)
            }
            resyncWanted = false
            let before = await transport.usage().totalUnits
            let result = try await relist(labels: labelChains(), allMail: true, replaceBits: true, confirmRemovals: true,
                                          work: .background(.index))
            try await store.commit(GmailJournalBatch(changes: result.changes + [.resyncEnded(target)], cursor: target))
            cursor = target
            resyncBegan = nil
            figures.resyncs += 1
            let units = await transport.usage().totalUnits - before
            Log.info("gmail", "resync reason=history404 removed=\(result.removed) added=\(result.added) units=\(units)")
            Log.warning("gmail", "\(account.email): listed the mailbox again after the history expired: \(result.removed) removed, \(result.added) added",
                        account: account, code: "resync")
            publishIndexChange(ids: [], everything: true)
            // Ends "Checking … for changes", which the status bar showed while it ran.
            emit(.finished(accountID: accountID))
            Task { await self.poke(reason: .schedule) }
        } catch is CancellationError {
            return
        } catch {
            Log.warning("gmail", "\(account.email): listing the mailbox again stopped; it goes on at the next check", error: error,
                        account: account, code: (error as? GoogleAPIError)?.kind.rawValue)
        }
    }

    // MARK: - Counts after a check

    /// `labels.get` for the labels whose bits a check changed, at most once a minute each: a label
    /// still being listed takes its count from it (§2.5, §4.2 step 6).
    func refreshCounts(of labels: Set<GmailLabelID>) {
        let current = now()
        let due = labels.filter { label in
            labelEntries.contains { $0.id == label && $0.isShown } &&
                current.timeIntervalSince(labelCountsAsked[label] ?? .distantPast) >= settings.labelCountsEvery
        }
        guard !due.isEmpty else { return }
        for label in due { labelCountsAsked[label] = current }
        Task { await self.askCounts(Array(due).sorted(), work: .background(.index)) }
    }

    /// Asks Gmail for labels' counts, 25 to a batch.
    @discardableResult
    func askCounts(_ labels: [GmailLabelID], work: WorkClass) async -> [GmailLabelID: GmailLabelCounts] {
        var out: [GmailLabelID: GmailLabelCounts] = [:]
        for chunk in labels.chunked(25) {
            guard let answers = try? await transport.batch(chunk.map { .label($0) }, work: work) else { continue }
            for label in chunk {
                if case .failure(let error)? = answers[.label(label)], error.kind == .notFound {
                    // The label went on another device: the labels are read again.
                    labelsListWanted = true
                    continue
                }
                guard case .success(let answer)? = answers[.label(label)], let found = answer.label else { continue }
                let counts = GmailLabelCounts(messagesTotal: found.messagesTotal ?? 0, messagesUnread: found.messagesUnread ?? 0,
                                              threadsTotal: found.threadsTotal, threadsUnread: found.threadsUnread, asOf: now())
                out[label] = counts
                labelCounts[label] = counts
            }
        }
        return out
    }

    /// A label the records name that the table does not hold was made on another device since
    /// the labels were read: they are read again, and a new shown label is listed.
    func noteLabelsNamed(_ labels: Set<GmailLabelID>) {
        let knownLabels = Set(labelEntries.map(\.id))
        if labels.contains(where: { $0.isUserLabel && !knownLabels.contains($0) }) { labelsListWanted = true }
    }
}
