import Foundation

/// Works out how one snapshot of a view became the next, for the table to animate: rows that
/// stayed are matched by the message they stand for, so a new message at the top is one insert
/// and a read message one reload, not a reload of 200,000 rows.
public enum ListDiffer {
    /// Beyond this many rows changed in the middle, matching them is not worth it: the table
    /// reloads anyway past `ListDiff.reloadThreshold`.
    static let matchLimit = 4_000

    public static func diff(from old: ListSnapshot, to new: ListSnapshot) -> ListDiff {
        guard old.view == new.view else { return .replacing(old, with: new) }
        let oldRows = old.rows, newRows = new.rows
        let oldCount = oldRows.count, newCount = newRows.count

        var prefix = 0
        while prefix < oldCount, prefix < newCount, same(old, prefix, new, prefix) { prefix += 1 }
        var suffix = 0
        while suffix < oldCount - prefix, suffix < newCount - prefix,
              same(old, oldCount - 1 - suffix, new, newCount - 1 - suffix) { suffix += 1 }

        var reloaded = IndexSet()
        for i in 0..<prefix where oldRows[i] != newRows[i] { reloaded.insert(i) }
        for k in 0..<suffix where oldRows[oldCount - 1 - k] != newRows[newCount - 1 - k] { reloaded.insert(newCount - 1 - k) }

        let oldMiddle = prefix..<(oldCount - suffix)
        let newMiddle = prefix..<(newCount - suffix)
        var removed = IndexSet(integersIn: oldMiddle)
        var inserted = IndexSet(integersIn: newMiddle)
        if !oldMiddle.isEmpty, !newMiddle.isEmpty, oldMiddle.count + newMiddle.count <= matchLimit {
            // Rows found in both, kept in the longest run that stays in order; the rest move.
            var placeInNew: [Identity: Int] = [:]
            for j in newMiddle { placeInNew[identity(new, j)] = j }
            var pairs: [(old: Int, new: Int)] = []
            for i in oldMiddle { if let j = placeInNew[identity(old, i)] { pairs.append((i, j)) } }
            for pair in longestIncreasing(pairs) {
                removed.remove(pair.old)
                inserted.remove(pair.new)
                if oldRows[pair.old] != newRows[pair.new] { reloaded.insert(pair.new) }
            }
        }
        return ListDiff(inserted: inserted, removed: removed, reloaded: reloaded, snapshot: new)
    }

    /// What a row stands for, whichever snapshot it is in.
    enum Identity: Hashable {
        case gmail(UUID, UInt64, UInt8)
        case stored(String, UInt8)
        case header(String)
        case unknown(Int)
    }

    static func identity(_ snapshot: ListSnapshot, _ i: Int) -> Identity {
        let record = snapshot.rows[i]
        if record.displayKind == .header { return .header(snapshot.headers[Int(record.group)] ?? "") }
        if record.displayBits.contains(.storedRow) {
            let slot = Int(record.slot)
            return snapshot.storedKeys.indices.contains(slot) ? .stored(snapshot.storedKeys[slot], record.kind) : .unknown(i)
        }
        let source = Int(record.source)
        return snapshot.sources.indices.contains(source) ? .gmail(snapshot.sources[source], record.key, record.kind) : .unknown(i)
    }

    @inline(__always)
    private static func same(_ a: ListSnapshot, _ i: Int, _ b: ListSnapshot, _ j: Int) -> Bool {
        let x = a.rows[i], y = b.rows[j]
        guard x.kind == y.kind else { return false }
        if x.displayKind == .header { return a.headers[Int(x.group)] == b.headers[Int(y.group)] }
        let storedX = x.displayBits.contains(.storedRow), storedY = y.displayBits.contains(.storedRow)
        guard storedX == storedY else { return false }
        if storedX {
            guard a.storedKeys.indices.contains(Int(x.slot)), b.storedKeys.indices.contains(Int(y.slot)) else { return false }
            return a.storedKeys[Int(x.slot)] == b.storedKeys[Int(y.slot)]
        }
        guard x.key == y.key, a.sources.indices.contains(Int(x.source)), b.sources.indices.contains(Int(y.source)) else { return false }
        return a.sources[Int(x.source)] == b.sources[Int(y.source)]
    }

    /// The longest subsequence of `pairs`, already in old order, whose new places rise too.
    static func longestIncreasing(_ pairs: [(old: Int, new: Int)]) -> [(old: Int, new: Int)] {
        guard !pairs.isEmpty else { return [] }
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: pairs.count)
        for (i, pair) in pairs.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if pairs[tails[mid]].new < pair.new { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[i] = tails[low - 1] }
            if low == tails.count { tails.append(i) } else { tails[low] = i }
        }
        var out: [(old: Int, new: Int)] = []
        var i = tails.last ?? -1
        while i >= 0 {
            out.append(pairs[i])
            i = previous[i]
        }
        return out.reversed()
    }
}
