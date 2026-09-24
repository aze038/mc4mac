import Foundation

extension AccountInfo {
    /// The addresses that are this account's own, lower-cased: its email, and the sign-in name
    /// when that is an address of its own. Send-as aliases belong here too once they are known.
    public var ownAddresses: Set<String> {
        var out: Set<String> = [email.lowercased()]
        if let username, username.contains("@") { out.insert(username.lowercased()) }
        return out
    }
}

/// Who a reply is addressed to. A reply to a message the owner sent goes back to the people it
/// was sent to, as it does in Outlook and Gmail, rather than to the owner.
public enum ReplyAddressing {
    /// `replyTo` is the original's Reply-To, empty when it had none. `own` holds the account's
    /// own addresses, lower-cased.
    public static func recipients(for message: MessageSummary, replyTo: [EmailAddress], own: Set<String>,
                                  all: Bool) -> (to: [EmailAddress], cc: [EmailAddress]) {
        func isOwn(_ a: EmailAddress) -> Bool { own.contains(a.address.lowercased()) }
        let senders = replyTo.filter { !$0.address.isEmpty }
        let targets = senders.isEmpty ? [message.from] : senders

        var to: [EmailAddress]
        var cc: [EmailAddress] = []
        if targets.allSatisfy(isOwn) {
            to = unique(message.to.filter { !isOwn($0) })
            if all { cc = message.cc.filter { !isOwn($0) } }
            // Nobody left means it was a note to self, and so is the reply.
            if to.isEmpty { to = targets }
        } else {
            to = unique(targets)
            if all { cc = (message.to + message.cc).filter { !isOwn($0) } }
        }
        let taken = Set(to.map { $0.address.lowercased() })
        cc = unique(cc).filter { !taken.contains($0.address.lowercased()) }
        return (to, cc)
    }

    private static func unique(_ list: [EmailAddress]) -> [EmailAddress] {
        var seen = Set<String>()
        return list.filter { !$0.address.isEmpty && seen.insert($0.address.lowercased()).inserted }
    }
}
