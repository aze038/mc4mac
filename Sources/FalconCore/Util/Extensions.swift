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

    /// Only RFC 3986's unreserved characters stay as they are. `CharacterSet.alphanumerics` would
    /// also pass letters such as "é" or "д" through unencoded, which is not a valid query.
    public var urlQueryEncoded: String {
        addingPercentEncoding(withAllowedCharacters: String.urlUnreserved) ?? self
    }

    private static let urlUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
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
    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FalconMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("falconmail.log")
    }()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func info(_ area: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "\(stamp.string(from: Date())) [\(area)] \(message())\n"
        print(line, terminator: "")
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: fileURL)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }
}
