import Foundation

public enum ConversationThreader {
    public static func normalizedSubject(_ subject: String) -> String {
        var s = subject.trimmed
        let pattern = "^((re|fw|fwd|aw|wg|sv|vs|tr|rv|antw|odp)\\s*(\\[\\d+\\])?\\s*:\\s*)+"
        while let r = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
            s = s.trimmed
        }
        return s.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    public static func threadKey(messageID: String, inReplyTo: String, references: [String], subject: String,
                                 lookup: (String) -> String?) -> String {
        for ref in (references + [inReplyTo]).reversed() where !ref.isEmpty {
            if let key = lookup(ref) { return key }
        }
        if let root = references.first, !root.isEmpty { return root }
        if !inReplyTo.isEmpty { return inReplyTo }
        if !messageID.isEmpty { return messageID }
        return "subject:" + normalizedSubject(subject)
    }

    public static func group(_ messages: [MessageSummary]) -> [[MessageSummary]] {
        var byKey: [String: [MessageSummary]] = [:]
        var order: [String] = []
        for m in messages.sorted(by: { $0.date > $1.date }) {
            let key = m.threadKey.isEmpty ? m.id : m.threadKey
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(m)
        }
        return order.map { byKey[$0]! }
    }
}
