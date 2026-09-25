import Foundation

// The list's view of the index: which messages a view shows, in which order, grouped how. It is
// built off the main thread from an immutable copy of the index, so the table only ever reads a
// finished snapshot. No view needs a message's date or text to exist: a folder is one pass over
// the account's order with one AND per record, and conversations are one hash pass over that.

// MARK: - What the list is built from

/// One Google account as the list sees it: an immutable copy of its index, its labels and what
/// is known about the listings still running.
public struct ListIndexAccount: Sendable {
    public var accountID: UUID
    public var email: String
    public var index: GmailIndexSnapshot
    public var labels: [GmailLabelEntry]
    /// The sidebar's Archive, which is Gmail's All Mail and has no label of its own.
    public var archiveFolderID: UUID?
    /// All Mail has been listed in full, so every message has its place in the order.
    public var allMailComplete: Bool
    /// Gmail's own count of the mailbox, which Archive's Items shows until the listing is done.
    public var allMailTotal: Int?
    public var anchors: [GmailDateAnchor]
    /// `has:attachment` has been listed, so a message without the bit has no attachment.
    public var attachmentsKnown: Bool
    /// The `larger:` listings have run, so every message's size band is known.
    public var sizesKnown: Bool

    public init(accountID: UUID, email: String, index: GmailIndexSnapshot, labels: [GmailLabelEntry] = [],
                archiveFolderID: UUID? = nil, allMailComplete: Bool = true, allMailTotal: Int? = nil,
                anchors: [GmailDateAnchor] = [], attachmentsKnown: Bool = false, sizesKnown: Bool = false) {
        self.accountID = accountID
        self.email = email
        self.index = index
        self.labels = labels
        self.archiveFolderID = archiveFolderID
        self.allMailComplete = allMailComplete
        self.allMailTotal = allMailTotal
        self.anchors = anchors
        self.attachmentsKnown = attachmentsKnown
        self.sizesKnown = sizesKnown
    }

    /// The label a sidebar folder shows, or nil for Archive; `.none` when the folder is not this
    /// account's.
    func target(of folderID: UUID) -> ListFolderTarget? {
        if folderID == archiveFolderID { return .archive }
        return labels.first { $0.folderID == folderID }.map { .label($0.id) }
    }
}

enum ListFolderTarget: Hashable {
    case label(GmailLabelID)
    case archive
}

/// What is known of a message's text: enough to sort by sender, recipient or subject, to place
/// it by date among other accounts' mail, and to show it offline. Only messages whose text the
/// Mac holds have facts: the newest 1,000 and the rows fetched this session.
public struct ListRowFacts: Hashable, Sendable {
    public var date: Date
    public var from: String
    public var to: String
    public var subject: String
    /// The owner is named in the message with an @, for the Mentions filter.
    public var mentionsOwner: Bool

    public init(date: Date, from: String, to: String, subject: String, mentionsOwner: Bool = false) {
        self.date = date
        self.from = from
        self.to = to
        self.subject = subject
        self.mentionsOwner = mentionsOwner
    }

    public init(_ content: MessageRowContent, ownAddresses: Set<String> = []) {
        self.init(date: content.date, from: ListRowFacts.name(content.from),
                  to: content.to.first.map(ListRowFacts.name) ?? "", subject: content.subject,
                  mentionsOwner: ListRowFacts.mentions(content.subject + " " + content.preview, ownAddresses))
    }

    static func name(_ address: EmailAddress) -> String { address.name.isEmpty ? address.address : address.name }

    static func mentions(_ text: String, _ own: Set<String>) -> Bool {
        guard text.contains("@") else { return false }
        let lower = text.lowercased()
        return own.contains { address in
            let local = address.split(separator: "@").first.map(String.init) ?? address
            return lower.contains("@" + address) || (!local.isEmpty && lower.contains("@" + local))
        }
    }
}

/// A row of an account that is not Google, for All Inboxes: its stored row, already grouped
/// into its conversation and dated exactly.
public struct ListStoredRow: Hashable, Sendable {
    public var key: String
    public var accountID: UUID
    public var date: Date
    public var bits: DisplayBits
    public var members: UInt16
    public var unread: UInt16
    public var kind: DisplayKind
    public var facts: ListRowFacts?
    /// The conversation's messages, newest first, shown when it is opened out.
    public var children: [ListStoredChild]

    public init(key: String, accountID: UUID, date: Date, bits: DisplayBits = [], members: UInt16 = 1, unread: UInt16 = 0,
                kind: DisplayKind = .message, facts: ListRowFacts? = nil, children: [ListStoredChild] = []) {
        self.key = key
        self.accountID = accountID
        self.date = date
        self.bits = bits
        self.members = members
        self.unread = unread
        self.kind = kind
        self.facts = facts
        self.children = children
    }
}

public struct ListStoredChild: Hashable, Sendable {
    public var key: String
    public var bits: DisplayBits

    public init(key: String, bits: DisplayBits) {
        self.key = key
        self.bits = bits
    }
}

/// Something a view asked for that the index does not know yet. The account's engine lists it in
/// the background, and the view is built again when it arrives.
public enum ListNeed: Hashable, Sendable {
    /// The `has:attachment` listing, for the Has attachments filter or the Attachments sort.
    case attachments(UUID)
    /// The `larger:` listings, for the Size sort.
    case sizes(UUID)
    /// Date anchors, for date groups and for placing rows among other accounts' by date.
    case anchors(UUID)
}

/// A view as built: its snapshot, and what else building it found out.
public struct ListBuild: Sendable {
    public var snapshot: ListSnapshot
    public var needs: Set<ListNeed>
    /// Rows whose text a sort by sender, recipient or subject would use, newest first: fetched in
    /// the background, at most 200 a sort.
    public var textWanted: [RowKey]
    /// Messages left out because their text is not on this Mac while it is offline.
    public var hiddenMessages: Int
    /// The newest date among rows listed by date after a text sort's groups, for its footer.
    public var listedByDateBefore: Date?
}

// MARK: - Date groups

/// Outlook's "Show in groups" for dates: Today, Yesterday, Earlier this week, Earlier this month,
/// then one group a month. Boundaries fall at local midnights, so they move only once a day and
/// the anchors that place them are asked again only then.
public struct ListDateGroups: Sendable {
    public let now: Date
    public let calendar: Calendar
    private let today: Date
    private let yesterday: Date
    private let week: Date
    private let month: Date

    public init(now: Date, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        week = calendar.date(byAdding: .day, value: -6, to: today) ?? today.addingTimeInterval(-6 * 86_400)
        month = calendar.date(byAdding: .month, value: -1, to: today) ?? today.addingTimeInterval(-30 * 86_400)
    }

    /// The group boundaries from newest to oldest: the four recent ones, then the first of each
    /// month back to `oldest`. With `daily`, every midnight of the last month as well, so rows
    /// of several accounts can be placed among each other to the day.
    public func boundaries(oldest: Date?, daily: Bool = false) -> [Date] {
        var out = [today, yesterday, week, month]
        if daily {
            var day = yesterday
            while let next = calendar.date(byAdding: .day, value: -1, to: day), next > month {
                day = next
                if day != week { out.append(day) }
            }
        }
        var start = calendar.dateInterval(of: .month, for: month.addingTimeInterval(-1))?.start
        let floor = oldest ?? now
        while let boundary = start, boundary < month {
            out.append(boundary)
            guard boundary > floor else { break }
            start = calendar.date(byAdding: .month, value: -1, to: boundary)
        }
        return Array(Set(out)).sorted(by: >)
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    /// The group a date falls in, as the list's own `dayKey` names them.
    public func title(for date: Date) -> String {
        if date >= today { return "Today" }
        if date >= yesterday { return "Yesterday" }
        if date >= week { return "Earlier this week" }
        if date >= month { return "Earlier this month" }
        let formatter = ListDateGroups.monthFormatter
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }
}

// MARK: - The index

/// Builds every view of every Google account, and All Inboxes with the stored Inboxes of other
/// accounts, off the main thread.
public actor ListIndex {
    public struct Settings: Hashable, Sendable {
        /// Moves Gmail's Updates from Focused to Other, for someone who prefers Gmail's own tabs.
        public var updatesAreOther: Bool

        public init(updatesAreOther: Bool = false) {
            self.updatesAreOther = updatesAreOther
        }
    }

    private var accounts: [UUID: ListIndexAccount] = [:]
    /// The accounts in the sidebar's order, which All Inboxes and the Account sort follow.
    private var accountOrder: [UUID] = []
    private var facts: [UUID: [UInt64: ListRowFacts]] = [:]
    private var storedInboxRows: [ListStoredRow] = []
    private var accountNames: [UUID: String] = [:]
    private var searches: [UUID: [UUID: ContiguousArray<UInt64>]] = [:]
    private var expanded: [ListView.Scope: Set<ListThreadRef>] = [:]
    private var frozen: [RowKey: Date] = [:]
    private var offline: Set<UUID> = []
    private var settings: Settings
    private let calendar: Calendar
    private let clock: @Sendable () -> Date
    private nonisolated let changed = RowBroadcast<Void>()

    public init(settings: Settings = Settings(), calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.calendar = calendar
        self.clock = clock
    }

    /// A signal each time anything a view is built from changes, for views that merge accounts
    /// and are built by no one account's source.
    public nonisolated func observe() -> AsyncStream<Void> { changed.subscribe() }

    // MARK: Keeping it current

    public func setAccount(_ account: ListIndexAccount) {
        defer { changed.send(()) }
        if accounts[account.accountID] == nil, !accountOrder.contains(account.accountID) { accountOrder.append(account.accountID) }
        accounts[account.accountID] = account
        accountNames[account.accountID] = accountNames[account.accountID] ?? account.email
    }

    public func removeAccount(_ id: UUID) {
        defer { changed.send(()) }
        accounts[id] = nil
        facts[id] = nil
        accountOrder.removeAll { $0 == id }
    }

    public func account(_ id: UUID) -> ListIndexAccount? { accounts[id] }

    /// The accounts in sidebar order, with the names the Account sort shows, for Google and
    /// stored accounts alike.
    public func setAccountOrder(_ ids: [UUID], names: [UUID: String] = [:]) {
        defer { changed.send(()) }
        accountOrder = ids + accountOrder.filter { !ids.contains($0) }
        accountNames.merge(names) { _, new in new }
    }

    public func setSettings(_ settings: Settings) {
        defer { changed.send(()) }
        self.settings = settings
    }

    public func addFacts(_ new: [UInt64: ListRowFacts], account: UUID) {
        defer { changed.send(()) }
        facts[account, default: [:]].merge(new) { _, fresh in fresh }
    }

    public func forgetFacts(_ ids: [UInt64], account: UUID) {
        defer { changed.send(()) }
        for id in ids { facts[account]?[id] = nil }
    }

    public func hasFacts(_ id: UInt64, account: UUID) -> Bool { facts[account]?[id] != nil }

    public func setStoredInboxRows(_ rows: [ListStoredRow]) {
        defer { changed.send(()) }
        storedInboxRows = rows
    }

    /// A search's hits in one account, newest first. The search's rows are these, with their
    /// flags and folders from the index, so every action works on them.
    public func setSearchHits(_ ids: [GmailMessageID], search: UUID, account: UUID) {
        defer { changed.send(()) }
        searches[search, default: [:]][account] = ContiguousArray(ids.map(\.raw))
    }

    public func searchHits(_ search: UUID, account: UUID) -> [GmailMessageID] {
        (searches[search]?[account] ?? []).map(GmailMessageID.init(raw:))
    }

    public func endSearch(_ id: UUID) {
        defer { changed.send(()) }
        searches[id] = nil
        expanded[.search(id)] = nil
    }

    /// Conversations opened out in a view, named by any key of theirs; they stay open as new
    /// messages arrive in them.
    public func setExpanded(_ keys: Set<RowKey>, in scope: ListView.Scope) {
        defer { changed.send(()) }
        var refs = Set<ListThreadRef>()
        for key in keys {
            switch key {
            case .gmail(let account, let id):
                if let record = accounts[account]?.index.record(for: id) {
                    refs.insert(.gmail(account: account, thread: record.threadID))
                }
            case .stored(let id):
                refs.insert(.stored(id))
            }
        }
        expanded[scope] = refs
    }

    public func expandedThreads(in scope: ListView.Scope) -> Set<ListThreadRef> { expanded[scope] ?? [] }

    /// While an account is offline, or Gmail has paused FalconMail for more than a minute, its
    /// rows are shown only where their text is on this Mac: a grey row could not fill.
    public func setOffline(_ isOffline: Bool, account: UUID) {
        defer { changed.send(()) }
        if isOffline { offline.insert(account) } else { offline.remove(account) }
    }

    /// Rows on screen keep the place their estimated date gave them among other accounts' rows
    /// until they leave the screen: a row never moves while the owner is looking at it.
    public func freeze(_ keys: [RowKey], dates: [RowKey: Date]) {
        frozen = [:]
        for key in keys { if let date = dates[key] { frozen[key] = date } }
    }

    // MARK: Building

    public func snapshot(of view: ListView) -> ListSnapshot { build(view).snapshot }

    public func build(_ view: ListView) -> ListBuild {
        let now = clock()
        var builder = ListBuilder(view: view, settings: settings, groups: ListDateGroups(now: now, calendar: calendar))
        switch view.scope {
        case .folder(let folderID):
            guard let account = accountOrder.lazy.compactMap({ self.accounts[$0] }).first(where: { $0.target(of: folderID) != nil }),
                  let target = account.target(of: folderID) else {
                return ListBuild(snapshot: .empty(view), needs: [], textWanted: [], hiddenMessages: 0)
            }
            builder.add(account, target: .folder(target), facts: facts[account.accountID] ?? [:],
                        offline: offline.contains(account.accountID), expanded: expanded[view.scope] ?? [])
        case .allInboxes:
            for id in accountOrder {
                guard let account = accounts[id] else { continue }
                builder.add(account, target: .folder(.label(.inbox)), facts: facts[id] ?? [:], offline: offline.contains(id),
                            expanded: expanded[view.scope] ?? [])
            }
            builder.addStored(storedInboxRows, expanded: expanded[view.scope] ?? [])
        case .search(let searchID):
            for id in accountOrder {
                guard let account = accounts[id], let hits = searches[searchID]?[id] else { continue }
                builder.add(account, target: .search(hits), facts: facts[id] ?? [:], offline: offline.contains(id),
                            expanded: expanded[view.scope] ?? [])
            }
        }
        return builder.finish(order: accountOrder, names: accountNames, frozen: frozen)
    }
}

/// A conversation opened out, as the index knows it: by thread, so it stays open when a new
/// message becomes its newest.
public enum ListThreadRef: Hashable, Sendable {
    case gmail(account: UUID, thread: UInt64)
    case stored(String)
}

// MARK: - Building one view

/// One view being built. Each account adds its rows, newest first; `finish` merges them, sorts,
/// opens out conversations and places the group headers. The common case, one folder by date,
/// never makes more than the records themselves: dates, facts and folders are gathered only for
/// the sorts and groups that use them.
struct ListBuilder {
    enum Target {
        case folder(ListFolderTarget)
        case search(ContiguousArray<UInt64>)
    }

    /// Rows before sorting, with whatever the sort needs beside each; the side arrays are empty
    /// when it needs nothing.
    struct Rows {
        var records = ContiguousArray<DisplayRecord>()
        var facts: [ListRowFacts?] = []
        var dates: [Date?] = []
        /// How many of its account's anchors each row is older than; -1 when not known.
        var dateGroups: [Int32] = []
        /// The folder each row is filed under for the Folder sort, as a place in `folderNames`.
        var folders: [Int32] = []

        mutating func take(_ other: Rows, at i: Int) {
            records.append(other.records[i])
            if !other.facts.isEmpty { facts.append(other.facts[i]) }
            if !other.dates.isEmpty { dates.append(other.dates[i]) }
            if !other.dateGroups.isEmpty { dateGroups.append(other.dateGroups[i]) }
            if !other.folders.isEmpty { folders.append(other.folders[i]) }
        }

        func permuted(_ order: [Int]) -> Rows {
            var out = Rows()
            out.records.reserveCapacity(order.count)
            for i in order { out.take(self, at: i) }
            return out
        }

        func reversed() -> Rows { permuted(Array(records.indices.reversed())) }

        func fact(_ i: Int) -> ListRowFacts? { facts.isEmpty ? nil : facts[i] }
        func date(_ i: Int) -> Date? { dates.isEmpty ? nil : dates[i] }
    }

    let view: ListView
    let settings: ListIndex.Settings
    let groups: ListDateGroups
    private var sequences: [Rows] = []
    private var sources: [UUID] = []
    /// Each Google source's index, to find a conversation row's thread.
    private var indexes: [UInt8: GmailIndexSnapshot] = [:]
    private var anchorDating: [UInt8: AnchorDating] = [:]
    private var storedKeys: [String] = []
    private var itemCount = 0
    private var complete = true
    private var needs = Set<ListNeed>()
    private var hidden = 0
    /// Children to place under each opened conversation, by its thread.
    private var children: [ListThreadRef: [DisplayRecord]] = [:]
    /// Folder titles for the Folder sort, each with its place in the sidebar.
    private var folderNames: [(place: Int, name: String)] = [(0, "Deleted Items"), (1, "Junk Email")]
    private var folderIndex: [String: Int32] = ["Deleted Items": 0, "Junk Email": 1]

    private let wantsFacts: Bool
    private let wantsDateGroups: Bool

    init(view: ListView, settings: ListIndex.Settings, groups: ListDateGroups) {
        self.view = view
        self.settings = settings
        self.groups = groups
        wantsFacts = view.sort.key.isTextual || view.filters.contains(.mentionsMe) || view.scope.mergesAccounts
            || view.dateGroups && view.sort.key == .date
        wantsDateGroups = view.scope.mergesAccounts || view.dateGroups && view.sort.key == .date
    }

    // MARK: Adding an account

    mutating func add(_ account: ListIndexAccount, target: Target, facts: [UInt64: ListRowFacts], offline: Bool,
                      expanded: Set<ListThreadRef>) {
        let source = UInt8(truncatingIfNeeded: sources.count)
        sources.append(account.accountID)
        let index = account.index
        indexes[source] = index
        let masks = ListMasks(index: index, settings: settings)
        var query = masks.query(for: target, filters: view.filters)
        defer { query.release() }

        if view.filters.contains(.attachments) || view.sort.key == .attachments, !account.attachmentsKnown {
            needs.insert(.attachments(account.accountID))
            complete = false
        }
        if view.sort.key == .size, !account.sizesKnown {
            needs.insert(.sizes(account.accountID))
            complete = false
        }
        if view.filters.contains(.mentionsMe) { complete = false }
        if wantsDateGroups, account.anchors.isEmpty, !index.byOrder.isEmpty { needs.insert(.anchors(account.accountID)) }
        let dating = AnchorDating(anchors: account.anchors)
        anchorDating[source] = dating

        var records: ContiguousArray<DisplayRecord>
        if view.conversations {
            let members = ListScan.members(index, query: query, target: target)
            itemCount += count(of: account, target: target, members: members.count)
            records = ListScan.conversations(index, members: members, masks: masks, target: target, source: source)
        } else if case .folder = target {
            records = ListScan.flat(index, query: query, masks: masks, source: source)
            itemCount += count(of: account, target: target, members: records.count)
        } else {
            let members = ListScan.members(index, query: query, target: target)
            itemCount += count(of: account, target: target, members: members.count)
            records = ListScan.messages(index, members: members, masks: masks, source: source)
        }
        if !isComplete(account, target: target) { complete = false }

        if offline || view.filters.contains(.mentionsMe) {
            var shown = ContiguousArray<DisplayRecord>()
            shown.reserveCapacity(min(records.count, facts.count))
            for record in records {
                guard let known = facts[record.key] else {
                    if offline { hidden += Int(record.members) }
                    continue
                }
                if view.filters.contains(.mentionsMe), !known.mentionsOwner { continue }
                shown.append(record)
            }
            records = shown
        }

        var rows = Rows()
        if wantsFacts {
            rows.facts = records.map { facts[$0.key] }
            rows.dates = rows.facts.map { $0?.date }
        }
        if wantsDateGroups, !dating.isEmpty {
            rows.dateGroups = records.map { Int32(dating.group(of: index.records[Int($0.slot)].order)) }
        }
        if view.sort.key == .folder {
            let namer = FolderNamer(account: account, masks: masks)
            rows.folders = records.map { record in
                let bits = record.displayBits
                if bits.contains(.inDeletedItems) { return 0 }
                if bits.contains(.inJunkEmail) { return 1 }
                let (place, name) = namer.folder(ofSlot: record.slot)
                return folderNumber(name, place: place)
            }
        }
        rows.records = records
        sequences.append(rows)

        let opened = expanded.filter { if case .gmail(let a, _) = $0 { return a == account.accountID } else { return false } }
        if !opened.isEmpty {
            for (thread, list) in ListScan.children(index, threads: opened, masks: masks, target: target, source: source) {
                children[thread] = list
            }
        }
    }

    private mutating func folderNumber(_ name: String, place: Int) -> Int32 {
        if let known = folderIndex[name] { return known }
        folderNames.append((place, name))
        let number = Int32(folderNames.count - 1)
        folderIndex[name] = number
        return number
    }

    mutating func addStored(_ stored: [ListStoredRow], expanded: Set<ListThreadRef>) {
        guard !stored.isEmpty else { return }
        var rows = Rows()
        var sourceOf: [UUID: UInt8] = [:]
        for row in stored {
            if view.filters.contains(.unread), !row.bits.contains(.unread) && row.unread == 0 { continue }
            if view.filters.contains(.flagged), !row.bits.contains(.flagged) { continue }
            if view.filters.contains(.attachments), !row.bits.contains(.hasAttachment) { continue }
            if view.filters.contains(.mentionsMe), row.facts?.mentionsOwner != true { continue }
            let source: UInt8
            if let known = sourceOf[row.accountID] {
                source = known
            } else {
                source = UInt8(truncatingIfNeeded: sources.count)
                sources.append(row.accountID)
                sourceOf[row.accountID] = source
            }
            let slot = Int32(storedKeys.count)
            storedKeys.append(row.key)
            var bits = row.bits
            bits.insert(.storedRow)
            let kind: DisplayKind = view.conversations ? row.kind : .message
            let members = view.conversations ? row.members : 1
            rows.records.append(DisplayRecord(key: UInt64(slot), slot: slot, bits: bits, members: members,
                                              unread: row.unread, kind: kind, source: source))
            rows.facts.append(row.facts)
            rows.dates.append(row.date)
            if wantsDateGroups { rows.dateGroups.append(-1) }
            if view.sort.key == .folder { rows.folders.append(folderNumber("Inbox", place: 2)) }
            itemCount += Int(members)
            let ref = ListThreadRef.stored(row.key)
            if kind == .conversation, expanded.contains(ref) {
                children[ref] = row.children.map { child in
                    let childSlot = Int32(storedKeys.count)
                    storedKeys.append(child.key)
                    var childBits = child.bits
                    childBits.insert(.storedRow)
                    return DisplayRecord(key: UInt64(childSlot), slot: childSlot, bits: childBits,
                                         unread: childBits.contains(.unread) ? 1 : 0, kind: .child, source: source)
                }
            }
        }
        sequences.append(rows)
    }

    private func count(of account: ListIndexAccount, target: Target, members: Int) -> Int {
        guard case .folder(let folder) = target, view.filters.isEmpty, !isComplete(account, target: target) else { return members }
        switch folder {
        case .archive:
            return max(members, account.allMailTotal ?? members)
        case .label(let label):
            let counts = account.labels.first { $0.id == label }?.counts
            return max(members, counts?.messagesTotal ?? members)
        }
    }

    private func isComplete(_ account: ListIndexAccount, target: Target) -> Bool {
        guard case .folder(let folder) = target else { return account.allMailComplete }
        switch folder {
        case .archive: return account.allMailComplete
        case .label(let label):
            guard account.allMailComplete else { return false }
            // A label never listed on its own is complete once All Mail is, if it has a fixed bit:
            // the first listing gives every message its system labels.
            return account.labels.first { $0.id == label }?.isComplete ?? (label.fixedSlot != nil)
        }
    }

    // MARK: Finishing

    func finish(order: [UUID], names: [UUID: String], frozen: [RowKey: Date]) -> ListBuild {
        var rows = merged(frozen: frozen)
        var titles: [String] = []
        var textWanted: [RowKey] = []
        var listedByDateBefore: Date?
        let ascending = view.sort.ascending

        switch view.sort.key {
        case .date:
            if view.dateGroups { titles = dateTitles(&rows) }
            if ascending { rows = rows.reversed() }
        case .from, .to, .subject:
            var known: [Int] = []
            var unknown: [Int] = []
            var keys: [String] = []
            keys.reserveCapacity(rows.records.count)
            for i in rows.records.indices {
                if let facts = rows.fact(i) {
                    known.append(i)
                    keys.append(textKey(facts))
                } else {
                    unknown.append(i)
                    keys.append("")
                }
            }
            known.sort { a, b in
                let order = keys[a].localizedCaseInsensitiveCompare(keys[b])
                if order != .orderedSame { return order == .orderedAscending }
                return (rows.date(a) ?? .distantPast) > (rows.date(b) ?? .distantPast)
            }
            if ascending { known.reverse() }
            if !unknown.isEmpty { listedByDateBefore = known.compactMap { rows.date($0) }.min() }
            var index: [String: Int] = [:]
            var numbered: [Int: UInt16] = [:]
            func number(_ title: String) -> UInt16 {
                if let known = index[title] { return UInt16(truncatingIfNeeded: known) }
                titles.append(title)
                index[title] = titles.count - 1
                return UInt16(truncatingIfNeeded: titles.count - 1)
            }
            for i in known { numbered[i] = number(view.dateGroups ? groupTitle(keys[i]) : "") }
            for i in unknown { numbered[i] = number(ListStatusText.olderByDate) }
            textWanted = unknown.prefix(200).compactMap { key(of: rows.records[$0]) }
            rows = rows.permuted(known + unknown)
            for i in rows.records.indices {
                rows.records[i].group = numbered[(known + unknown)[i]] ?? 0
            }
        default:
            let ranking = ranks(rows, order: order, names: names)
            titles = ranking.titles
            for i in rows.records.indices { rows.records[i].group = ranking.ranks[i] }
            rows = rows.permuted(ListBuilder.stableOrder(ranking.ranks, count: titles.count))
            if ascending { rows = rows.reversed() }
        }

        // Headers go where the group changes. A text sort's dated tail always has its own, so it
        // is plain why those rows stand in date order.
        let showHeaders = view.dateGroups || view.sort.key.isTextual
        let records = rows.records
        var out: ContiguousArray<DisplayRecord>
        var headers: [Int: String] = [:]
        if !showHeaders, children.isEmpty {
            out = records
        } else {
            out = ContiguousArray()
            out.reserveCapacity(records.count + 64 + (showHeaders ? titles.count : 0))
            var lastGroup: Int?
            for var record in records {
                let group = Int(record.group)
                if showHeaders, group != lastGroup, titles.indices.contains(group), !titles[group].isEmpty {
                    out.append(.header(group: record.group))
                    headers[group] = titles[group]
                }
                lastGroup = group
                if record.displayKind == .conversation, let thread = thread(of: record), let list = children[thread] {
                    record.displayBits.insert(.expanded)
                    out.append(record)
                    for var child in list {
                        child.group = record.group
                        out.append(child)
                    }
                } else {
                    out.append(record)
                }
            }
        }

        let snapshot = ListSnapshot(view: view, rows: out, headers: headers, complete: complete, itemCount: itemCount,
                                    sources: sources, storedKeys: storedKeys)
        return ListBuild(snapshot: snapshot, needs: needs, textWanted: textWanted, hiddenMessages: hidden,
                         listedByDateBefore: listedByDateBefore)
    }

    private func thread(of record: DisplayRecord) -> ListThreadRef? {
        if record.displayBits.contains(.storedRow) {
            let slot = Int(record.slot)
            return storedKeys.indices.contains(slot) ? .stored(storedKeys[slot]) : nil
        }
        guard let index = indexes[record.source], index.records.indices.contains(Int(record.slot)),
              sources.indices.contains(Int(record.source)) else { return nil }
        return .gmail(account: sources[Int(record.source)], thread: index.records[Int(record.slot)].threadID)
    }

    private func key(of record: DisplayRecord) -> RowKey? {
        if record.displayBits.contains(.storedRow) {
            let slot = Int(record.slot)
            return storedKeys.indices.contains(slot) ? .stored(storedKeys[slot]) : nil
        }
        let source = Int(record.source)
        return sources.indices.contains(source) ? .gmail(account: sources[source], id: GmailMessageID(raw: record.key)) : nil
    }

    /// Every account's rows in one sequence. One account's rows are already in order; several are
    /// merged by date, each account's own order kept, since it is exact within the account.
    private func merged(frozen: [RowKey: Date]) -> Rows {
        guard sequences.count > 1 else { return sequences.first ?? Rows() }
        var dated = sequences
        for s in dated.indices {
            if dated[s].dates.isEmpty { dated[s].dates = [Date?](repeating: nil, count: dated[s].records.count) }
            if dated[s].facts.isEmpty { dated[s].facts = [ListRowFacts?](repeating: nil, count: dated[s].records.count) }
            let dating = anchorDating[UInt8(truncatingIfNeeded: s)]
            for i in dated[s].records.indices {
                let record = dated[s].records[i]
                if let key = key(of: record), let pinned = frozen[key] {
                    dated[s].dates[i] = pinned
                } else if dated[s].dates[i] == nil, let dating, !dated[s].dateGroups.isEmpty, dated[s].dateGroups[i] >= 0 {
                    dated[s].dates[i] = dating.estimate(group: Int(dated[s].dateGroups[i]), now: groups.now)
                }
            }
        }
        var heads = [Int](repeating: 0, count: dated.count)
        var out = Rows()
        out.records.reserveCapacity(dated.reduce(0) { $0 + $1.records.count })
        while true {
            var best = -1
            var bestDate = Date.distantPast
            for s in dated.indices where heads[s] < dated[s].records.count {
                let date = dated[s].dates[heads[s]] ?? .distantPast
                if best < 0 || date > bestDate {
                    best = s
                    bestDate = date
                }
            }
            guard best >= 0 else { break }
            out.take(dated[best], at: heads[best])
            // A merged row's group number is by dates from here on, not its account's anchors.
            if !out.dateGroups.isEmpty { out.dateGroups[out.dateGroups.count - 1] = -1 }
            heads[best] += 1
        }
        if out.dateGroups.count != out.records.count { out.dateGroups = [] }
        return out
    }

    /// Titles of the date groups, with each row's group set, for a date sort shown in groups: by
    /// its anchors where the account has them, which is exact, and otherwise by its date.
    private func dateTitles(_ rows: inout Rows) -> [String] {
        var titles: [String] = []
        var index: [String: Int] = [:]
        let single = sequences.count == 1
        let dating = anchorDating[0]
        for i in rows.records.indices {
            let title: String
            if single, let dating, !dating.isEmpty, !rows.dateGroups.isEmpty, rows.dateGroups[i] >= 0 {
                title = dating.title(group: Int(rows.dateGroups[i]), groups: groups)
            } else if let date = rows.date(i) {
                title = groups.title(for: date)
            } else {
                title = titles.last ?? groups.title(for: groups.now)
            }
            let group: Int
            if let known = index[title] {
                group = known
            } else {
                titles.append(title)
                group = titles.count - 1
                index[title] = group
            }
            rows.records[i].group = UInt16(truncatingIfNeeded: group)
        }
        return titles
    }

    private func textKey(_ facts: ListRowFacts) -> String {
        switch view.sort.key {
        case .from: return facts.from
        case .to: return facts.to.isEmpty ? "No recipient" : facts.to
        default: return facts.subject.isEmpty ? "(no subject)" : facts.subject
        }
    }

    /// Outlook's group for a sender or recipient is the name; for a subject, its first letter.
    private func groupTitle(_ key: String) -> String {
        view.sort.key == .subject ? String(key.prefix(1)).uppercased() : key
    }

    /// Each row's place among the sort's groups, and the groups' titles in order.
    private func ranks(_ rows: Rows, order: [UUID], names: [UUID: String]) -> (ranks: [UInt16], titles: [String]) {
        let records = rows.records
        var ranks = [UInt16](repeating: 0, count: records.count)
        switch view.sort.key {
        case .flag:
            for i in records.indices { ranks[i] = records[i].displayBits.contains(.flagged) ? 0 : 1 }
            return (ranks, ["Flagged", "Not flagged"])
        case .status:
            for i in records.indices { ranks[i] = records[i].unread > 0 || records[i].displayBits.contains(.unread) ? 0 : 1 }
            return (ranks, ["Unread", "Read"])
        case .attachments:
            for i in records.indices { ranks[i] = records[i].displayBits.contains(.hasAttachment) ? 0 : 1 }
            return (ranks, ["With attachments", "No attachments"])
        case .size:
            for i in records.indices {
                let bits = records[i].displayBits
                ranks[i] = bits.contains(.sizeKnown) ? UInt16(SizeBand.huge.rawValue - bits.sizeBand.rawValue) : 5
            }
            return (ranks, ["Huge (5 MB and over)", "Large (under 5 MB)", "Medium (under 1 MB)", "Small (under 100 KB)",
                            "Tiny (under 25 KB)", "Size not known yet"])
        case .account:
            let placed = order.filter { sources.contains($0) } + sources.filter { !order.contains($0) }
            var rankOf: [UUID: UInt16] = [:]
            for (i, id) in placed.enumerated() where rankOf[id] == nil { rankOf[id] = UInt16(truncatingIfNeeded: i) }
            for i in records.indices {
                let source = Int(records[i].source)
                ranks[i] = sources.indices.contains(source) ? rankOf[sources[source]] ?? 0 : 0
            }
            return (ranks, placed.map { names[$0] ?? "Account" })
        case .folder:
            // Deleted Items and Junk Email first, then folders in sidebar order.
            let placed = folderNames.indices.sorted { (folderNames[$0].place, folderNames[$0].name) < (folderNames[$1].place, folderNames[$1].name) }
            var rankOf = [UInt16](repeating: 0, count: folderNames.count)
            for (rank, number) in placed.enumerated() { rankOf[number] = UInt16(truncatingIfNeeded: rank) }
            for i in records.indices where i < rows.folders.count { ranks[i] = rankOf[Int(rows.folders[i])] }
            return (ranks, placed.map { folderNames[$0].name })
        default:
            return (ranks, [""])
        }
    }

    /// The order that puts rows by rank, keeping their order within a rank: one counting pass.
    static func stableOrder(_ ranks: [UInt16], count: Int) -> [Int] {
        guard count > 1 else { return Array(ranks.indices) }
        var starts = [Int](repeating: 0, count: count + 1)
        for rank in ranks { starts[min(Int(rank), count - 1) + 1] += 1 }
        for i in 1..<starts.count { starts[i] += starts[i - 1] }
        var out = [Int](repeating: 0, count: ranks.count)
        for (i, rank) in ranks.enumerated() {
            let r = min(Int(rank), count - 1)
            out[starts[r]] = i
            starts[r] += 1
        }
        return out
    }
}

extension ListView.Scope {
    /// Views whose rows come from several accounts, which are placed among each other by date.
    var mergesAccounts: Bool {
        switch self {
        case .allInboxes, .search: return true
        case .folder: return false
        }
    }
}

/// Which folder a message is filed under for the Folder sort: the first of its folders in sidebar
/// order, and Archive when it is in none.
struct FolderNamer {
    private let folders: [(label: GmailLabelID, name: String, place: Int)]
    private let index: GmailIndexSnapshot
    /// After Drafts, as in the sidebar.
    private static let archivePlace = 4

    init(account: ListIndexAccount, masks: ListMasks) {
        index = account.index
        var out: [(GmailLabelID, String, Int)] = [
            (.inbox, "Inbox", 2), (.draft, "Drafts", 3), (.sent, "Sent", 5)
        ]
        // Important, Starred and the other labels follow, by name, as the sidebar lists them.
        var rest: [(GmailLabelID, String)] = [(.important, "Important"), (.starred, "Starred")]
        for entry in account.labels where entry.kind == .user && entry.isShown {
            rest.append((entry.id, entry.name))
        }
        rest.sort { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        for (i, label) in rest.enumerated() { out.append((label.0, label.1, 6 + i)) }
        folders = out.map { (label: $0.0, name: $0.1, place: $0.2) }
    }

    func folder(ofSlot slot: Int32) -> (place: Int, name: String) {
        for folder in folders where index.record(atSlot: slot, has: folder.label) {
            return (folder.place, folder.name)
        }
        return (FolderNamer.archivePlace, "Archive")
    }
}

extension ListSortKey {
    /// Sorts that need a message's text, which only rows fetched or kept on the Mac have.
    public var isTextual: Bool { self == .from || self == .to || self == .subject }
}

// MARK: - Dates from anchors

/// Places an account's messages between its date anchors, by their order alone.
struct AnchorDating {
    /// Newest boundary first, with the order of the newest message older than it; -1 when none is.
    private let boundaries: [Date]
    private let orders: [Int64]

    init(anchors: [GmailDateAnchor]) {
        let sorted = anchors.sorted { $0.boundary > $1.boundary }
        var boundaries: [Date] = []
        var orders: [Int64] = []
        var floor = Int64.max
        for anchor in sorted {
            // A later placement can leave an anchor out of step; the order never rises going back.
            let order = min(floor, anchor.order.map(Int64.init) ?? -1)
            boundaries.append(anchor.boundary)
            orders.append(order)
            floor = order
        }
        self.boundaries = boundaries
        self.orders = orders
    }

    var isEmpty: Bool { boundaries.isEmpty }

    /// How many boundaries the message is older than: 0 when newer than every one.
    func group(of order: UInt32) -> Int {
        let value = Int64(order)
        var low = 0
        var high = orders.count
        while low < high {
            let mid = (low + high) / 2
            if orders[mid] >= value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The middle of the time between the boundaries on either side of the group.
    func estimate(group: Int, now: Date) -> Date? {
        guard !boundaries.isEmpty else { return nil }
        let newer = group == 0 ? now : boundaries[min(group, boundaries.count) - 1]
        let older = group < boundaries.count ? boundaries[group] : newer.addingTimeInterval(-31 * 86_400)
        return Date(timeIntervalSince1970: (newer.timeIntervalSince1970 + older.timeIntervalSince1970) / 2)
    }

    func title(group: Int, groups: ListDateGroups) -> String {
        guard !boundaries.isEmpty else { return groups.title(for: groups.now) }
        if group == 0 { return groups.title(for: groups.now) }
        if group < boundaries.count { return groups.title(for: boundaries[group]) }
        return groups.title(for: boundaries[boundaries.count - 1].addingTimeInterval(-1))
    }
}

// MARK: - Masks

/// The label bits one account's views are tested against.
struct ListMasks {
    let index: GmailIndexSnapshot
    let unread: UInt64
    let starred: UInt64
    let draft: UInt64
    let spam: UInt64
    let trash: UInt64
    let inbox: UInt64
    let hidden: UInt64
    let otherCategories: UInt64

    init(index: GmailIndexSnapshot, settings: ListIndex.Settings) {
        self.index = index
        func bit(_ label: GmailLabelID) -> UInt64 {
            guard let slot = label.fixedSlot ?? index.labelSlots[label] else { return 0 }
            return 1 << UInt64(slot)
        }
        unread = bit(.unread)
        starred = bit(.starred)
        draft = bit(.draft)
        spam = bit(.spam)
        trash = bit(.trash)
        inbox = bit(.inbox)
        hidden = bit(.spam) | bit(.trash) | bit(.chat)
        var other = bit(.categoryPromotions) | bit(.categorySocial) | bit(.categoryForums)
        if settings.updatesAreOther { other |= bit(.categoryUpdates) }
        otherCategories = other
    }

    func bit(_ label: GmailLabelID) -> UInt64? {
        (label.fixedSlot ?? index.labelSlots[label]).map { 1 << UInt64($0) }
    }

    /// What a record must have, and must not, to be in the view.
    func query(for target: ListBuilder.Target, filters: Set<ListFilter>) -> ListQuery {
        var query = ListQuery()
        switch target {
        case .folder(.archive):
            query.exclude = hidden
        case .folder(.label(let label)):
            if label == .spam || label == .trash {
                query.want = bit(label) ?? 0
                query.exclude = hidden & ~(bit(label) ?? 0)
            } else if let bit = bit(label) {
                query.want = bit
                query.exclude = hidden
            } else {
                query.exclude = hidden
                query.overflow = ListBitset(slots: index.overflow[label] ?? [], capacity: index.records.count)
            }
        case .search:
            break
        }
        if filters.contains(.unread) { query.want |= unread }
        if filters.contains(.flagged) { query.want |= starred }
        if filters.contains(.attachments) { query.attributes |= GmailRecordAttributes.hasAttachment.rawValue }
        if filters.contains(.focused) { query.exclude |= otherCategories }
        if filters.contains(.other) { query.any = otherCategories }
        return query
    }

    /// The row's bits, from the record's labels and attributes.
    @inline(__always)
    func displayBits(_ record: GmailIndexRecord) -> UInt32 {
        let labels = record.labelBits
        var bits: UInt32 = 0
        if labels & unread != 0 { bits |= DisplayBits.unread.rawValue }
        if labels & starred != 0 { bits |= DisplayBits.flagged.rawValue }
        if labels & draft != 0 { bits |= DisplayBits.draft.rawValue }
        if labels & trash != 0 { bits |= DisplayBits.inDeletedItems.rawValue }
        if labels & spam != 0 { bits |= DisplayBits.inJunkEmail.rawValue }
        let attributes = record.attributes.rawValue
        if attributes & GmailRecordAttributes.attachmentKnown.rawValue != 0 {
            bits |= DisplayBits.attachmentKnown.rawValue
            if attributes & GmailRecordAttributes.hasAttachment.rawValue != 0 { bits |= DisplayBits.hasAttachment.rawValue }
        }
        if attributes & GmailRecordAttributes.sizeKnown.rawValue != 0 {
            bits |= DisplayBits.sizeKnown.rawValue | (UInt32((attributes >> 5) & 0b111) << 11)
        }
        return bits
    }
}

/// One view's test on a record: all of `want`, none of `exclude`, at least one of `any`, all of
/// `attributes`, and membership of an overflow label when the view is one.
struct ListQuery {
    var want: UInt64 = 0
    var exclude: UInt64 = 0
    var any: UInt64 = 0
    var attributes: UInt16 = 0
    var overflow: ListBitset?

    mutating func release() {
        overflow?.release()
        overflow = nil
    }
}

/// Membership of an overflow label, one bit per index slot, so the test is as cheap as a label bit.
struct ListBitset {
    private let words: UnsafeMutablePointer<UInt64>
    private let count: Int

    init(slots: ContiguousArray<Int32>, capacity: Int) {
        count = max(1, (capacity + 63) / 64)
        words = .allocate(capacity: count)
        words.initialize(repeating: 0, count: count)
        for slot in slots where slot >= 0 && Int(slot) < capacity {
            words[Int(slot) >> 6] |= 1 << UInt64(slot & 63)
        }
    }

    @inline(__always)
    func contains(_ slot: Int32) -> Bool {
        words[Int(slot) >> 6] & (1 << UInt64(slot & 63)) != 0
    }

    func release() {
        words.deallocate()
    }
}

// MARK: - The passes

enum ListScan {
    static let skipped = GmailRecordAttributes.tombstone.rawValue | GmailRecordAttributes.provisional.rawValue

    /// The view's messages, newest first, as index slots: one pass over the order with one AND.
    static func members(_ index: GmailIndexSnapshot, query: ListQuery, target: ListBuilder.Target) -> ContiguousArray<Int32> {
        if case .search(let hits) = target { return searchMembers(index, hits: hits, query: query) }
        let want = query.want, exclude = query.exclude, any = query.any, attributes = query.attributes
        let overflow = query.overflow
        return index.records.withUnsafeBufferPointer { records in
            index.byOrder.withUnsafeBufferPointer { order in
                ContiguousArray<Int32>(unsafeUninitializedCapacity: order.count) { out, written in
                    var n = 0
                    var i = order.count - 1
                    while i >= 0 {
                        let slot = order[i]
                        let record = records[Int(slot)]
                        let labels = record.labelBits
                        let attrs = record.attributes.rawValue
                        if labels & want == want, labels & exclude == 0, any == 0 || labels & any != 0,
                           attrs & attributes == attributes, attrs & skipped == 0,
                           overflow?.contains(slot) ?? true {
                            out[n] = slot
                            n += 1
                        }
                        i -= 1
                    }
                    written = n
                }
            }
        }
    }

    private static func searchMembers(_ index: GmailIndexSnapshot, hits: ContiguousArray<UInt64>, query: ListQuery) -> ContiguousArray<Int32> {
        var out = ContiguousArray<Int32>()
        out.reserveCapacity(hits.count)
        var seen = Set<Int32>()
        for id in hits {
            guard let slot = index.slotByID[id], seen.insert(slot).inserted else { continue }
            let record = index.records[Int(slot)]
            let labels = record.labelBits
            let attrs = record.attributes.rawValue
            guard labels & query.want == query.want, labels & query.exclude == 0, query.any == 0 || labels & query.any != 0,
                  attrs & query.attributes == query.attributes, attrs & skipped == 0 else { continue }
            out.append(slot)
        }
        return out
    }

    /// One row a message, straight from the order: the view's test and the row in one pass, since
    /// this is the view the table shows most and 200,000 of them must take a few milliseconds.
    static func flat(_ index: GmailIndexSnapshot, query: ListQuery, masks: ListMasks, source: UInt8) -> ContiguousArray<DisplayRecord> {
        let want = query.want, exclude = query.exclude, any = query.any, attributes = query.attributes
        let overflow = query.overflow
        let unreadBit = masks.unread, starredBit = masks.starred, draftBit = masks.draft
        let trashBit = masks.trash, spamBit = masks.spam
        let attachmentKnown = GmailRecordAttributes.attachmentKnown.rawValue
        let hasAttachment = GmailRecordAttributes.hasAttachment.rawValue
        let sizeKnown = GmailRecordAttributes.sizeKnown.rawValue
        var template = DisplayRecord(key: 0, slot: 0, source: source)
        template.kind = DisplayKind.message.rawValue
        return index.records.withUnsafeBufferPointer { records in
            index.byOrder.withUnsafeBufferPointer { order in
                ContiguousArray<DisplayRecord>(unsafeUninitializedCapacity: order.count) { out, written in
                    guard let base = out.baseAddress, let slots = order.baseAddress, let all = records.baseAddress else {
                        written = 0
                        return
                    }
                    var n = 0
                    var i = order.count - 1
                    while i >= 0 {
                        let slot = slots[i]
                        i -= 1
                        let record = all[Int(slot)]
                        let labels = record.labelBits
                        let attrs = record.attributes.rawValue
                        guard labels & want == want, labels & exclude == 0, any == 0 || labels & any != 0,
                              attrs & attributes == attributes, attrs & skipped == 0 else { continue }
                        if let overflow, !overflow.contains(slot) { continue }
                        var bits: UInt32 = 0
                        if labels & unreadBit != 0 { bits |= 1 }
                        if labels & starredBit != 0 { bits |= 1 << 1 }
                        if labels & draftBit != 0 { bits |= 1 << 4 }
                        if labels & trashBit != 0 { bits |= 1 << 8 }
                        if labels & spamBit != 0 { bits |= 1 << 9 }
                        if attrs & attachmentKnown != 0 { bits |= attrs & hasAttachment != 0 ? 0b1100 : 0b1000 }
                        if attrs & sizeKnown != 0 { bits |= 1 << 10 | UInt32((attrs >> 5) & 0b111) << 11 }
                        template.key = record.id
                        template.slot = slot
                        template.bits = bits
                        template.unread = UInt16(bits & 1)
                        (base + n).initialize(to: template)
                        n += 1
                    }
                    written = n
                }
            }
        }
    }

    /// One row a message, in the members' order.
    static func messages(_ index: GmailIndexSnapshot, members: ContiguousArray<Int32>, masks: ListMasks,
                         source: UInt8) -> ContiguousArray<DisplayRecord> {
        index.records.withUnsafeBufferPointer { records in
            members.withUnsafeBufferPointer { slots in
                ContiguousArray<DisplayRecord>(unsafeUninitializedCapacity: slots.count) { out, written in
                    var i = 0
                    while i < slots.count {
                        let slot = slots[i]
                        let record = records[Int(slot)]
                        let bits = masks.displayBits(record)
                        (out.baseAddress! + i).initialize(to: DisplayRecord(
                            key: record.id, slot: slot, bits: DisplayBits(rawValue: bits), members: 1,
                            unread: bits & DisplayBits.unread.rawValue != 0 ? 1 : 0, group: 0,
                            kind: .message, source: source))
                        i += 1
                    }
                    written = slots.count
                }
            }
        }
    }

    /// One row a conversation, where its newest member in the view sits. A conversation that has
    /// only this message in the view but others elsewhere, such as the owner's replies in Sent,
    /// is still a conversation, as in Outlook.
    static func conversations(_ index: GmailIndexSnapshot, members: ContiguousArray<Int32>, masks: ListMasks,
                              target: ListBuilder.Target, source: UInt8) -> ContiguousArray<DisplayRecord> {
        var table = ThreadTable(expected: members.count)
        defer { table.release() }
        let carried = DisplayBits.unread.rawValue | DisplayBits.flagged.rawValue | DisplayBits.hasAttachment.rawValue
            | DisplayBits.attachmentKnown.rawValue
        // Whether each thread has messages outside the view, counted by the folders that may
        // show them: never Junk Email, Deleted Items or chats, unless the view is one.
        var hidden = masks.hidden
        if case .folder(.label(let label)) = target, label == .spam || label == .trash {
            hidden = masks.hidden & ~(masks.bit(label) ?? 0)
        }
        var template = DisplayRecord(key: 0, slot: 0, source: source)
        template.kind = DisplayKind.message.rawValue
        return index.records.withUnsafeBufferPointer { records in
            let all = records.baseAddress
            var rows = members.withUnsafeBufferPointer { slots in
                ContiguousArray<DisplayRecord>(unsafeUninitializedCapacity: slots.count) { out, written in
                    guard let base = out.baseAddress, let list = slots.baseAddress, let all else {
                        written = 0
                        return
                    }
                    var n: Int32 = 0
                    var i = 0
                    while i < slots.count {
                        let slot = list[i]
                        i += 1
                        let record = all[Int(slot)]
                        let bits = masks.displayBits(record)
                        let unread = UInt16(bits & 1)
                        let row = table.findOrInsert(record.threadID, next: n)
                        if row < n {
                            let existing = base + Int(row)
                            if existing.pointee.members < .max { existing.pointee.members += 1 }
                            if existing.pointee.unread < .max { existing.pointee.unread += unread }
                            existing.pointee.bits |= bits & carried
                        } else {
                            template.key = record.id
                            template.slot = slot
                            template.bits = bits
                            template.unread = unread
                            (base + Int(n)).initialize(to: template)
                            n += 1
                        }
                    }
                    written = Int(n)
                }
            }
            let totals = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, rows.count))
            totals.initialize(repeating: 0, count: max(1, rows.count))
            defer { totals.deallocate() }
            index.byOrder.withUnsafeBufferPointer { order in
                guard let slots = order.baseAddress, let all else { return }
                var i = 0
                while i < order.count {
                    let record = all[Int(slots[i])]
                    i += 1
                    guard record.labelBits & hidden == 0, record.attributes.rawValue & skipped == 0 else { continue }
                    let row = table.find(record.threadID)
                    if row >= 0, totals[Int(row)] < 2 { totals[Int(row)] += 1 }
                }
            }
            let conversation = DisplayKind.conversation.rawValue
            rows.withUnsafeMutableBufferPointer { out in
                for i in out.indices where out[i].members > 1 || totals[i] > 1 { out[i].kind = conversation }
            }
            return rows
        }
    }

    /// The members of opened conversations, newest first, as child rows: every message of the
    /// thread in the folders that may show it, including those outside the view.
    static func children(_ index: GmailIndexSnapshot, threads: Set<ListThreadRef>, masks: ListMasks, target: ListBuilder.Target,
                         source: UInt8) -> [ListThreadRef: [DisplayRecord]] {
        var wanted: [UInt64: ListThreadRef] = [:]
        for ref in threads { if case .gmail(_, let thread) = ref { wanted[thread] = ref } }
        guard !wanted.isEmpty else { return [:] }
        var hidden = masks.hidden
        if case .folder(.label(let label)) = target, label == .spam || label == .trash {
            hidden = masks.hidden & ~(masks.bit(label) ?? 0)
        }
        var out: [ListThreadRef: [DisplayRecord]] = [:]
        for slot in index.byOrder.reversed() {
            let record = index.records[Int(slot)]
            guard let ref = wanted[record.threadID], record.labelBits & hidden == 0, record.attributes.rawValue & skipped == 0 else { continue }
            let bits = masks.displayBits(record)
            out[ref, default: []].append(DisplayRecord(key: record.id, slot: slot, bits: DisplayBits(rawValue: bits),
                                                       unread: bits & DisplayBits.unread.rawValue != 0 ? 1 : 0, kind: .child,
                                                       source: source))
        }
        // A conversation with one message has nothing to open out.
        return out.filter { $0.value.count > 1 }
    }
}

/// Thread ids to row numbers, by open addressing: a dictionary costs several times as much per
/// message, and grouping 200,000 has to stay well under a frame's worth of work times six.
struct ThreadTable {
    private let keys: UnsafeMutablePointer<UInt64>
    private let values: UnsafeMutablePointer<Int32>
    private let mask: Int

    init(expected: Int) {
        var capacity = 16
        while capacity < expected * 2 { capacity <<= 1 }
        keys = .allocate(capacity: capacity)
        values = .allocate(capacity: capacity)
        values.initialize(repeating: -1, count: capacity)
        keys.initialize(repeating: 0, count: capacity)
        mask = capacity - 1
    }

    @inline(__always)
    private func home(_ key: UInt64) -> Int {
        Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 32) & mask
    }

    /// The row already given to `key`, or `next` after giving it that.
    @inline(__always)
    mutating func findOrInsert(_ key: UInt64, next: Int32) -> Int32 {
        var i = home(key)
        while true {
            let value = values[i]
            if value < 0 {
                keys[i] = key
                values[i] = next
                return next
            }
            if keys[i] == key { return value }
            i = (i + 1) & mask
        }
    }

    @inline(__always)
    func find(_ key: UInt64) -> Int32 {
        var i = home(key)
        while true {
            let value = values[i]
            if value < 0 { return -1 }
            if keys[i] == key { return value }
            i = (i + 1) & mask
        }
    }

    func release() {
        keys.deallocate()
        values.deallocate()
    }
}
