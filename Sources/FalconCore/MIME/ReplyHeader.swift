import Foundation

/// The heading a reply or forward puts above the original, as Legacy Outlook for Mac writes it.
///
/// Outlook for Mac sets it in the message's own font, in black, under a one point line in
/// #B5C4DF with three points above the text, the labels in bold, each on a line of its own:
///
///     From: Sam Sender <sam@example.com>
///     Date: Wednesday, 23 September 2026 at 14:21
///     To: Alex Example <alex@example.com>, Jo <jo@example.com>
///     Cc: 'Team' <team@example.com>
///     Subject: Re: Figures
///
/// then an empty line and the original. A name is written as it came, followed by the address
/// in angle brackets; a sender without a name is the address in brackets alone. People are
/// separated by commas, and Cc, To and Date are left out when there is nothing to say. The
/// date is always English, whatever language and region the Mac is set to, since FalconMail
/// itself is English and a business chain is read by people in many countries: day, date,
/// month, year and a 24-hour time, in the Mac's own time zone.
public enum ReplyHeader {
    /// How the original is introduced, as Settings chooses.
    public enum Attribution: Equatable, Sendable {
        /// Outlook's From, Date, To, Cc and Subject.
        case outlook
        /// One line from a pattern holding [DATE], [NAME] and [ADDRESS].
        case custom(String)
        /// Nothing: the original follows the new text directly.
        case none
    }

    /// What the heading says about the original.
    public struct Original: Equatable, Sendable {
        public var from: EmailAddress
        public var date: Date
        public var to: [EmailAddress]
        public var cc: [EmailAddress]
        public var subject: String

        public init(from: EmailAddress, date: Date, to: [EmailAddress], cc: [EmailAddress], subject: String) {
            self.from = from
            self.date = date
            self.to = to
            self.cc = cc
            self.subject = subject
        }
    }

    /// The labels, as the composer shows them in bold.
    public static let labels = ["From:", "Date:", "Sent:", "To:", "Cc:", "Subject:"]

    /// The heading's lines, label and value.
    public static func lines(_ original: Original) -> [(label: String, value: String)] {
        var lines = [("From:", person(original.from)), ("Date:", date(original.date))]
        if !original.to.isEmpty { lines.append(("To:", people(original.to))) }
        if !original.cc.isEmpty { lines.append(("Cc:", people(original.cc))) }
        lines.append(("Subject:", original.subject))
        return lines
    }

    /// The heading as text, as the composer shows it and the plain text part sends it: an empty
    /// line, the heading, an empty line. Empty for `.none`.
    public static func plain(_ original: Original, attribution: Attribution) -> String {
        switch attribution {
        case .none: return ""
        case .custom(let pattern): return "\n" + custom(pattern, original) + "\n\n"
        case .outlook: return "\n" + lines(original).map { "\($0.label) \($0.value)" }.joined(separator: "\n") + "\n\n"
        }
    }

    /// The heading as HTML, in `font`, with the empty paragraph that follows it. Empty for
    /// `.none`.
    public static func html(_ original: Original, attribution: Attribution, font: ComposeFont) -> String {
        let open = "<div style=\"\(font.css);color:black\">"
        switch attribution {
        case .none:
            return ""
        case .custom(let pattern):
            return open + "<p style=\"margin:0\">\(HTMLText.escape(custom(pattern, original)))</p><p style=\"margin:0\">&nbsp;</p></div>"
        case .outlook:
            let body = lines(original).map { "<b>\($0.label) </b>\(HTMLText.escape($0.value))" }.joined(separator: "<br>")
            return open + "<div style=\"border:none;border-top:solid #B5C4DF 1.0pt;padding:3.0pt 0in 0in 0in\">"
                + "<p style=\"margin:0\">\(body)</p></div><p style=\"margin:0\">&nbsp;</p></div>"
        }
    }

    /// `Name <address>`, or `<address>` for someone without a name, as Outlook for Mac writes.
    public static func person(_ address: EmailAddress) -> String {
        let name = address.name.trimmed
        return name.isEmpty ? "<\(address.address)>" : "\(name) <\(address.address)>"
    }

    public static func people(_ list: [EmailAddress]) -> String {
        list.map(person).joined(separator: ", ")
    }

    /// `Wednesday, 23 September 2026 at 14:21`, in English and in `timeZone`.
    public static func date(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }

    /// Settings' own pattern filled in, the date written as in the heading.
    public static func custom(_ pattern: String, _ original: Original) -> String {
        pattern.replacingOccurrences(of: "[DATE]", with: date(original.date))
            .replacingOccurrences(of: "[NAME]", with: original.from.name.isEmpty ? original.from.address : original.from.name)
            .replacingOccurrences(of: "[ADDRESS]", with: original.from.address)
    }
}
