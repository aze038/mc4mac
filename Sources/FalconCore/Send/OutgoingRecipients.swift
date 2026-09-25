import Foundation

/// The To, Cc and Bcc boxes of a message being written, read as they are sent. Each box holds
/// addresses a comma or semicolon apart, as typed, pasted, completed from the suggestion list or
/// filled in by Reply All, and the message goes to every one of them: To and Cc are written into
/// its headers, Bcc only into the envelope (see MIMEBuilder and SMTPClient.send).
public struct OutgoingRecipients: Sendable, Hashable {
    public enum Field: String, Sendable, Hashable { case to = "To", cc = "Cc", bcc = "Bcc" }

    /// Where Outlook's "automatically Cc or Bcc myself" puts the owner.
    public enum CopyMode: String, Sendable { case cc, bcc }

    /// An entry of a box that is not an email address, as a name typed and never completed.
    public struct Unreadable: Sendable, Hashable {
        public var field: Field
        public var text: String

        public var sentence: String {
            "“\(text)” in the \(field.rawValue) box is not an email address. Correct it, or remove it, then send the message again."
        }
    }

    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]

    public init(to: [EmailAddress] = [], cc: [EmailAddress] = [], bcc: [EmailAddress] = []) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
    }

    /// The boxes as typed.
    public init(to: String, cc: String, bcc: String) {
        self.init(to: OutgoingRecipients.addresses(in: to), cc: OutgoingRecipients.addresses(in: cc),
                  bcc: OutgoingRecipients.addresses(in: bcc))
    }

    public var isEmpty: Bool { to.isEmpty && cc.isEmpty && bcc.isEmpty }

    /// The first entry, To first, then Cc, then Bcc, that is not an email address.
    public var unreadable: Unreadable? {
        for (field, list) in [(Field.to, to), (.cc, cc), (.bcc, bcc)] {
            if let bad = list.first(where: { !OutgoingRecipients.isAddress($0.address) }) {
                return Unreadable(field: field, text: bad.name.isEmpty ? bad.address : bad.rfc5322)
            }
        }
        return nil
    }

    /// Throws what the compose window says when the message cannot go as it is: nobody to send
    /// it to, or an entry that is no address. Found here rather than by the mail server, which
    /// would refuse the whole message, to every recipient, once it had left the compose window.
    public func checkSendable() throws {
        guard !isEmpty else { throw FalconError.invalidInput("Add at least one recipient.") }
        if let bad = unreadable { throw FalconError.invalidInput(bad.sentence) }
    }

    /// Adds the owner in Cc or Bcc, as "automatically Cc or Bcc myself" asks, unless a box names
    /// the owner already.
    public mutating func copy(_ me: EmailAddress, as mode: CopyMode) {
        let named = (to + cc + bcc).contains { $0.address.caseInsensitiveCompare(me.address) == .orderedSame }
        guard !named else { return }
        switch mode {
        case .cc: cc.append(me)
        case .bcc: bcc.append(me)
        }
    }

    /// The addresses in a box. Commas and semicolons divide them, outside a quoted name and angle
    /// brackets; so does a line break or a tab, as a list pasted from a spreadsheet or a column
    /// of addresses has them, and so does a space between bare addresses. A trailing separator,
    /// as the suggestion list leaves after the address it puts in, adds nothing.
    public static func addresses(in box: String) -> [EmailAddress] {
        let separated = String(box.map { $0.isNewline || $0 == "\t" ? "," : $0 })
        return AddressParser.parse(separated).flatMap(splitAtSpaces)
    }

    /// A box's text for `list`, as Reply All fills Cc, and a draft opened again its boxes.
    public static func box(_ list: [EmailAddress]) -> String {
        list.map(\.rfc5322).joined(separator: ", ")
    }

    /// Whether `address` can be named in a RCPT TO: a local part, one at sign and a domain,
    /// without spaces or brackets.
    public static func isAddress(_ address: String) -> Bool {
        guard SMTPClient.isSafeInCommand(address), !address.contains(where: { ",;\"()[]\\".contains($0) }) else { return false }
        let halves = address.split(separator: "@", omittingEmptySubsequences: false)
        return halves.count == 2 && !halves[0].isEmpty && !halves[1].isEmpty
    }

    /// "ana@example.com bob@example.com" is two addresses; "Ana Lee ana@example.com" is Ana Lee's.
    private static func splitAtSpaces(_ entry: EmailAddress) -> [EmailAddress] {
        guard entry.name.isEmpty, entry.address.contains(where: \.isWhitespace) else { return [entry] }
        let words = entry.address.split(whereSeparator: \.isWhitespace).map(String.init)
        let addresses = words.filter { $0.contains("@") }
        if addresses.count == words.count { return addresses.map { EmailAddress(address: $0) } }
        if addresses.count == 1, words.last == addresses[0] {
            return [EmailAddress(name: words.dropLast().joined(separator: " "), address: addresses[0])]
        }
        return [entry]
    }
}
