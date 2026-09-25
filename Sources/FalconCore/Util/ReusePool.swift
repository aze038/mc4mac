import Foundation

/// Objects kept for reuse, as the reading pane keeps its web views: each handed out to one
/// user at a time, and taken back only once.
///
/// Anything that could leave two users sharing one object is refused rather than trusted: an
/// object given back twice, given back while `isFree` says it is still in use (a web view still
/// in a window), or marked `unusable` (a web view whose page process died, or whose page never
/// finished loading) is dropped instead of kept, and `take` never hands out an object that is
/// out already.
@MainActor
public final class ReusePool<Item: AnyObject> {
    public let capacity: Int
    private var free: [Item] = []
    private var out: [ObjectIdentifier: Item] = [:]
    private var unusable = Set<ObjectIdentifier>()
    private let isFree: @MainActor (Item) -> Bool

    /// `isFree` says whether an object given back is really free now; one that is not is dropped.
    public init(capacity: Int, isFree: @escaping @MainActor (Item) -> Bool = { _ in true }) {
        self.capacity = capacity
        self.isFree = isFree
    }

    /// How many are kept for reuse, and how many are out.
    public var freeCount: Int { free.count }
    public var outCount: Int { out.count }

    public func isOut(_ item: Item) -> Bool { out[ObjectIdentifier(item)] != nil }

    /// A kept object that is free, or a new one from `make`.
    public func take(_ make: () -> Item) -> Item {
        while let candidate = free.popLast() {
            let id = ObjectIdentifier(candidate)
            guard out[id] == nil, !unusable.contains(id), isFree(candidate) else { continue }
            out[id] = candidate
            return candidate
        }
        let made = make()
        out[ObjectIdentifier(made)] = made
        return made
    }

    /// `item` is not to be handed out again, whether it is out now or kept.
    public func markUnusable(_ item: Item) {
        let id = ObjectIdentifier(item)
        free.removeAll { $0 === item }
        // Remembered only while it is out: the identity of an object gone may be another's later.
        if out[id] != nil { unusable.insert(id) }
    }

    /// Everything kept is dropped, as when the process they all share has died.
    public func dropFree() {
        free.removeAll()
    }

    /// `item` given back. True when it is kept for reuse; false when it is dropped: given back
    /// already, never handed out by this pool, unusable, not really free, or the pool is full.
    @discardableResult
    public func giveBack(_ item: Item) -> Bool {
        let id = ObjectIdentifier(item)
        guard out.removeValue(forKey: id) != nil else { return false }
        if unusable.remove(id) != nil { return false }
        guard isFree(item), free.count < capacity, !free.contains(where: { $0 === item }) else { return false }
        free.append(item)
        return true
    }
}
