import Foundation

// Where a message goes in the account's order (§4.3). The order is a number per message: newer is
// larger, and listings leave gaps of 16 so that mail learnt about later can be put between two
// messages without moving either. Mail that arrived now goes above the top; any other mail goes
// just above the newest message older than it, which one `before:` search finds.

/// The arithmetic of the order, kept apart from the engine so every edge can be tested directly.
public enum GmailOrderSpace {
    public static let step = GmailIndexRecord.orderStep
    /// Kept free at the top of the number range so a check can always put new mail above
    /// everything, however long the owner goes between relistings.
    static let headroom: UInt32 = 16 * 4_000_000

    /// Orders for `count` messages that arrived now, oldest first, above everything up to `ceiling`.
    public static func top(count: Int, above ceiling: UInt32) -> [UInt32] {
        guard count > 0 else { return [] }
        return (1...count).map { ceiling &+ step * UInt32($0) }
    }

    /// Orders for `count` messages put between `low` and `high`, oldest first, evenly spread;
    /// nil when the gap is too small for them.
    public static func between(_ low: UInt32, _ high: UInt32, count: Int) -> [UInt32]? {
        guard count > 0 else { return [] }
        guard high > low else { return nil }
        let spacing = UInt64(high - low) / UInt64(count + 1)
        guard spacing >= 1 else { return nil }
        return (1...count).map { UInt32(UInt64(low) + spacing * UInt64($0)) }
    }

    /// Orders for `count` messages going in just above `low`, and, when the gap there is used up,
    /// new orders for as few of the messages above as must move up to make room, with a full step
    /// between every one. `above` holds the orders of the messages above `low`, lowest first, as
    /// far as the caller looked; `reachesTop` says it goes all the way to the top, so the top may
    /// rise. Nil when the messages looked at cannot make room.
    public static func renumber(above low: UInt32, inserting count: Int, neighbours above: [UInt32], reachesTop: Bool,
                                ceiling: UInt32) -> (inserted: [UInt32], moved: [UInt32])? {
        guard count > 0 else { return ([], []) }
        if let first = above.first {
            if let fits = between(low, first, count: count) { return (fits, []) }
        } else if reachesTop {
            return (top(count: count, above: max(low, ceiling)), [])
        } else {
            return nil
        }
        for moving in 1...above.count {
            let slots = UInt64(count + moving + 1)
            let limit: UInt64
            if moving < above.count {
                limit = UInt64(above[moving])
            } else if reachesTop {
                // Everything above moves, so the top rises by as much as it needs.
                limit = UInt64(max(low, ceiling)) + UInt64(step) * slots
            } else {
                return nil
            }
            guard limit > UInt64(low) else { continue }
            let spacing = (limit - UInt64(low)) / slots
            guard spacing >= UInt64(step) else { continue }
            let orders = (1..<Int(slots)).map { UInt32(UInt64(low) + spacing * UInt64($0)) }
            return (Array(orders.prefix(count)), Array(orders.dropFirst(count)))
        }
        return nil
    }

    /// The band a listing of about `messages` messages takes: its orders run down from `top`, so the
    /// newest listed gets `top` and each older one a step less. It starts above `ceiling`, so mail
    /// placed at the top meanwhile stays above what the listing has not reached yet. When the band
    /// would reach into the headroom, it starts again from the bottom of the range instead, and
    /// the listing moves every message down as it goes.
    public static func band(for messages: Int, above ceiling: UInt32) -> (top: UInt32, size: UInt32) {
        let count = UInt64(max(messages, 0))
        let slots = count + count / 10 + 1_000
        let size = min(UInt64(step) * slots, UInt64(UInt32.max) - UInt64(headroom))
        let limit = UInt64(UInt32.max) - UInt64(headroom)
        if UInt64(ceiling) + size <= limit {
            return (UInt32(UInt64(ceiling) + size), UInt32(size))
        }
        return (UInt32(size), UInt32(size))
    }
}

/// One message to put deep in the order: mail that did not arrive now, such as an import, or a
/// message a listing skipped.
struct GmailDeepPlacement: Sendable {
    var ref: GmailRef
    var labels: Set<GmailLabelID>
    var internalDate: Date
    var attributes: GmailRecordAttributes
}

extension GmailAccountEngine {
    /// Puts messages deep in the order, each just above the newest message older than it, found
    /// with one `before:` search (5 units). Messages that share a neighbour go in together, oldest
    /// first; when a gap is used up its neighbours move up, journaled as upserts. The changes are
    /// returned for the check to journal with its cursor. A message whose neighbour is not in the
    /// index yet waits to be placed, since a listing still running will reach it.
    func deepChanges(for items: [GmailDeepPlacement], work: WorkClass) async -> (changes: [GmailChange], waiting: [GmailRef]) {
        guard !items.isEmpty else { return ([], []) }
        var byNeighbour: [UInt64: [GmailDeepPlacement]] = [:]
        var bottom: [GmailDeepPlacement] = []
        var waiting: [GmailRef] = []
        let batch = Set(items.map(\.ref.id.raw))
        // A list call costs the same however many ids it returns, so each search asks for enough to
        // see past the other messages placed with it, which share its neighbour.
        let window = min(500, items.count + 5)
        for item in items {
            let seconds = Int(item.internalDate.timeIntervalSince1970.rounded(.down))
            let query = GmailListQuery(query: "before:\(seconds)", includeSpamTrash: true, maxResults: window)
            do {
                let page = try await transport.list(query, work: work)
                var neighbour: GmailRef?
                for ref in page.refs where ref.id != item.ref.id && !batch.contains(ref.id.raw) {
                    if let record = await store.record(for: ref.id), Self.isSettled(record) {
                        neighbour = ref
                        break
                    }
                }
                if let neighbour {
                    byNeighbour[neighbour.id.raw, default: []].append(item)
                } else if page.nextPageToken == nil {
                    // Nothing settled is older: it goes at the bottom.
                    bottom.append(item)
                } else {
                    waiting.append(item.ref)
                }
            } catch {
                waiting.append(item.ref)
            }
        }
        guard !byNeighbour.isEmpty || !bottom.isEmpty else { return ([], waiting) }

        let snapshot = await store.index()
        // The order as it will stand, lowest first, with each group's messages added as it goes,
        // so a later group never puts a message out of place beside an earlier one.
        var entries: [(order: UInt32, slot: Int32?, id: UInt64)] = liveOrder(snapshot).map {
            (snapshot.records[Int($0)].order, $0, snapshot.records[Int($0)].id)
        }
        var placed: [UInt64: (item: GmailDeepPlacement, order: UInt32)] = [:]
        var moved: [Int32: UInt32] = [:]
        var groups: [(low: UInt32?, neighbour: UInt64?, items: [GmailDeepPlacement])] = byNeighbour.compactMap { key, items in
            guard let slot = snapshot.slotByID[key] else { return nil }
            return (snapshot.records[Int(slot)].order, key, items)
        }
        if !bottom.isEmpty { groups.append((nil, nil, bottom)) }
        groups.sort { ($0.low ?? 0) < ($1.low ?? 0) }

        for group in groups {
            let items = group.items.sorted { ($0.internalDate, $0.ref.id) < ($1.internalDate, $1.ref.id) }
            var position = 0
            if let neighbour = group.neighbour {
                guard let at = entries.firstIndex(where: { $0.id == neighbour }) else {
                    waiting += items.map(\.ref)
                    continue
                }
                position = at + 1
            }
            let low = position > 0 ? entries[position - 1].order : 0
            let window = Array(entries[position..<min(entries.count, position + 256)])
            let reachesTop = position + window.count >= entries.count
            guard let plan = GmailOrderSpace.renumber(above: low, inserting: items.count, neighbours: window.map(\.order),
                                                      reachesTop: reachesTop, ceiling: ceiling) else {
                // Hundreds of messages packed into one gap: the next relisting spreads them out.
                Log.info("gmail", "\(account.email): no room in the order; \(items.count) messages wait to be placed")
                waiting += items.map(\.ref)
                continue
            }
            for (offset, order) in plan.moved.enumerated() {
                let entry = entries[position + offset]
                entries[position + offset].order = order
                if let slot = entry.slot { moved[slot] = order } else { placed[entry.id]?.order = order }
                ceiling = max(ceiling, order)
            }
            let fresh = zip(items, plan.inserted).map { (order: $0.1, slot: Int32?.none, id: $0.0.ref.id.raw) }
            entries.insert(contentsOf: fresh, at: position)
            for (item, order) in zip(items, plan.inserted) {
                placed[item.ref.id.raw] = (item, order)
                ceiling = max(ceiling, order)
            }
        }

        var changes: [GmailChange] = placed.values.sorted { $0.order < $1.order }.map {
            .place($0.item.ref, order: $0.order, labels: $0.item.labels, attributes: $0.item.attributes)
        }
        for (slot, order) in moved.sorted(by: { $0.value < $1.value }) {
            let record = snapshot.records[Int(slot)]
            changes.append(.place(record.ref, order: order, labels: snapshot.labels(atSlot: slot),
                                  attributes: record.attributes.subtracting(.cached)))
        }
        if !moved.isEmpty {
            Log.info("gmail", "\(account.email): moved \(moved.count) messages up to make room in the order")
        }
        return (changes, waiting)
    }

    /// A provisional message, one another app is importing, is not shown and has no settled place,
    /// so it never serves as a neighbour.
    static func isSettled(_ record: GmailIndexRecord) -> Bool {
        !record.attributes.contains(.tombstone) && !record.attributes.contains(.provisional)
    }

    /// Slots of the messages that count in the order, lowest order first.
    func liveOrder(_ snapshot: GmailIndexSnapshot) -> [Int32] {
        snapshot.byOrder.filter { !snapshot.records[Int($0)].attributes.contains(.provisional) }
    }
}
