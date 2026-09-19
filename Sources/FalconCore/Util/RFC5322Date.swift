import Foundation

public enum RFC5322Date {
    private static let formats = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm Z",
        "EEE, d MMM yy HH:mm:ss Z",
        "EEE d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss",
        "d MMM yyyy HH:mm:ss"
    ]

    private static let formatters: [DateFormatter] = formats.map { fmt in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = fmt
        return f
    }

    private static let zoneNames: [String: String] = [
        "UT": "+0000", "GMT": "+0000", "UTC": "+0000", "Z": "+0000",
        "EST": "-0500", "EDT": "-0400", "CST": "-0600", "CDT": "-0500",
        "MST": "-0700", "MDT": "-0600", "PST": "-0800", "PDT": "-0700",
        "CET": "+0100", "CEST": "+0200", "EET": "+0200", "EEST": "+0300", "BST": "+0100"
    ]

    public static func parse(_ raw: String) -> Date? {
        var s = raw
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        s = s.trimmed
        s = s.replacingOccurrences(of: "  ", with: " ")
        let words = s.split(separator: " ").map(String.init)
        if let last = words.last, let mapped = zoneNames[last.uppercased()] {
            s = (words.dropLast() + [mapped]).joined(separator: " ")
        }
        for f in formatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    public static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }
}
