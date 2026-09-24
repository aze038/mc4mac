import Foundation

extension Data {
    public var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }

    public static func random(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }

    public var utf8Lossy: String { String(decoding: self, as: UTF8.self) }
}

extension String {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    public func removingPrefix(_ p: String) -> String {
        hasPrefix(p) ? String(dropFirst(p.count)) : self
    }

    public var urlQueryEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

extension Dictionary where Key == String, Value == String {
    public var formURLEncoded: Data {
        map { "\($0.key.urlQueryEncoded)=\($0.value.urlQueryEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}

extension ISO8601DateFormatter {
    public static let archive: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

public enum Log {
    public static var isEnabled = true
    private static let queue = DispatchQueue(label: "falconmail.log")
    /// Where lines go. Nowhere until the app names its data folder, so that nothing else that
    /// links FalconCore, the tests among them, can write into the owner's log.
    private static var fileURL: URL?
    static let maxFileBytes = 2_000_000
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Starts writing `falconmail.log` in `directory`.
    public static func start(in directory: URL) {
        queue.sync {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent("falconmail.log")
        }
    }

    public static func info(_ area: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "\(stamp.string(from: Date())) [\(area)] \(message())\n"
        print(line, terminator: "")
        queue.async {
            guard let url = fileURL else { return }
            rotateIfFull(url)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Returns once every line logged before the call has reached the file.
    public static func flush() {
        queue.sync {}
    }

    /// A full log becomes `falconmail.1.log`, replacing the one before it, so the newest lines
    /// always survive: the old way deleted the whole file, and with it the lead-up to whatever
    /// had just gone wrong.
    private static func rotateIfFull(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxFileBytes else { return }
        let older = url.deletingLastPathComponent().appendingPathComponent("falconmail.1.log")
        try? FileManager.default.removeItem(at: older)
        try? FileManager.default.moveItem(at: url, to: older)
    }

    private static let addressPattern = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")

    /// `text` with every email address but `own` replaced, for server replies that can name
    /// the people a message was for. Only the account's own address ever goes into the log.
    public static func redacted(_ text: String, keeping own: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var out = text
        for match in addressPattern.matches(in: text, range: range).reversed() {
            guard let r = Range(match.range, in: out) else { continue }
            if out[r].caseInsensitiveCompare(own) == .orderedSame { continue }
            out.replaceSubrange(r, with: "<address>")
        }
        return out
    }
}
