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

/// The groups the list draws when "Show in groups" is on, the same as `ListSort.dayKey`: Today,
/// Yesterday, Earlier this week, Earlier this month, then one group a month.
public enum GmailDateGroups {
    /// The title of the group above every boundary.
    public static let newestTitle = "Today"

    /// The recent boundaries that move every day, which are worked out again at local midnight.
    public static let recentCount = 4

    /// Every boundary from today back to the month of `oldest`, newest first. Without `oldest`,
    /// only the recent four and the month they reach into.
    public static func boundaries(now: Date, oldest: Date?, calendar: Calendar = .current,
                                  locale: Locale = .current) -> [GmailDateBoundary] {
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let week = calendar.date(byAdding: .day, value: -7, to: now),
              let month = calendar.date(byAdding: .month, value: -1, to: now) else { return [] }
        let format = DateFormatter()
        format.calendar = calendar
        format.locale = locale
        format.timeZone = calendar.timeZone
        format.dateFormat = "MMMM yyyy"

        // A message exactly a week or a month old is already in the older group, as dayKey has it.
        let rollingWeek = week.addingTimeInterval(0.001)
        let rollingMonth = month.addingTimeInterval(0.001)
        var out = [
            GmailDateBoundary(date: today, title: "Yesterday"),
            GmailDateBoundary(date: yesterday, title: "Earlier this week"),
            GmailDateBoundary(date: rollingWeek, title: "Earlier this month"),
            GmailDateBoundary(date: rollingMonth, title: format.string(from: month))
        ]
        guard var start = calendar.dateInterval(of: .month, for: month)?.start else { return out }
        let floor = oldest.flatMap { calendar.dateInterval(of: .month, for: $0)?.start } ?? start
        while start > floor {
            guard let previous = calendar.date(byAdding: .month, value: -1, to: start) else { break }
            out.append(GmailDateBoundary(date: start, title: format.string(from: previous)))
            start = previous
        }
        return out
    }
}

/// Keeping anchors true as the index changes, without asking Gmail again for all of them.
public enum GmailDateAnchoring {
    /// Boundaries that have no anchor, and recent ones last asked before the local midnight that
    /// moved them.
    public static func boundariesToAsk(_ boundaries: [GmailDateBoundary], anchors: [GmailDateAnchor], now: Date,
                                       calendar: Calendar = .current) -> [Date] {
        let byBoundary = Dictionary(anchors.map { ($0.boundary, $0) }, uniquingKeysWith: { a, b in a.askedAt >= b.askedAt ? a : b })
        let midnight = calendar.startOfDay(for: now)
        return boundaries.enumerated().compactMap { i, boundary in
            guard let anchor = byBoundary[boundary.date] else { return boundary.date }
            return i < GmailDateGroups.recentCount && anchor.askedAt < midnight ? boundary.date : nil
        }
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
