import CryptoKit
import Foundation

// The first load (§3): the Inbox within about a second and a half, then the index of every message
// from list calls alone, its counts checked against Gmail's, and then the newest 1,000 kept on the
// Mac with their text. Every page of every listing is journaled on its own, so a quit or a crash
// resumes from the last page saved. The same listing machinery lists the mailbox again after the
// history expired (§4.4), during another app's import (§4.3) and when a count disagrees (§2.5).

// MARK: - Labels and folders

/// Gmail's labels as the owner's Legacy Outlook shows folders (§2.2).
public enum GmailLabelMapping {
    /// A folder's id when nothing earlier gave it one: the same on every Mac and every launch.
    public static func folderID(accountID: UUID, key: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data((accountID.uuidString + ":" + key).utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static let archiveKey = "ALL_MAIL"

    /// The [Gmail] group keeps the name the account used, such as `[Google Mail]`.
    public static func groupName(hints: [FolderInfo]) -> String {
        for folder in hints where folder.role != .inbox && folder.role != .other {
            if let range = folder.path.range(of: folder.delimiter.isEmpty ? "/" : folder.delimiter) {
                return String(folder.path[..<range.lowerBound])
            }
        }
        return "[Gmail]"
    }

    /// The folder id for a label: the one the account's IMAP folder of the same role or path had,
    /// so rules, move targets, the collapsed state and the selection survive the switch.
    public static func folderID(for label: GmailLabelID, entries: [GmailLabelEntry], accountID: UUID, hints: [FolderInfo]) -> UUID {
        if let entry = entries.first(where: { $0.id == label }) { return entry.folderID }
        return newFolderID(for: label, name: label.value, accountID: accountID, hints: hints)
    }

    public static func archiveFolderID(accountID: UUID, hints: [FolderInfo]) -> UUID {
        hints.first { $0.role == .all }?.id ?? folderID(accountID: accountID, key: archiveKey)
    }

    static func newFolderID(for label: GmailLabelID, name: String, accountID: UUID, hints: [FolderInfo]) -> UUID {
        if let system = GmailSystemFolder(label: label) {
            if let hint = hints.first(where: { $0.role == system.role }) { return hint.id }
        } else if label.isUserLabel, let hint = hints.first(where: { $0.role == .other && $0.path == name }) {
            return hint.id
        }
        return folderID(accountID: accountID, key: label.value)
    }

    /// The label table for Gmail's labels. A label already in the table keeps its folder and
    /// whether it is shown. Otherwise Gmail's system folders are shown; a user label is shown at
    /// the switch when the account's IMAP folders showed it, after the switch always, since it was
    /// made since, and for a new account when Gmail itself lists it.
    public static func entries(from labels: [GmailLabel], previous: [GmailLabelEntry], hints: [FolderInfo], accountID: UUID,
                               showsAll: Bool) -> [GmailLabelEntry] {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let switching = !hints.isEmpty
        return labels.map { label in
            let id = label.labelID
            let isUser = label.isUserLabel
            let shown: Bool
            if !isUser {
                shown = GmailSystemFolder(label: id) != nil
            } else if showsAll {
                shown = true
            } else if let kept = before[id] {
                shown = kept.isShown
            } else if !previous.isEmpty {
                shown = true
            } else if switching {
                shown = hints.contains { $0.role == .other && $0.path == label.name }
            } else {
                shown = label.labelListVisibility != "labelHide"
            }
            var entry = GmailLabelEntry(id: id, name: label.name, kind: isUser ? .user : .system,
                                        labelListVisibility: label.labelListVisibility,
                                        messageListVisibility: label.messageListVisibility, isShown: shown,
                                        folderID: before[id]?.folderID ?? newFolderID(for: id, name: label.name, accountID: accountID, hints: hints))
            entry.slot = before[id]?.slot
            entry.counts = before[id]?.counts
            entry.isComplete = before[id]?.isComplete ?? false
            return entry
        }
    }

    /// The sidebar's folders: Inbox, then the [Gmail] group in Outlook's order and names, then the
    /// shown user labels by name, nested by `/`. Counts come from the index for a label listed in
    /// full, and from Gmail's own count while it is being listed. Drafts counts its drafts, as
    /// Outlook does, in its unread count too, which is the number the sidebar shows.
    static func folders(entries: [GmailLabelEntry], accountID: UUID, hints: [FolderInfo], tally: GmailLabelTally,
                        counts: [GmailLabelID: GmailLabelCounts], allMailComplete: Bool) -> [FolderInfo] {
        let group = groupName(hints: hints)
        var out: [FolderInfo] = []
        func counted(_ entry: GmailLabelEntry) -> (total: Int, unread: Int) {
            if entry.isComplete { return (tally.total[entry.id] ?? 0, tally.unread[entry.id] ?? 0) }
            let gmail = counts[entry.id] ?? entry.counts
            return (gmail?.messagesTotal ?? tally.total[entry.id] ?? 0, gmail?.messagesUnread ?? tally.unread[entry.id] ?? 0)
        }
        for system in GmailSystemFolder.allCases {
            var folder: FolderInfo
            if let label = system.label {
                guard let entry = entries.first(where: { $0.id == label }) else { continue }
                let path = system == .inbox ? "INBOX" : "\(group)/\(system.outlookName)"
                folder = FolderInfo(id: entry.folderID, accountID: accountID, path: path, name: system.outlookName, delimiter: "/",
                                    role: system.role, attributes: [], isSelectable: true)
                folder.gmailLabelID = label
                let (total, unread) = counted(entry)
                folder.totalCount = total
                folder.unreadCount = system == .drafts ? total : unread
            } else {
                folder = FolderInfo(id: archiveFolderID(accountID: accountID, hints: hints), accountID: accountID,
                                    path: "\(group)/\(system.outlookName)", name: system.outlookName, delimiter: "/",
                                    role: system.role, attributes: [], isSelectable: true)
                folder.totalCount = tally.allMail
                folder.unreadCount = tally.allMailUnread
            }
            out.append(folder)
        }
        let user = entries.filter { $0.kind == .user && $0.isShown }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for entry in user {
            var folder = FolderInfo(id: entry.folderID, accountID: accountID, path: entry.name,
                                    name: entry.name.split(separator: "/").last.map(String.init) ?? entry.name, delimiter: "/",
                                    role: .other, attributes: [], isSelectable: true)
            folder.gmailLabelID = entry.id
            let (total, unread) = counted(entry)
            folder.totalCount = total
            folder.unreadCount = unread
            out.append(folder)
        }
        return out
    }
}

/// Counts from the index bits: for the sidebar, where a folder leaves out Junk Email, Deleted
/// Items and chats except in those folders themselves (§5.3); or to compare with Gmail's own
/// totals, by the rule Gmail counts by.
struct GmailLabelTally: Sendable {
    var total: [GmailLabelID: Int] = [:]
    var unread: [GmailLabelID: Int] = [:]
    var allMail = 0
    var allMailUnread = 0

    init(snapshot: GmailIndexSnapshot, forFolders: Bool, rule: GmailCountRule) {
        var labelForBit = [GmailLabelID?](repeating: nil, count: GmailLabelID.slotCount)
        for (label, bit) in snapshot.labelSlots where bit < GmailLabelID.slotCount { labelForBit[bit] = label }
        let spamBit = UInt64(1) << UInt64(GmailLabelID.spam.fixedSlot ?? 3)
        let trashBit = UInt64(1) << UInt64(GmailLabelID.trash.fixedSlot ?? 4)
        let chatBit = UInt64(1) << UInt64(GmailLabelID.chat.fixedSlot ?? 13)
        let unreadBit = UInt64(1) << UInt64(GmailLabelID.unread.fixedSlot ?? 5)
        var totals = [Int](repeating: 0, count: GmailLabelID.slotCount)
        var unreads = [Int](repeating: 0, count: GmailLabelID.slotCount)

        func counts(label: GmailLabelID, bits: UInt64) -> Bool {
            let junkOrDeleted = bits & (spamBit | trashBit) != 0
            if label == .spam || label == .trash { return true }
            if forFolders { return !junkOrDeleted && bits & chatBit == 0 }
            return rule.labelTotalsCountJunkAndDeleted || !junkOrDeleted
        }

        for slot in snapshot.byOrder {
            let record = snapshot.records[Int(slot)]
            if forFolders && record.attributes.contains(.provisional) { continue }
            let bits = record.labelBits
            let junkOrDeleted = bits & (spamBit | trashBit) != 0
            let isUnread = bits & unreadBit != 0
            if forFolders ? (!junkOrDeleted && bits & chatBit == 0) : (rule.profileTotalCountsJunkAndDeleted || !junkOrDeleted) {
                allMail += 1
                if isUnread { allMailUnread += 1 }
            }
            var rest = bits
            while rest != 0 {
                let bit = rest.trailingZeroBitCount
                rest &= rest - 1
                guard let label = labelForBit[bit], counts(label: label, bits: bits) else { continue }
                totals[bit] += 1
                if isUnread { unreads[bit] += 1 }
            }
        }
        for (bit, label) in labelForBit.enumerated() {
            guard let label, totals[bit] > 0 else { continue }
            total[label] = totals[bit]
            unread[label] = unreads[bit]
        }
        for (label, members) in snapshot.overflow {
            var count = 0
            var unreadCount = 0
            for slot in members {
                let record = snapshot.records[Int(slot)]
                if record.attributes.contains(.tombstone) || (forFolders && record.attributes.contains(.provisional)) { continue }
                guard counts(label: label, bits: record.labelBits) else { continue }
                count += 1
                if record.labelBits & unreadBit != 0 { unreadCount += 1 }
            }
            total[label] = count
            unread[label] = unreadCount
        }
    }
}

// MARK: - Listings

/// One listing to run: a chain, where it resumes, and what each page tells the index.
struct GmailChainPlan: Sendable {
    var chain: GmailListingChain
    var run: UInt32
    var token: String?
    /// Listed already in this run, which sets the order of the next page's first message.
    var listed: Int
    /// For All Mail: the order of the newest message the run lists.
    var top: UInt32?
    var labels: Set<GmailLabelID>
    var query: GmailListQuery
    /// Keep the ids listed, to compare with the index afterwards.
    var collects: Bool
}

/// What listing the mailbox again decided.
struct GmailRelistResult: Sendable {
    var changes: [GmailChange] = []
    var added = 0
    var removed = 0
}

/// Date groups' boundaries (§5.6): Today, Yesterday, Earlier this week, Earlier this month, then
/// one per month back to the month of the oldest message.
public enum GmailDateGroups {
    public static func boundaries(now: Date, oldest: Date?, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        var out: Set<Date> = [today]
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) { out.insert(yesterday) }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start { out.insert(week) }
        guard let month = calendar.dateInterval(of: .month, for: now)?.start else { return out.sorted(by: >) }
        out.insert(month)
        let floor = oldest.flatMap { calendar.dateInterval(of: .month, for: $0)?.start } ?? month
        var cursor = month
        while cursor > floor, let previous = calendar.date(byAdding: .month, value: -1, to: cursor) {
            out.insert(previous)
            cursor = previous
        }
        return out.filter { $0 <= today }.sorted(by: >)
    }

    /// The four that move every day, asked again at local midnight.
    public static func recent(now: Date, calendar: Calendar = .current) -> [Date] {
        Array(boundaries(now: now, oldest: now, calendar: calendar).prefix(4))
    }
}

extension GmailAccountEngine {
    // MARK: - Chains

    /// Every label list the index is built from, apart from All Mail: the system labels with a
    /// bit, the Inbox with each of the four categories that make Other and Updates, every shown
    /// user label, and chats if Gmail lists them. Junk Email and Deleted Items are included in each,
    /// so the bits stay exact for mail in them.
    func labelChains() -> [GmailListingChain] {
        var chains: [GmailListingChain] = [.inbox, .sent, .unread, .starred, .important, .draft, .spam, .trash].map { .label($0) }
        chains += [GmailLabelID.categorySocial, .categoryPromotions, .categoryUpdates, .categoryForums].map { .labels([.inbox, $0]) }
        chains += labelEntries.filter { $0.kind == .user && $0.isShown }.sorted { $0.name < $1.name }.map { .label($0.id) }
        if settings.listsChats { chains.append(.label(.chat)) }
        return chains
    }

    func plan(_ chain: GmailListingChain, run: UInt32, top: UInt32? = nil, collects: Bool) -> GmailChainPlan {
        var query = GmailListQuery(includeSpamTrash: true, maxResults: settings.pageSize)
        var labels: Set<GmailLabelID> = []
        switch chain {
        case .allMail(let after, let before):
            let terms = [after.map { "after:\(Int($0.timeIntervalSince1970))" }, before.map { "before:\(Int($0.timeIntervalSince1970))" }]
                .compactMap { $0 }
            query.query = terms.isEmpty ? nil : terms.joined(separator: " ")
        case .label(let label):
            query.labels = [label]
            labels = [label]
        case .labels(let all):
            query.labels = all
            labels = Set(all)
        case .search(let q):
            query.query = q
        }
        return GmailChainPlan(chain: chain, run: run, token: nil, listed: 0, top: top, labels: labels, query: query, collects: collects)
    }

    /// Whether All Mail has been listed in full, so every message has its place and deep mail can
    /// be put beside its neighbour.
    var allMailComplete: Bool {
        guard let backfill = state.backfill else { return false }
        if backfill.phase != .listing { return true }
        let bands = backfill.bands.filter { $0.run == backfill.run }
        return !bands.isEmpty && bands.allSatisfy { chainProgress[$0.chain]?.run == $0.run && chainProgress[$0.chain]?.isComplete == true }
    }

    /// The next run number for a chain, so a relisting's pages are told from an earlier run's.
    func nextRun(for chains: [GmailListingChain]) -> UInt32 {
        (chains.compactMap { chainProgress[$0]?.run }.max() ?? 0) &+ 1
    }

    /// Runs listings side by side, several chains at once: the transport decides how many requests
    /// are really in flight, and background work never holds more than two. Returns the ids each
    /// collecting chain listed.
    func runChains(_ plans: [GmailChainPlan], work: WorkClass) async throws -> [GmailListingChain: Set<UInt64>] {
        var out: [GmailListingChain: Set<UInt64>] = [:]
        try await withThrowingTaskGroup(of: (GmailListingChain, Set<UInt64>).self) { group in
            var queue = plans[...]
            for _ in 0..<min(max(1, settings.chainsAtOnce), plans.count) {
                if let next = queue.popFirst() { group.addTask { try await self.runChain(next, work: work) } }
            }
            for try await (chain, ids) in group {
                if !ids.isEmpty { out[chain] = ids }
                if let next = queue.popFirst() { group.addTask { try await self.runChain(next, work: work) } }
            }
        }
        return out
    }

    /// Lists one chain to its end, one journaled page at a time. A page token Gmail no longer takes
    /// starts the chain again from the top, once; what is stored already stays.
    func runChain(_ plan: GmailChainPlan, work: WorkClass) async throws -> (GmailListingChain, Set<UInt64>) {
        var token = plan.token
        var listed = plan.listed
        var ids: Set<UInt64> = []
        var restarted = false
        while true {
            try Task.checkCancellation()
            var query = plan.query
            query.pageToken = token
            let page: GmailListPage
            do {
                page = try await transport.list(query, work: work)
            } catch let error as GoogleAPIError where token != nil && !restarted && error.kind == .other && error.httpStatus == 400 {
                Log.info("gmail", "\(account.email): a listing's page token was refused; listing that chain from the top")
                token = nil
                listed = 0
                restarted = true
                continue
            }
            var refs = page.refs
            if !plan.labels.isEmpty, !held.isEmpty {
                // A change the owner made and Gmail has not confirmed wins over what the list says.
                refs = refs.filter { ref in !plan.labels.contains { held.protects(ref.id, $0) != nil } }
            }
            var first: UInt32?
            var step = GmailOrderSpace.step
            if let top = plan.top {
                let used = UInt64(listed) * UInt64(step)
                let start = UInt64(top) > used ? UInt64(top) - used : UInt64(step) * UInt64(refs.count + 1)
                if start < UInt64(step) * UInt64(refs.count + 1) {
                    step = UInt32(max(1, start / UInt64(refs.count + 1)))
                }
                first = UInt32(start)
            }
            try await store.appendListingPage(GmailListingPage(chain: plan.chain, run: plan.run, pageToken: token,
                                                               nextPageToken: page.nextPageToken, refs: refs, firstOrder: first,
                                                               orderStep: step, labels: plan.labels))
            listed += page.refs.count
            chainProgress[plan.chain] = GmailChainProgress(run: plan.run, nextPageToken: page.nextPageToken,
                                                           isComplete: page.nextPageToken == nil, listed: listed)
            if plan.collects { ids.formUnion(page.refs.map(\.id.raw)) }
            if plan.top != nil {
                await settleProvisional(page.refs)
                reportListingProgress()
            }
            token = page.nextPageToken
            if token == nil { break }
        }
        return (plan.chain, ids)
    }

    /// Messages another app imported, which a check left provisional, have their place once All
    /// Mail lists them, and are shown from then on.
    private func settleProvisional(_ refs: [GmailRef]) async {
        let settled = refs.filter { provisional.contains($0.id.raw) }
        guard !settled.isEmpty else { return }
        do {
            try await store.commit(GmailJournalBatch(changes: settled.map { .attributes($0.id, setting: [], clearing: .provisional) }))
            for ref in settled { provisional.remove(ref.id.raw) }
            placedDuringRelist?.formUnion(settled.map(\.id.raw))
        } catch {
            Log.warning("gmail", "\(account.email): imported messages could not be shown yet", error: error, account: account)
        }
    }

    /// The status bar's progress while All Mail is listed, in FalconMail's existing words.
    private func reportListingProgress() {
        guard let backfill = state.backfill, backfill.phase == .listing else { return }
        let listed = backfill.bands.filter { $0.run == backfill.run }.reduce(0) { $0 + (chainProgress[$1.chain]?.listed ?? 0) }
        let total = max(backfill.total, listed)
        emit(.progress(accountID: accountID, text: "Syncing \(account.email): \(listed.formatted()) of \(total.formatted()) messages"))
    }

    /// Lists chains again and compares them with the index. New messages go in with their listed
    /// place. With `replaceBits`, each label's bits become its listing, except where a change of
    /// the owner's is held. With `confirmRemovals`, messages All Mail no longer lists are only
    /// candidates: each is confirmed gone, by a 404 or, with many, by a second listing, before it
    /// becomes a tombstone. Nothing placed while the listing ran is touched. The changes are
    /// returned for the caller to journal with its cursor.
    func relist(labels chains: [GmailListingChain], allMail: Bool, replaceBits: Bool, confirmRemovals: Bool,
                work: WorkClass) async throws -> GmailRelistResult {
        placedDuringRelist = placedDuringRelist ?? []
        defer { placedDuringRelist = nil }
        let before = await store.index()
        var plans: [GmailChainPlan] = []
        let allMailChain = GmailListingChain.allMail(after: nil, before: nil)
        if allMail {
            let total = try await transport.profile(work: work).messagesTotal ?? before.byOrder.count
            let band = GmailOrderSpace.band(for: total, above: ceiling)
            ceiling = band.top
            plans.append(plan(allMailChain, run: nextRun(for: [allMailChain]), top: band.top, collects: true))
        }
        plans += chains.map { plan($0, run: nextRun(for: [$0]), collects: replaceBits) }
        let listed = try await runChains(plans, work: work)
        var result = GmailRelistResult()
        let after = await store.index()
        let fresh = placedDuringRelist ?? []

        if allMail, let all = listed[allMailChain] {
            result.added = all.filter { raw in before.slotByID[raw].map { before.records[Int($0)].attributes.contains(.tombstone) } ?? true }.count
            if confirmRemovals {
                var candidates: [GmailMessageID] = []
                for slot in after.byOrder {
                    let record = after.records[Int(slot)]
                    if all.contains(record.id) || fresh.contains(record.id) || record.attributes.contains(.provisional) { continue }
                    candidates.append(record.gmailID)
                }
                let gone = try await confirmGone(candidates, work: work)
                result.changes += gone.map { .tombstone($0) }
                result.removed = gone.count
            }
        }
        if replaceBits {
            let inboxListed = listed[.label(.inbox)]
            for chain in chains {
                let members = listed[chain] ?? []
                let label: GmailLabelID
                switch chain {
                case .label(let l): label = l
                case .labels(let all) where all.count == 2 && all.contains(.inbox):
                    guard let category = all.first(where: { $0 != .inbox }), let inboxListed else { continue }
                    for slot in after.byOrder {
                        let record = after.records[Int(slot)]
                        guard after.record(atSlot: slot, has: category), inboxListed.contains(record.id), !members.contains(record.id),
                              !fresh.contains(record.id), held.protects(record.gmailID, category) == nil else { continue }
                        result.changes.append(.relabel(record.gmailID, adding: [], removing: [category]))
                    }
                    continue
                default: continue
                }
                for slot in after.byOrder {
                    let record = after.records[Int(slot)]
                    guard !members.contains(record.id), !fresh.contains(record.id), !record.attributes.contains(.provisional),
                          after.record(atSlot: slot, has: label), held.protects(record.gmailID, label) == nil else { continue }
                    result.changes.append(.relabel(record.gmailID, adding: [], removing: [label]))
                }
            }
        }
        return result
    }

    /// Which candidates are really gone: one `format=minimal` each, where a 404 means gone, or,
    /// with many, a second listing of All Mail, where gone means absent from both.
    func confirmGone(_ candidates: [GmailMessageID], work: WorkClass) async throws -> [GmailMessageID] {
        guard !candidates.isEmpty else { return [] }
        if candidates.count > settings.confirmByListingAbove {
            var listed: Set<UInt64> = []
            var token: String?
            repeat {
                let page = try await transport.list(GmailListQuery(includeSpamTrash: true, maxResults: settings.pageSize, pageToken: token),
                                                    work: work)
                listed.formUnion(page.refs.map(\.id.raw))
                token = page.nextPageToken
            } while token != nil
            return candidates.filter { !listed.contains($0.raw) }
        }
        let answers = await fetch(candidates, format: .minimal, work: work)
        return candidates.filter {
            if case .failure(let error)? = answers[$0.raw], error.kind == .notFound { return true }
            return false
        }
    }

    // MARK: - The first load

    func runBackfill() async {
        await loadIfNeeded()
        do {
            if cursor == nil || state.backfill == nil { try await backfillStart() }
            guard state.backfill != nil else { return }
            if state.backfill?.phase == .listing {
                try await backfillListing()
                state.backfill?.phase = .counting
                saveState(force: true)
            }
            if state.backfill?.phase == .counting {
                try await checkCounts(work: .background(.index))
                state.backfill?.phase = .replaying
                saveState(force: true)
            }
            if state.dateGroupsWanted == true { try await refreshDateAnchors(only: nil) }
            if state.backfill?.phase == .replaying, let start = state.backfill?.startHistory {
                let report = await exclusively { await self.replay(from: start) }
                if let failure = report.failure { throw failure }
                state.backfill?.phase = .complete
                saveState(force: true)
            }
            await markListedLabelsComplete()
            publishIndexChange(ids: [], everything: true)
            Log.info("gmail", "\(account.email): every message is listed")
            backfillTask = nil
            startCacheFill()
        } catch is CancellationError {
            backfillTask = nil
        } catch {
            backfillTask = nil
            backfillRetryAt = now().addingTimeInterval(60)
            Log.warning("gmail", "\(account.email): listing the mailbox stopped; it goes on in a minute", error: error, account: account,
                        code: (error as? GoogleAPIError)?.kind.rawValue)
        }
    }

    /// Steps 0 to 2: the address, the labels, the base cursor, the counts and the Inbox's first
    /// screen. Checks for new mail start as soon as the cursor is saved.
    func backfillStart() async throws {
        let profile = try await transport.profile(work: .interactive)
        guard profile.emailAddress.caseInsensitiveCompare(account.email) == .orderedSame else {
            let sentence = "\(account.email) needs you to sign in again."
            Log.error("gmail", "\(account.email): Gmail answered for a different address", account: account, code: "needsSignIn")
            backfillRetryAt = .distantFuture
            setHealth(.needsSignIn)
            emit(.error(accountID: accountID, message: sentence))
            schedule.stop(true)
            throw CancellationError()
        }
        guard let start = profile.historyID else { throw GoogleAPIError(kind: .other, detail: "profile without a history id") }
        let labels = try await transport.labels(work: .interactive)
        labelEntries = try await store.saveLabelTable(GmailLabelMapping.entries(from: labels, previous: labelEntries, hints: folderHints,
                                                                               accountID: accountID, showsAll: settings.showsAllLabels))
        // The counts, and the Inbox's first page, side by side.
        let transport = self.transport
        let pageSize = min(100, settings.pageSize)
        async let inboxPage = transport.list(GmailListQuery(labels: [.inbox], maxResults: pageSize), work: .interactive)
        let shown = labelEntries.filter { $0.isShown || $0.id.fixedSlot != nil }.map(\.id)
        let counts = await askCounts(shown, work: .interactive)
        var entries = labelEntries
        for i in entries.indices { if let found = counts[entries[i].id] { entries[i].counts = found } }
        labelEntries = try await store.saveLabelTable(entries)
        try await store.commit(GmailJournalBatch(changes: [], cursor: start))
        cursor = cursor.map { max($0, start) } ?? start
        state.backfill = GmailEngineState.Backfill(startHistory: start, startedAt: await gmailNow(),
                                                   run: nextRun(for: [.allMail(after: nil, before: nil)]), bands: [],
                                                   phase: .listing, total: profile.messagesTotal ?? 0)
        saveState(force: true)
        wakeLoop()
        await firstScreen(try await inboxPage.refs)
    }

    /// Step 2: the text of the rows the Inbox shows first, in one batch: a conversation with more
    /// than one message on the page is fetched whole (40 units), any other row alone (20).
    func firstScreen(_ refs: [GmailRef]) async {
        var threads: [GmailThreadID] = []
        var members: [GmailThreadID: [GmailRef]] = [:]
        for ref in refs {
            if members[ref.threadID] == nil { threads.append(ref.threadID) }
            members[ref.threadID, default: []].append(ref)
        }
        let shown = threads.prefix(settings.firstScreenRows)
        let parts: [GmailBatchPart] = shown.map { thread in
            let refs = members[thread] ?? []
            return refs.count > 1 ? .thread(thread, .metadata(headers: GmailMessageBuilder.headers)) : .message(refs[0].id, .metadata(headers: GmailMessageBuilder.headers))
        }
        guard !parts.isEmpty, let answers = try? await transport.batch(parts, work: .interactive) else { return }
        var rows: [RowKey: MessageRowContent] = [:]
        var summaries: [GmailThreadSummary] = []
        for part in parts {
            guard case .success(let answer)? = answers[part] else { continue }
            switch answer {
            case .message(let message):
                if let row = GmailMessageBuilder.row(message, accountID: accountID) { rows[row.key] = row }
            case .thread(let thread):
                guard let summary = GmailMessageBuilder.threadSummary(thread),
                      let newest = (thread.messages ?? []).filter({ $0.labels.contains(.inbox) }).max(by: {
                          ($0.receivedDate ?? .distantPast) < ($1.receivedDate ?? .distantPast)
                      }),
                      var row = GmailMessageBuilder.row(newest, accountID: accountID) else { continue }
                row.conversation = ConversationContent(
                    senders: summary.senders, messageCount: summary.messageCount, newestDate: summary.newestDate,
                    members: summary.members.map { ConversationMember(key: .gmail(account: accountID, id: $0.id), from: $0.from, date: $0.date) })
                rows[row.key] = row
                summaries.append(summary)
            case .label:
                continue
            }
        }
        if !summaries.isEmpty { try? await store.saveThreadSummaries(summaries) }
        publishRows(rows)
    }

    /// Step 3: All Mail, in slices by year when the mailbox is large, and every label list, side by
    /// side, with the selected folder's list first. A listing that stopped resumes from its last
    /// saved page. Messages a label listed that All Mail never placed are placed one by one.
    func backfillListing() async throws {
        guard var backfill = state.backfill else { return }
        if backfill.bands.isEmpty {
            backfill.bands = allMailBands(total: backfill.total, run: backfill.run)
            ceiling = max(ceiling, backfill.bands.map(\.top).max() ?? ceiling)
            state.backfill = backfill
            saveState(force: true)
        }
        var plans: [GmailChainPlan] = backfill.bands.map { plan($0.chain, run: $0.run, top: $0.top, collects: true) }
        let selected: GmailLabelID? = selectedLabel ?? .inbox
        var labels = labelChains()
        if let selected, let at = labels.firstIndex(of: .label(selected)) { labels.insert(labels.remove(at: at), at: 0) }
        plans += labels.map { plan($0, run: backfill.run, collects: true) }
        plans = plans.compactMap { plan in
            var plan = plan
            guard let progress = chainProgress[plan.chain], progress.run == plan.run else { return plan }
            if progress.isComplete { return nil }
            plan.token = progress.nextPageToken
            plan.listed = progress.listed
            return plan
        }
        let listed = try await runChains(plans, work: .background(.index))

        // Ids a label listed that the index still lacks: All Mail skipped them, as happens when
        // mail comes or goes above the page being read. They are placed, never ignored.
        let snapshot = await store.index()
        var missing: [GmailMessageID] = []
        var seen: Set<UInt64> = []
        for (chain, ids) in listed {
            if case .allMail = chain { continue }
            for raw in ids where seen.insert(raw).inserted && snapshot.slotByID[raw] == nil { missing.append(GmailMessageID(raw: raw)) }
        }
        missing.sort()
        guard !missing.isEmpty else { return }
        Log.info("gmail", "\(account.email): \(missing.count) messages listed in a folder but not in All Mail; placing them")
        try await placeListedOnly(missing, work: .background(.index))
    }

    /// Places messages the index lacks although a listing named them.
    func placeListedOnly(_ ids: [GmailMessageID], work: WorkClass) async throws {
        let answers = await fetch(ids, format: .minimal, work: work)
        var items: [GmailDeepPlacement] = []
        var changes: [GmailChange] = []
        for id in ids {
            switch answers[id.raw] {
            case .success(let message)?:
                guard let ref = message.ref, let date = message.receivedDate else { continue }
                items.append(GmailDeepPlacement(ref: ref, labels: message.labels, internalDate: date, attributes: Self.attributes(of: message)))
            case .failure(let error)? where error.kind == .notFound:
                changes.append(.tombstone(id))
            default:
                continue
            }
        }
        let placed = await deepChanges(for: items, work: work)
        changes += placed.changes + placed.waiting.map { .awaitingPlacement($0) }
        for ref in placed.waiting { awaiting[ref.id.raw] = ref }
        guard !changes.isEmpty else { return }
        try await store.commit(GmailJournalBatch(changes: changes, cursor: cursor))
    }

    /// The bands All Mail's orders take: one for a mailbox of 50,000 or fewer; otherwise one per
    /// year, listed side by side, stacked oldest lowest, each big enough for the whole mailbox so
    /// no slice can run into the next.
    func allMailBands(total: Int, run: UInt32) -> [GmailEngineState.Band] {
        guard total > settings.sliceAbove, settings.sliceYears > 0 else {
            let band = GmailOrderSpace.band(for: total, above: ceiling)
            return [GmailEngineState.Band(chain: .allMail(after: nil, before: nil), run: run, top: band.top)]
        }
        let calendar = Calendar(identifier: .gregorian)
        let current = now()
        var edges: [Date] = []
        for years in 1...settings.sliceYears {
            if let edge = calendar.date(byAdding: .year, value: -years, to: current) { edges.append(edge) }
        }
        // Oldest slice first, so its band is lowest.
        var slices: [GmailListingChain] = [.allMail(after: nil, before: edges.last)]
        for i in stride(from: edges.count - 1, to: 0, by: -1) { slices.append(.allMail(after: edges[i], before: edges[i - 1])) }
        slices.append(.allMail(after: edges.first, before: nil))
        var bands: [GmailEngineState.Band] = []
        var top = ceiling
        for chain in slices {
            let band = GmailOrderSpace.band(for: total, above: top)
            top = band.top
            bands.append(GmailEngineState.Band(chain: chain, run: run, top: band.top))
        }
        return bands.reversed()
    }

    /// Step 7: the changes made while the mailbox was listed, applied again from the start, so a
    /// page read just before a change and saved just after it cannot leave a stale bit. Applying
    /// a change twice changes nothing.
    func replay(from start: HistoryID) async -> GmailCheckReport {
        var report = GmailCheckReport(reason: .schedule)
        let startedAt = await gmailNow()
        do {
            try await historyCheck(from: start, startedAt: startedAt, report: &report)
        } catch let error as GoogleAPIError where error.kind == .historyExpired {
            resyncWanted = true
        } catch let error as GoogleAPIError {
            report.failure = error
        } catch {
            report.failure = GoogleAPIError(kind: .temporary, detail: error.localizedDescription)
        }
        return report
    }

    func markListedLabelsComplete() async {
        var entries = labelEntries
        var changed = false
        for i in entries.indices where !entries[i].isComplete {
            if chainProgress[.label(entries[i].id)]?.isComplete == true {
                entries[i].isComplete = true
                changed = true
            }
            if let counts = labelCounts[entries[i].id] { entries[i].counts = counts }
        }
        guard changed else { return }
        do { labelEntries = try await store.saveLabelTable(entries) } catch {
            Log.warning("gmail", "\(account.email): the label table could not be saved", error: error, account: account)
        }
    }

    // MARK: - Checking the counts (§2.5, §3 step 4)

    /// Each label's bits against Gmail's own count, and All Mail against the profile's, by the
    /// rule the probe found for Junk Email and Deleted Items. A check just before brings the index
    /// up to Gmail's state, and one just after says how much changed while the counts were asked;
    /// a list that differs by more than that is listed again, which a skipped page or a missed
    /// change leaves no other way to repair.
    func checkCounts(work: WorkClass) async throws {
        let first = await check(reason: .schedule)
        if let failure = first.failure { throw failure }
        let profile = try await transport.profile(work: work)
        let comparable = labelChains().compactMap { chain -> GmailLabelID? in
            if case .label(let label) = chain { return label }
            return nil
        }
        let counts = await askCounts(comparable, work: work)
        let after = await check(reason: .schedule)
        if let failure = after.failure { throw failure }
        let snapshot = await store.index()
        let tally = GmailLabelTally(snapshot: snapshot, forFolders: false, rule: settings.countRule)
        var mismatched: [GmailListingChain] = []
        for label in comparable {
            guard let gmail = counts[label] else { continue }
            let bits = tally.total[label] ?? 0
            if abs(bits - gmail.messagesTotal) > (after.labelEvents[label] ?? 0) {
                Log.info("gmail", "\(account.email): label count differs (index \(bits), Gmail \(gmail.messagesTotal)); listing it again")
                mismatched.append(.label(label))
            }
        }
        var allMail = false
        if let total = profile.messagesTotal, abs(tally.allMail - total) > after.messageEvents {
            Log.info("gmail", "\(account.email): All Mail differs (index \(tally.allMail), Gmail \(total)); listing it again")
            allMail = true
        }
        guard !mismatched.isEmpty || allMail else { return }
        let result = try await relist(labels: mismatched, allMail: allMail, replaceBits: true, confirmRemovals: allMail, work: work)
        if !result.changes.isEmpty { try await store.commit(GmailJournalBatch(changes: result.changes, cursor: cursor)) }
        publishIndexChange(ids: [], everything: true)
    }

    // MARK: - Date anchors (§5.6)

    /// Turns date groups on or off. When on, each boundary's anchor is found with one `before:`
    /// search (5 units), and the four that move every day are asked again at local midnight.
    public func setDateGroupsWanted(_ wanted: Bool) {
        let was = state.dateGroupsWanted == true
        state.dateGroupsWanted = wanted
        saveState(force: true)
        guard wanted, !was, state.backfill?.phase == .complete else { return }
        Task { try? await self.refreshDateAnchors(only: nil) }
    }

    /// Asks the anchor of each boundary in `only`, or of every boundary back to the oldest message.
    func refreshDateAnchors(only: [Date]?) async throws {
        let boundaries: [Date]
        if let only {
            boundaries = only
        } else {
            let snapshot = await store.index()
            var oldest: Date?
            if let slot = liveOrder(snapshot).first {
                oldest = try? await transport.message(snapshot.records[Int(slot)].gmailID, format: .minimal, work: .background(.index)).receivedDate
            }
            boundaries = GmailDateGroups.boundaries(now: now(), oldest: oldest)
        }
        var anchors = Dictionary((await store.dateAnchors()).map { ($0.boundary, $0) }, uniquingKeysWith: { a, _ in a })
        for boundary in boundaries {
            let page = try await transport.list(GmailListQuery(query: "before:\(Int(boundary.timeIntervalSince1970))", includeSpamTrash: true,
                                                               maxResults: 1), work: .background(.index))
            let ref = page.refs.first
            let order: UInt32?
            if let ref { order = await store.record(for: ref.id)?.order } else { order = nil }
            anchors[boundary] = GmailDateAnchor(boundary: boundary, id: ref?.id, order: order, askedAt: now())
        }
        try await store.saveDateAnchors(anchors.values.sorted { $0.boundary > $1.boundary })
        state.anchorsDay = Calendar.current.startOfDay(for: now())
        saveState(force: true)
    }

    /// After mail was placed deep, only a boundary with a newly placed message directly above its
    /// anchor can have moved, so only those are asked again.
    func refreshAnchors(near placed: Set<UInt64>) async {
        guard state.dateGroupsWanted == true, !placed.isEmpty else { return }
        let anchors = await store.dateAnchors()
        guard !anchors.isEmpty else { return }
        let snapshot = await store.index()
        let ordered = liveOrder(snapshot)
        var position: [UInt64: Int] = [:]
        for (i, slot) in ordered.enumerated() { position[snapshot.records[Int(slot)].id] = i }
        var moved: [Date] = []
        for anchor in anchors {
            let above: Int
            if let id = anchor.id { guard let at = position[id.raw] else { moved.append(anchor.boundary); continue }; above = at + 1 } else { above = 0 }
            if above < ordered.count, placed.contains(snapshot.records[Int(ordered[above])].id) { moved.append(anchor.boundary) }
        }
        guard !moved.isEmpty else { return }
        try? await refreshDateAnchors(only: moved)
    }

    // MARK: - The newest 1,000 (§2.4, §3 step 6)

    /// Starts keeping the newest 1,000 on the Mac, unless it runs already or another app is
    /// importing, which it waits out.
    public func startCacheFill() {
        guard settings.fillsCache, running, cacheTask == nil, !flood.isActive, state.backfill?.phase == .complete else { return }
        cacheTask = Task {
            await self.fillCache()
            self.cacheFillEnded()
        }
    }

    private func cacheFillEnded() { cacheTask = nil }

    /// `format=full` in batches of 10, most wanted first: drafts and messages in use, the first
    /// screens of the Inbox and the folders used most, then the newest. Then each conversation
    /// that has a message kept gets its summary, from the kept rows when all its messages are
    /// kept, and otherwise from one `threads.get`.
    func fillCache() async {
        var fetched: Set<UInt64> = []
        while running, !Task.isCancelled, !flood.isActive {
            let wanted = await store.messagesToCache(limit: 1_000).filter { !fetched.contains($0.raw) }
            guard !wanted.isEmpty else { return }
            let snapshot = await store.index()
            let threads = threadMembers(snapshot)
            var progressed = false
            for chunk in wanted.chunked(max(1, settings.cacheBatch)) {
                guard running, !Task.isCancelled, !flood.isActive else { return }
                let answers = await fetch(chunk, format: .full, work: .background(.cacheFill))
                var messages: [GmailMessage] = []
                var gone: [GmailMessageID] = []
                for id in chunk {
                    fetched.insert(id.raw)
                    switch answers[id.raw] {
                    case .success(let message)?: messages.append(message)
                    case .failure(let error)? where error.kind == .notFound: gone.append(id)
                    default: continue
                    }
                }
                if !gone.isEmpty { try? await store.commit(GmailJournalBatch(changes: gone.map { .tombstone($0) })) }
                guard !messages.isEmpty else { continue }
                progressed = true
                await keep(messages, work: .background(.cacheFill), members: threads)
            }
            if !progressed { return }
        }
    }

    /// Each thread's messages in the index, from one snapshot.
    func threadMembers(_ snapshot: GmailIndexSnapshot) -> [UInt64: [GmailMessageID]] {
        var out: [UInt64: [GmailMessageID]] = [:]
        for slot in snapshot.byOrder {
            let record = snapshot.records[Int(slot)]
            out[record.threadID, default: []].append(record.gmailID)
        }
        return out
    }

    /// Keeps messages whose whole text was fetched among the newest 1,000, with their pictures.
    /// Junk Email and Deleted Items are never kept.
    func keep(_ messages: [GmailMessage], work: WorkClass, members: [UInt64: [GmailMessageID]]?) async {
        var evicted: [GmailMessageID] = []
        var threads: Set<GmailThreadID> = []
        for message in messages where message.labels.isDisjoint(with: [.spam, .trash]) {
            var opened = GmailMessageContent.textStage(message)
            opened = await withPictures(opened, answer: message, work: work, limit: 1)
            guard let built = GmailMessageBuilder.cached(message, opened: opened, now: now()) else { continue }
            do {
                evicted += try await store.cache(built.message, body: built.body)
                threads.insert(built.message.threadID)
            } catch {
                Log.warning("gmail", "\(account.email): a message could not be kept on this Mac", error: error, account: account)
            }
        }
        await settleSummaries(for: threads, evicted: evicted, work: work, members: members)
    }

    /// Keeps each conversation's summary current: made again for conversations that gained a kept
    /// message, and dropped for those left with none.
    func settleSummaries(for threads: Set<GmailThreadID>, evicted: [GmailMessageID], work: WorkClass,
                         members given: [UInt64: [GmailMessageID]]? = nil) async {
        guard !threads.isEmpty || !evicted.isEmpty else { return }
        var members = given ?? [:]
        if given == nil { members = threadMembers(await store.index()) }
        var summaries: [GmailThreadSummary] = []
        let kept = await store.threadSummaries(Array(threads))
        for thread in threads {
            let ids = members[thread.raw] ?? []
            // A summary that already names every message of the conversation, such as the one the
            // first screen kept, is still right.
            if let summary = kept[thread], Set(summary.members.map(\.id)) == Set(ids) { continue }
            let cached = await store.cachedMessages(ids)
            if !ids.isEmpty, cached.count == ids.count {
                if let summary = GmailMessageBuilder.threadSummary(thread, cached: Array(cached.values)) { summaries.append(summary) }
            } else if let answer = try? await transport.thread(thread, format: .metadata(headers: ["From"]), work: work),
                      let summary = GmailMessageBuilder.threadSummary(answer) {
                summaries.append(summary)
            }
        }
        if !summaries.isEmpty { try? await store.saveThreadSummaries(summaries) }
        guard !evicted.isEmpty else { return }
        var emptied: [GmailThreadID] = []
        let evictedThreads = Set(evicted.compactMap { id in members.first { $0.value.contains(id) }.map { GmailThreadID(raw: $0.key) } })
        for thread in evictedThreads {
            let still = await store.cachedMessages(members[thread.raw] ?? [])
            if still.isEmpty { emptied.append(thread) }
        }
        if !emptied.isEmpty { try? await store.removeThreadSummaries(emptied) }
    }

    // MARK: - Another app importing (§4.3 step 5)

    func floodBegan(at date: Date, count: Int) async {
        await transport.setFloodMode(true)
        state.floodBegan = date
        saveState(force: true)
        cacheTask?.cancel()
        Log.warning("gmail", "\(account.email): another app is importing (\(count) messages placed deep in one check); FalconMail uses less of Gmail's budget until it stops",
                    account: account, code: "floodMode")
    }

    /// Every half hour of a flood, and once when it ends: All Mail again, which orders and settles
    /// every imported message in one pass, and only the labels whose count changed.
    func floodRelist(final: Bool) async {
        do {
            let before = labelCounts
            let comparable = labelChains().compactMap { chain -> GmailLabelID? in
                if case .label(let label) = chain { return label }
                return nil
            }
            let counts = await askCounts(comparable, work: .background(.index))
            let changed = comparable.filter { counts[$0]?.messagesTotal != before[$0]?.messagesTotal }.map { GmailListingChain.label($0) }
            let result = try await relist(labels: changed, allMail: true, replaceBits: false, confirmRemovals: false, work: .background(.index))
            if !result.changes.isEmpty { try await store.commit(GmailJournalBatch(changes: result.changes, cursor: cursor)) }
            publishIndexChange(ids: [], everything: true)
            if final {
                await settleLeftovers()
                await transport.setFloodMode(false)
                state.floodBegan = nil
                saveState(force: true)
                Log.info("gmail", "\(account.email): the other app's import has ended")
                startCacheFill()
            }
        } catch {
            Log.warning("gmail", "\(account.email): listing during another app's import stopped", error: error, account: account,
                        code: (error as? GoogleAPIError)?.kind.rawValue)
            if final { pendingFloodEnd = true }
        }
    }

    /// Imported messages the last listing did not reach are confirmed one by one: placed where
    /// they belong, or dropped when Gmail no longer has them.
    private func settleLeftovers() async {
        let left = provisional.sorted().map(GmailMessageID.init(raw:))
        guard !left.isEmpty else { return }
        do {
            try await placeListedOnly(left, work: .background(.index))
            provisional.removeAll()
        } catch {
            Log.warning("gmail", "\(account.email): imported messages could not be settled yet", error: error, account: account)
        }
    }

    // MARK: - Maintenance, between checks

    /// Work the loop looks at every minute: a flood's relistings and end, labels made elsewhere, a
    /// listing to resume, the daily look, and the date anchors after midnight.
    func maintenance(at current: Date) async {
        if let step = flood.tick(at: current) {
            startFloodRelist(final: step == .ended)
        } else if pendingFloodEnd, relistTask == nil {
            pendingFloodEnd = false
            startFloodRelist(final: true)
        }
        if labelsListWanted, relistTask == nil, state.backfill?.phase == .complete {
            labelsListWanted = false
            relistTask = Task {
                await self.refreshLabelList()
                self.relistEnded()
            }
        }
        if running, backfillTask == nil, state.backfill?.phase != .complete, cursor != nil || state.backfill == nil,
           current >= (backfillRetryAt ?? .distantPast) {
            backfillTask = Task { await self.runBackfill() }
        }
        if state.backfill?.phase == .complete, relistTask == nil, dailyDue(at: current) {
            state.lastDailyCheck = current
            saveState(force: true)
            relistTask = Task {
                await self.daily()
                self.relistEnded()
            }
        }
        if state.dateGroupsWanted == true, state.backfill?.phase == .complete,
           state.anchorsDay.map({ $0 < Calendar.current.startOfDay(for: current) }) ?? true {
            state.anchorsDay = Calendar.current.startOfDay(for: current)
            Task { try? await self.refreshDateAnchors(only: GmailDateGroups.recent(now: current)) }
        }
    }

    func nextMaintenance(after current: Date) -> Date { current.addingTimeInterval(60) }

    private func startFloodRelist(final: Bool) {
        guard relistTask == nil else {
            if final { pendingFloodEnd = true }
            return
        }
        relistTask = Task {
            await self.floodRelist(final: final)
            self.relistEnded()
        }
    }

    /// Once a day, when the Mac is idle, or twelve hours later whatever the owner is doing.
    private func dailyDue(at current: Date) -> Bool {
        guard let last = state.lastDailyCheck else {
            state.lastDailyCheck = current
            return false
        }
        let elapsed = current.timeIntervalSince(last)
        guard elapsed >= settings.dailyEvery else { return false }
        if case .idle = schedule.activity { return true }
        return elapsed >= settings.dailyEvery + 12 * 3600
    }

    /// The send-as addresses (1 unit), the labels (1 unit) and every count (§2.5).
    func daily() async {
        if let addresses = try? await transport.sendAs(work: .background(.index)) {
            state.sendAs = addresses.map { $0.sendAsEmail.lowercased() }
            state.sendAsAt = now()
            sendAsAddresses = Set(state.sendAs ?? [])
            saveState(force: true)
        }
        await refreshLabelList()
        do { try await checkCounts(work: .background(.index)) } catch {
            Log.warning("gmail", "\(account.email): the daily count check stopped", error: error, account: account,
                        code: (error as? GoogleAPIError)?.kind.rawValue)
        }
    }

    /// Reads the labels again: a label renamed keeps its folder, one deleted leaves every message,
    /// and a new one that is shown is listed.
    func refreshLabelList() async {
        do {
            let labels = try await transport.labels(work: .background(.index))
            let previous = labelEntries
            let entries = GmailLabelMapping.entries(from: labels, previous: previous, hints: folderHints, accountID: accountID,
                                                    showsAll: settings.showsAllLabels)
            guard entries != previous else { return }
            labelEntries = try await store.saveLabelTable(entries)
            let before = Set(previous.map(\.id))
            let added = labelEntries.filter { $0.kind == .user && $0.isShown && !before.contains($0.id) }.map { GmailListingChain.label($0.id) }
            if !added.isEmpty {
                let result = try await relist(labels: added, allMail: false, replaceBits: false, confirmRemovals: false,
                                              work: .background(.index))
                if !result.changes.isEmpty { try await store.commit(GmailJournalBatch(changes: result.changes, cursor: cursor)) }
                await markListedLabelsComplete()
            }
            publishIndexChange(ids: [], everything: true)
        } catch {
            Log.warning("gmail", "\(account.email): the labels could not be read again", error: error, account: account,
                        code: (error as? GoogleAPIError)?.kind.rawValue)
            labelsListWanted = true
        }
    }
}
