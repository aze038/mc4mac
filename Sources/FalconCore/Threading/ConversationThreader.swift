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

    /// Groups messages into conversations, newest first.
    /// The input must already be in date-descending order; sorting it again here doubled the cost
    /// of every list reload.
    public static func group(_ messages: [MessageSummary]) -> [[MessageSummary]] {
        var byKey: [String: Int] = [:]
        byKey.reserveCapacity(messages.count)
        var buckets: [[MessageSummary]] = []
        buckets.reserveCapacity(messages.count)
        for m in messages {
            let key = m.threadKey.isEmpty ? m.id : m.threadKey
            if let slot = byKey[key] {
                buckets[slot].append(m)
            } else {
                byKey[key] = buckets.count
                buckets.append([m])
            }
        }
        return buckets
    }

    /// For callers that cannot guarantee ordering.
    public static func groupUnordered(_ messages: [MessageSummary]) -> [[MessageSummary]] {
        group(messages.sorted { $0.date > $1.date })
    }
}
