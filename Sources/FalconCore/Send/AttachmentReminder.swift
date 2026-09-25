import Foundation

public enum AttachmentReminder {
    public static let separatorLine = String(repeating: "_", count: 40)

    public static func keywords(from list: String) -> [String] {
        var seen = Set<String>()
        return list
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func userText(body: String, historyPlain: String) -> String {
        withoutSignature(withoutQuotedHistory(body: body, historyPlain: historyPlain))
    }

    public static func mentionsAttachment(subject: String, body: String, historyPlain: String, keywords: [String]) -> Bool {
        guard let pattern = alternation(for: keywords) else { return false }
        let haystack = (subject + "\n" + userText(body: body, historyPlain: historyPlain)).lowercased()
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    private static func withoutQuotedHistory(body: String, historyPlain: String) -> String {
        if !historyPlain.isEmpty, body.hasSuffix(historyPlain) {
            return String(body.dropLast(historyPlain.count))
        }
        let lines = body.components(separatedBy: "\n")
        let cut = lines.indices.first { index in
            startsQuotedHistory(lines[index]) || (index + 1 < lines.count && startsOutlookHeading(lines[index], lines[index + 1]))
        }
        guard let cut else { return body }
        return lines[..<cut].joined(separator: "\n")
    }

    /// Outlook's heading above a quoted original, which has no line of its own: From: followed
    /// by Date: as Outlook for Mac writes it, or by Sent: as Outlook for Windows does.
    private static func startsOutlookHeading(_ line: String, _ next: String) -> Bool {
        let next = next.trimmingCharacters(in: .whitespaces)
        return line.trimmingCharacters(in: .whitespaces).hasPrefix("From:") && (next.hasPrefix("Date:") || next.hasPrefix("Sent:"))
    }

    private static func startsQuotedHistory(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == separatorLine { return true }
        if trimmed.hasPrefix(">") { return true }
        return isReplyAttribution(trimmed)
    }

    private static func isReplyAttribution(_ line: String) -> Bool {
        guard line.hasSuffix(":"), line.count <= 400 else { return false }
        return line.range(of: attributionVerbs, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let attributionVerbs =
        "\\b(wrote|schrieb|schrieben|a écrit|escribió|написал|написала|yazdı|yazıb|yazmış|yazdılar)\\b"

    private static let signatureDelimiter = "--"

    private static func withoutSignature(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let cut = lines.lastIndex(where: isSignatureDelimiter) else { return text }
        return lines[..<cut].joined(separator: "\n")
    }

    private static func isSignatureDelimiter(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == signatureDelimiter
    }

    private static func alternation(for keywords: [String]) -> String? {
        let branches = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .map(bounded)
            .filter { !$0.isEmpty }
        guard !branches.isEmpty else { return nil }
        return branches.joined(separator: "|")
    }

    private static func bounded(_ keyword: String) -> String {
        let tokens = keyword
            .split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !tokens.isEmpty else { return "" }
        let leading = isWordCharacter(keyword.first) ? "\\b" : ""
        let trailing = isWordCharacter(keyword.last) ? "\\b" : ""
        return leading + tokens.joined(separator: "\\s+") + trailing
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}
