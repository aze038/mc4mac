import Foundation

// Date group headers ("Show in groups") without a date for every message. The header for a
// boundary goes before the first message older than it, and that message, the anchor, is found
// with one `before:` search of 5 units; the order of the index does the rest. Anchors are
// account-wide: each view puts a header before its first member at or below the anchor.

/// Where one date group ends and the next, older one begins.
public struct GmailDateBoundary: Hashable, Sendable {
    /// Messages older than this belong to the group below.
    public var date: Date
    /// The title of the group that begins here.
    public var title: String

    public init(date: Date, title: String) {
        self.date = date
        self.title = title
    }
}

/// The groups the list draws when "Show in groups" is on, with the list's names: Today,
/// Yesterday, Earlier this week, Earlier this month, then one group a month. Every boundary is a
/// local midnight, so a boundary is one fixed moment: an anchor found for it stays true until
/// mail is placed deep beside it, and after midnight only the new boundaries are asked for. The
/// list (`ListDateGroups`) and the engine both take their boundaries from here, so the anchors
/// the engine saves are the ones the list looks for.
public enum GmailDateGroups {
    /// The title of the group above every boundary.
    public static let newestTitle = "Today"

    /// The boundaries that move every day, which are new at each local midnight.
    public static let recentCount = 4

    /// The recent boundaries as they stand now.
    public static func recent(now: Date, calendar: Calendar = .current) -> [Date] {
        boundaries(now: now, oldest: nil, calendar: calendar).prefix(recentCount).map(\.date)
    }

    /// Every boundary from today back to the month of `oldest`, newest first, each with the title
    /// of the group below it. Without `oldest`, only the recent four. With `daily`, every midnight
    /// of the last month as well, so rows of several accounts can be placed among each other to
    /// the day (§5.3).
    public static func boundaries(now: Date, oldest: Date?, daily: Bool = false, calendar: Calendar = .current,
                                  locale: Locale = .current) -> [GmailDateBoundary] {
        let edges = Edges(now: now, calendar: calendar)
        var dates: Set<Date> = [edges.today, edges.yesterday, edges.week, edges.month]
        if daily {
            var day = edges.yesterday
            while let next = calendar.date(byAdding: .day, value: -1, to: day), next > edges.month {
                day = next
                dates.insert(day)
            }
        }
        if let oldest, var start = calendar.dateInterval(of: .month, for: edges.month.addingTimeInterval(-1))?.start {
            let floor = calendar.dateInterval(of: .month, for: oldest)?.start ?? oldest
            while start > floor {
                dates.insert(start)
                guard let previous = calendar.date(byAdding: .month, value: -1, to: start) else { break }
                start = previous
            }
        }
        return dates.sorted(by: >).map { date in
            // The group below a boundary is the one its last moment before falls in.
            GmailDateBoundary(date: date, title: title(for: date.addingTimeInterval(-1), edges: edges, calendar: calendar, locale: locale))
        }
    }

    /// The group a date falls in, as the list names it.
    public static func title(for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        title(for: date, edges: Edges(now: now, calendar: calendar), calendar: calendar, locale: locale)
    }

    private static func title(for date: Date, edges: Edges, calendar: Calendar, locale: Locale) -> String {
        if date >= edges.today { return newestTitle }
        if date >= edges.yesterday { return "Yesterday" }
        if date >= edges.week { return "Earlier this week" }
        if date >= edges.month { return "Earlier this month" }
        let format = DateFormatter()
        format.calendar = calendar
        format.locale = locale
        format.timeZone = calendar.timeZone
        format.dateFormat = "MMMM yyyy"
        return format.string(from: date)
    }

    /// The four recent boundaries: today's midnight, yesterday's, the midnight six days before
    /// today and the one a month before today.
    struct Edges {
        let today: Date
        let yesterday: Date
        let week: Date
        let month: Date

        init(now: Date, calendar: Calendar) {
            today = calendar.startOfDay(for: now)
            yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
            week = calendar.date(byAdding: .day, value: -6, to: today) ?? today.addingTimeInterval(-6 * 86_400)
            month = calendar.date(byAdding: .month, value: -1, to: today) ?? today.addingTimeInterval(-30 * 86_400)
        }
    }
}

/// Keeping anchors true as the index changes, without asking Gmail again for all of them.
public enum GmailDateAnchoring {
    /// Boundaries that have no anchor yet. Each boundary is a fixed midnight, so an anchor asked
    /// on an earlier day still holds; what can move one is mail placed deep beside it, which
    /// `boundariesToAskAgain` finds.
    public static func boundariesToAsk(_ boundaries: [GmailDateBoundary], anchors: [GmailDateAnchor]) -> [Date] {
        let known = Set(anchors.map(\.boundary))
        return boundaries.map(\.date).filter { !known.contains($0) }
    }

    /// After messages were placed deep in the order, by a relisting, an import or a late arrival:
    /// only a boundary with one of them directly above its anchor can have moved, since everything
    /// else above an anchor is at least as new as the boundary. An anchor with no message older
    /// than its boundary moves when a placed message is the oldest of all.
    public static func boundariesToAskAgain(_ anchors: [GmailDateAnchor], placed: Set<GmailMessageID>,
                                            in index: GmailIndexSnapshot) -> [Date] {
        guard !placed.isEmpty, !index.byOrder.isEmpty else { return [] }
        return resolve(anchors, in: index).compactMap { anchor in
            let above: Int
            if let id = anchor.id, let order = anchor.order {
                above = position(order: order, id: id.raw, in: index) + 1
            } else {
                above = 0
            }
            guard above < index.byOrder.count else { return nil }
            return placed.contains(index.records[Int(index.byOrder[above])].gmailID) ? anchor.boundary : nil
        }
    }

    /// Anchors as the index stands now: each takes its message's current order, and an anchor
    /// whose message has gone moves to the next older message, which is then the newest one older
    /// than the boundary.
    public static func resolve(_ anchors: [GmailDateAnchor], in index: GmailIndexSnapshot) -> [GmailDateAnchor] {
        anchors.map { anchor in
            guard let id = anchor.id else { return anchor }
            var out = anchor
            if let record = index.record(for: id), !record.attributes.contains(.tombstone) {
                out.order = record.order
                return out
            }
            guard let order = anchor.order else {
                out.id = nil
                return out
            }
            let below = position(order: order, id: id.raw, in: index) - 1
            if below >= 0 {
                let record = index.records[Int(index.byOrder[below])]
                out.id = record.gmailID
                out.order = record.order
            } else {
                out.id = nil
                out.order = nil
            }
            return out
        }
    }

    /// Where a message of this order and id stands among the live ones, or, once it has gone,
    /// where the next newer message now stands.
    private static func position(order: UInt32, id: UInt64, in index: GmailIndexSnapshot) -> Int {
        var low = 0
        var high = index.byOrder.count
        while low < high {
            let mid = (low + high) / 2
            let r = index.records[Int(index.byOrder[mid])]
            if r.order < order || (r.order == order && r.id < id) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// Finds date anchors and keeps them: one `before:` listing of 5 units for each boundary without
/// one. The account's engine owns one and hands it to the list, so `anchors.json` has one writer
/// and a boundary the list and the engine both want is asked once. Work runs one piece at a time,
/// so two asks never save over each other.
public actor GmailDateAnchorFiller {
    private let store: any GmailStore
    private let transport: any GmailTransport
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    /// Boundaries whose newest older message the index does not hold yet, left until the index
    /// changes, since asking again would only find the same message.
    private var unplaced: Set<Date> = []
    private var oldest: Date?
    /// Once a view has merged accounts by date, the daily boundaries are kept up too.
    private var daily = false
    private var running: Task<Void, Never>?

    public init(store: any GmailStore, transport: any GmailTransport, now: @escaping @Sendable () -> Date = { Date() },
                calendar: Calendar = .current) {
        self.store = store
        self.transport = transport
        self.now = now
        self.calendar = calendar
    }

    /// Asks for every boundary that has no anchor yet. True when an anchor was learnt. A boundary
    /// Gmail could not be asked about is asked again at the next fill.
    @discardableResult
    public func fill(daily wantsDaily: Bool = false) async -> Bool {
        daily = daily || wantsDaily
        return await serially { await self.fillNow() }
    }

    /// Asks these boundaries again, whatever anchors they have, as after mail was placed deep
    /// beside them. Throws when Gmail could not be asked.
    @discardableResult
    public func ask(_ boundaries: [Date]) async throws -> Bool {
        guard !boundaries.isEmpty else { return false }
        let outcome: Result<Bool, Error> = await serially {
            do { return .success(try await self.askNow(boundaries, keep: true)) } catch { return .failure(error) }
        }
        return try outcome.get()
    }

    /// The index changed, as after a listing or a deep placement: boundaries that had no placed
    /// neighbour may have one now.
    public func indexChanged() {
        unplaced = []
    }

    private func serially<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let previous = running
        let task = Task { () -> T in
            await previous?.value
            return await work()
        }
        running = Task { _ = await task.value }
        return await task.value
    }

    private func fillNow() async -> Bool {
        let snapshot = await store.index()
        if oldest == nil, let first = snapshot.byOrder.first {
            let id = snapshot.records[Int(first)].gmailID
            if let cached = await store.cachedMessages([id])[id] {
                oldest = cached.date
            } else {
                oldest = try? await transport.message(id, format: .minimal, work: .background(.index)).receivedDate
            }
        }
        let wanted = GmailDateGroups.boundaries(now: now(), oldest: oldest, daily: daily, calendar: calendar)
        let due = GmailDateAnchoring.boundariesToAsk(wanted, anchors: await store.dateAnchors()).filter { !unplaced.contains($0) }
        return (try? await askNow(due, keep: false)) ?? false
    }

    /// Asks each boundary in turn and saves what was learnt, even when a later one fails.
    private func askNow(_ boundaries: [Date], keep: Bool) async throws -> Bool {
        guard !boundaries.isEmpty else { return false }
        let snapshot = await store.index()
        // Anchors of boundaries no view uses any more go; those of the daily boundaries stay
        // while any view might merge accounts.
        let used = Set(GmailDateGroups.boundaries(now: now(), oldest: oldest ?? .distantPast, daily: true, calendar: calendar).map(\.date))
        var anchors = Dictionary((await store.dateAnchors()).filter { used.contains($0.boundary) || keep }.map { ($0.boundary, $0) },
                                 uniquingKeysWith: { a, b in a.askedAt >= b.askedAt ? a : b })
        var learnt = false
        var failure: Error?
        for boundary in boundaries {
            let query = GmailListQuery(query: "before:\(Int(boundary.timeIntervalSince1970))", includeSpamTrash: true, maxResults: 1)
            let page: GmailListPage
            do {
                page = try await transport.list(query, work: .background(.index))
            } catch {
                failure = error
                break
            }
            let ref = page.refs.first
            let order = ref.flatMap { snapshot.record(for: $0.id)?.order }
            if ref != nil, order == nil {
                // Gmail has an older message the index has not placed yet: an anchor without its
                // order would put the header at the bottom.
                unplaced.insert(boundary)
                continue
            }
            anchors[boundary] = GmailDateAnchor(boundary: boundary, id: ref?.id, order: order, askedAt: now())
            learnt = true
        }
        if learnt { try? await store.saveDateAnchors(anchors.values.sorted { $0.boundary > $1.boundary }) }
        if let failure { throw failure }
        return learnt
    }
}

/// `anchors.json`.
enum GmailDateAnchorFile {
    static func load(from url: URL) -> [GmailDateAnchor] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([GmailDateAnchor].self, from: data)) ?? []
    }

    static func save(_ anchors: [GmailDateAnchor], to url: URL, io: GmailDiskIO) throws {
        try io.replace(try JSONEncoder().encode(anchors), at: url)
    }
}
