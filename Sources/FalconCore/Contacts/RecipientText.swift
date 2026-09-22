import Foundation

/// The text of a To, Cc or Bcc field while it is typed: addresses separated by commas or
/// semicolons, the last one perhaps half written. A separator inside a quoted name or inside
/// angle brackets does not count, the same rule `AddressParser` reads the field by.
public enum RecipientText {
    /// The fragment being typed, everything after the last separator, trimmed.
    public static func lastFragment(of text: String) -> String {
        String(text[fragmentStart(in: text)...]).trimmed
    }

    /// `text` with its last fragment replaced by `address` and a separator, ready for the next
    /// recipient. Everything before the fragment is kept exactly as it was typed.
    public static func completing(_ text: String, with address: EmailAddress) -> String {
        let kept = text[..<fragmentStart(in: text)]
        return kept + (kept.isEmpty ? "" : " ") + address.rfc5322 + ", "
    }

    private static func fragmentStart(in text: String) -> String.Index {
        var start = text.startIndex
        var inQuotes = false
        var depth = 0
        var prev: Character = " "
        for i in text.indices {
            let ch = text[i]
            if ch == "\"" && prev != "\\" { inQuotes.toggle() }
            if !inQuotes {
                if ch == "<" { depth += 1 } else if ch == ">" { depth = max(0, depth - 1) }
                if (ch == "," || ch == ";") && depth == 0 { start = text.index(after: i) }
            }
            prev = ch
        }
        return start
    }
}
