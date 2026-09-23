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

    /// The contacts `fragment` may stand for, best first: the one whose address it already is,
    /// then those whose address, name or a word of the name starts with it, then those that
    /// merely contain it, the most used first within each. One row per address.
    public static func suggestions(from contacts: [ContactInfo], for fragment: String) -> [ContactInfo] {
        let query = fragment.trimmed.lowercased()
        guard !query.isEmpty else { return [] }
        let typed = completeAddress(in: fragment)?.lowercased() ?? query
        func tier(_ contact: ContactInfo) -> Int? {
            let email = contact.email.lowercased()
            let name = contact.name.lowercased()
            if email == typed { return 0 }
            if email.hasPrefix(query) || name.hasPrefix(query)
                || name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(query) }) { return 1 }
            if email.contains(query) || name.contains(query) { return 2 }
            return nil
        }
        var seen = Set<String>()
        return contacts.compactMap { contact in tier(contact).map { (contact, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return (a.0.useCount, a.0.lastUsed ?? .distantPast) > (b.0.useCount, b.0.lastUsed ?? .distantPast)
            }
            .map(\.0)
            .filter { seen.insert($0.email.lowercased()).inserted }
    }

    /// The address `fragment` already spells out in full, bare or in angle brackets after a name;
    /// nil while it is still being typed. Whole means a local part, one at sign and a dotted
    /// domain whose last label has at least two characters, as every top-level domain has.
    public static func completeAddress(in fragment: String) -> String? {
        guard let address = AddressParser.parseOne(fragment.trimmed)?.address,
              !address.contains(where: { $0.isWhitespace || "<>()[],;:\"\\".contains($0) }) else { return nil }
        let halves = address.split(separator: "@", omittingEmptySubsequences: false)
        guard halves.count == 2, !halves[0].isEmpty else { return nil }
        let labels = halves[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let last = labels.last, last.count >= 2 else { return nil }
        return address
    }

    /// Whether completing `fragment` from the keyboard may put `address` in its place. A fragment
    /// that is already a whole address only ever completes to that same address, so a typed or
    /// pasted dan@acme.com is never swapped for jordan@acme.com, which merely contains it.
    public static func mayComplete(_ fragment: String, with address: String) -> Bool {
        guard let typed = completeAddress(in: fragment) else { return true }
        return typed.caseInsensitiveCompare(address.trimmed) == .orderedSame
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
