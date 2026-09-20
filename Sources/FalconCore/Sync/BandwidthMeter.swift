import Foundation

/// Counts what each account downloads per day so a mailbox of any size can never
/// push an account past the provider's daily allowance and get it suspended.
public actor BandwidthMeter {
    public struct Usage: Codable, Sendable {
        public var day: String
        public var bytes: Int
    }

    private var usage: [String: Usage] = [:]
    private let url: URL
    private var dirty = false

    public init(layout: FileLayout = FileLayout()) {
        url = layout.root.appendingPathComponent("bandwidth.json")
        usage = AtomicFile.readJSON([String: Usage].self, from: url) ?? [:]
    }

    public static let shared = BandwidthMeter()

    static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    public func record(_ bytes: Int, for account: UUID) {
        guard bytes > 0 else { return }
        let key = account.uuidString
        let day = BandwidthMeter.today
        var entry = usage[key] ?? Usage(day: day, bytes: 0)
        if entry.day != day { entry = Usage(day: day, bytes: 0) }
        entry.bytes += bytes
        usage[key] = entry
        dirty = true
    }

    public func spentToday(_ account: UUID) -> Int {
        guard let entry = usage[account.uuidString], entry.day == BandwidthMeter.today else { return 0 }
        return entry.bytes
    }

    /// True when another `bytes` can be downloaded without crossing `budget` for today.
    public func allows(_ bytes: Int, for account: UUID, budget: Int) -> Bool {
        spentToday(account) + max(0, bytes) <= budget
    }

    public func persist() {
        guard dirty else { return }
        try? AtomicFile.writeJSON(usage, to: url)
        dirty = false
    }
}
