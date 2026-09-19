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
        var d = Data(count: count)
        d.withUnsafeMutableBytes { buf in
            for i in 0..<count { buf[i] = UInt8.random(in: 0...255) }
        }
        return d
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
    public static func info(_ area: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print("[FalconMail][\(area)] \(message())")
    }
}
