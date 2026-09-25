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
        switch attribution {
        case .none:
            return ""
        case .custom(let pattern):
            return "<div style=\"\(font.css);color:black\">" + "<p style=\"margin:0\">\(HTMLText.escape(custom(pattern, original)))</p><p style=\"margin:0\">&nbsp;</p></div>"
        case .outlook:
            return outlookHTML(lines(original), font: font)
        }
    }

    /// Outlook's heading as HTML from its lines as the composer shows them, from `From:` to the
    /// end of the `Subject:` line (see `headingLines(of:)`): the same as `html` gives for them.
    public static func html(headingLines: String, font: ComposeFont) -> String {
        let lines = headingLines.components(separatedBy: "\n").map { line -> (label: String, value: String) in
            for label in ["From:", "Date:", "To:", "Cc:", "Subject:"] where line.hasPrefix(label) {
                return (label, String(line.dropFirst(label.count).drop { $0 == " " }))
            }
            return ("", line)
        }
        return outlookHTML(lines, font: font)
    }

    /// The heading's block: a div whose top border runs the whole width of the message, as
    /// Outlook's does, holding one paragraph of bold labels and values, then an empty paragraph.
    private static func outlookHTML(_ lines: [(label: String, value: String)], font: ComposeFont) -> String {
        let body = lines.map { ($0.label.isEmpty ? "" : "<b>\($0.label) </b>") + HTMLText.escape($0.value) }.joined(separator: "<br>")
        return "<div style=\"\(font.css);color:black\"><div style=\"border:none;border-top:solid #B5C4DF 1.0pt;padding:3.0pt 0in 0in 0in\">"
            + "<p style=\"margin:0\">\(body)</p></div><p style=\"margin:0\">&nbsp;</p></div>"
    }

    /// The line Outlook's plain text puts above a quoted original's heading.
    public static let plainLine = String(repeating: "_", count: 32)

    /// The heading's lines as a history begins with them, from `From:` to the end of the
    /// `Subject:` line; nil when it begins with no heading of Outlook's.
    public static func headingLines(of history: String) -> String? {
        guard history.hasPrefix("\nFrom: ") else { return nil }
        let rest = history.dropFirst()
        guard let end = rest.range(of: "\n\n") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    /// Where the heading's `From:` stands in `text`, in UTF-16 units: in the history `text` still
    /// ends with, else wherever the heading's lines still stand whole on lines of their own, as
    /// they do once the original below them has been edited. Nil when `history` has no heading
    /// of Outlook's or `text` no longer holds it.
    public static func headingStart(in text: String, history: String) -> Int? {
        guard let lines = headingLines(of: history) else { return nil }
        if let start = ComposedBody.historyStart(in: text, history: history) { return start + 1 }
        let s = text as NSString
        if s.hasPrefix(lines + "\n") || s.isEqual(to: lines) { return 0 }
        let found = s.range(of: "\n" + lines + "\n")
        if found.location != NSNotFound { return found.location + 1 }
        return s.hasSuffix("\n" + lines) ? s.length - (lines as NSString).length : nil
    }

    /// The labels that begin a heading an earlier reply in a chain put above its original, as
    /// Outlook, Outlook on the web and FalconMail write them in the languages a chain is most
    /// often written in: `From:` and the like, then on the next line `Sent:`, `Date:` and the like.
    static let fromLabels = ["From:", "Van:", "Von:", "De:", "De :", "Da:", "Od:", "От:", "Kimden:", "Kimdən:", "Från:", "Fra:"]
    static let dateLabels = ["Sent:", "Date:", "Verzonden:", "Datum:", "Gesendet:", "Envoyé :", "Envoyé:", "Date :", "Enviado:",
                             "Enviado el:", "Fecha:", "Inviato:", "Data:", "Wysłano:", "Отправлено:", "Дата:", "Gönderildi:", "Tarih:",
                             "Göndərildi:", "Tarix:", "Skickat:", "Sendt:"]

    /// Where each heading in `text` from `location` on begins, in UTF-16 units: each paragraph
    /// whose first line starts with a From label and whose next line starts with a Sent or Date
    /// label, as Outlook's headings do, which it sets under a line across the message. A
    /// heading that a line of underscores or Outlook's -----Original Message----- already stands
    /// above in the text is left out, as is one that does not begin its paragraph, such as
    /// Gmail's under its Forwarded message line, which has no line of its own.
    public static func headingStarts(in text: NSString, from location: Int) -> [Int] {
        var starts: [Int] = []
        var index = max(0, location)
        var previous = ""
        var pendingFrom: Int?
        while index < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: index, length: 0))
            guard paragraph.length > 0 else { break }
            let content = text.substring(with: paragraph).trimmingCharacters(in: .newlines)
            let lines = content.components(separatedBy: "\u{2028}")
            let first = lines[0].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{00A0}")))
            if let from = pendingFrom, dateLabels.contains(where: { first.hasPrefix($0) }) { starts.append(from) }
            pendingFrom = nil
            if fromLabels.contains(where: { first.hasPrefix($0) }), !isSeparator(previous) {
                if lines.count > 1 {
                    let next = lines[1].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{00A0}")))
                    if dateLabels.contains(where: { next.hasPrefix($0) }) { starts.append(paragraph.location) }
                } else {
                    pendingFrom = paragraph.location
                }
            }
            if !first.isEmpty { previous = lines.last ?? first }
            index = NSMaxRange(paragraph)
        }
        return starts
    }

    /// A line of underscores or dashes, or Outlook's -----Original Message-----, that already
    /// sets a heading off from what is above it.
    private static func isSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{00A0}")))
        guard trimmed.count >= 5 else { return false }
        return trimmed.allSatisfy { $0 == "_" || $0 == "-" } || (trimmed.hasPrefix("-----") && trimmed.hasSuffix("-----"))
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
