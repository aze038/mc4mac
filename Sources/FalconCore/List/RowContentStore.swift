import Foundation

/// The text of rows fetched this session, the newest 5,000 used: what makes scrolling back free.
/// It lives only in memory, so a row seen once comes back grey after a relaunch until it is
/// scrolled into view again, as the owner's rule of keeping only the newest 1,000 on the Mac
/// asks. Reading a row counts as using it, so rows on screen are never the ones to go.
///
/// It is not thread-safe: the list controller keeps one on the main actor, and each account's
/// list source one inside its actor.
public final class RowContentStore {
    public static let defaultCapacity = 5_000

    public let capacity: Int
    private var slots: [RowKey: Int32] = [:]
    private var keys: [RowKey?] = []
    private var values: [MessageRowContent?] = []
    private var newer: [Int32] = []
    private var older: [Int32] = []
    private var free: [Int32] = []
    /// Most recently used.
    private var head: Int32 = -1
    /// Least recently used, the next to go.
    private var tail: Int32 = -1

    public init(capacity: Int = RowContentStore.defaultCapacity) {
        self.capacity = max(1, capacity)
        slots.reserveCapacity(self.capacity)
    }

    public var count: Int { slots.count }

    public func contains(_ key: RowKey) -> Bool { slots[key] != nil }

    /// The row's text, which then counts as the most recently used.
    public func content(for key: RowKey) -> MessageRowContent? {
        guard let slot = slots[key] else { return nil }
        touch(slot)
        return values[Int(slot)]
    }

    /// The row's text without counting it as used, for looking over what is held.
    public func peek(_ key: RowKey) -> MessageRowContent? {
        slots[key].flatMap { values[Int($0)] }
    }

    /// Keeps these rows, and returns the keys that went to make room for them.
    @discardableResult
    public func insert(_ rows: [RowKey: MessageRowContent]) -> [RowKey] {
        var evicted: [RowKey] = []
        for (key, content) in rows {
            if let gone = insert(content, for: key) { evicted.append(gone) }
        }
        return evicted
    }

    /// Keeps one row, and returns the key that went to make room for it.
    @discardableResult
    public func insert(_ content: MessageRowContent, for key: RowKey) -> RowKey? {
        if let slot = slots[key] {
            values[Int(slot)] = content
            touch(slot)
            return nil
        }
        var evicted: RowKey?
        if slots.count >= capacity, tail >= 0 {
            evicted = keys[Int(tail)]
            remove(slot: tail)
        }
        let slot: Int32
        if let reused = free.popLast() {
            slot = reused
            keys[Int(slot)] = key
            values[Int(slot)] = content
        } else {
            slot = Int32(keys.count)
            keys.append(key)
            values.append(content)
            newer.append(-1)
            older.append(-1)
        }
        slots[key] = slot
        pushFront(slot)
        return evicted
    }

    public func remove(_ key: RowKey) {
        guard let slot = slots[key] else { return }
        remove(slot: slot)
    }

    public func removeAll() {
        slots.removeAll(keepingCapacity: true)
        keys.removeAll()
        values.removeAll()
        newer.removeAll()
        older.removeAll()
        free.removeAll()
        head = -1
        tail = -1
    }

    /// Keys from the most recently used to the least.
    public var keysByUse: [RowKey] {
        var out: [RowKey] = []
        var slot = head
        while slot >= 0 {
            if let key = keys[Int(slot)] { out.append(key) }
            slot = older[Int(slot)]
        }
        return out
    }

    // MARK: The list of use

    private func touch(_ slot: Int32) {
        guard slot != head else { return }
        unlink(slot)
        pushFront(slot)
    }

    private func pushFront(_ slot: Int32) {
        newer[Int(slot)] = -1
        older[Int(slot)] = head
        if head >= 0 { newer[Int(head)] = slot }
        head = slot
        if tail < 0 { tail = slot }
    }

    private func unlink(_ slot: Int32) {
        let n = newer[Int(slot)]
        let o = older[Int(slot)]
        if n >= 0 { older[Int(n)] = o } else { head = o }
        if o >= 0 { newer[Int(o)] = n } else { tail = n }
        newer[Int(slot)] = -1
        older[Int(slot)] = -1
    }

    private func remove(slot: Int32) {
        unlink(slot)
        if let key = keys[Int(slot)] { slots[key] = nil }
        keys[Int(slot)] = nil
        values[Int(slot)] = nil
        free.append(slot)
    }
}
