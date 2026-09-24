import Foundation

/// Message web views and HTTP responses are kept in memory only. Earlier builds let WebKit and
/// URLSession write them to `~/Library/Caches/com.falconmail.app`, outside every limit FalconMail
/// keeps; what those caches wrote there is removed once.
public enum LegacyCaches {
    public static let bundleIdentifier = "com.falconmail.app"

    /// What URLSession's disk cache and WebKit's website data put in the app's caches folder,
    /// and nothing else: a file some other part of macOS keeps there is left alone.
    static let entries = ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData", "WebKit"]

    /// Removes those entries from FalconMail's own folder in `caches`, and only when running as
    /// FalconMail itself, not a build under another identifier. Returns the names removed.
    @discardableResult
    public static func remove(from caches: URL, runningAs identifier: String?) -> [String] {
        guard identifier == bundleIdentifier else { return [] }
        let folder = caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
        var removed: [String] = []
        for name in entries {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                removed.append(name)
            } catch {
                Log.info("app", "could not remove \(name) from the caches folder: \(error.localizedDescription)")
            }
        }
        if !removed.isEmpty { Log.info("app", "removed old caches: \(removed.joined(separator: ", "))") }
        return removed
    }
}
