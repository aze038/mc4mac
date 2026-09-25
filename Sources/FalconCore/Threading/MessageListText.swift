import Foundation

/// The words a row of the message list shows, worked out as Legacy Outlook works them out. They
/// live apart from the view so that a row only draws, and so that tests can hold them to
/// Outlook's.
public enum MessageListText {
    /// Everyone who wrote in a conversation, newest first and each once, joined with commas:
    /// Outlook's first line of a conversation, such as "Maya Lindqvist, Tom Okafor". A sender is
    /// the same person whatever case their address is written in; one without an address is
    /// known by their name.
    public static func participants(_ messages: [MessageSummary]) -> String {
        // Newest first however the caller ordered them; stable, so that two messages sent in the
        // same second keep the order they came in.
        let newestFirst = messages.enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date > $1.element.date : $0.offset < $1.offset }
            .map(\.element)
        var seen = Set<String>()
        var names: [String] = []
        for message in newestFirst {
            let address = message.from.address.trimmingCharacters(in: .whitespaces).lowercased()
            let name = message.from.displayName.trimmingCharacters(in: .whitespaces)
            let key = address.isEmpty ? "name:" + name.lowercased() : address
            guard !name.isEmpty, seen.insert(key).inserted else { continue }
            names.append(name)
        }
        return names.joined(separator: ", ")
    }

    /// A message's date as Outlook's list gives it: the time for today, "Yesterday", and the
    /// date in the Mac's own short style for anything older, or for a date after today, which
    /// only a wrong clock gives.
    public static func date(_ date: Date, now: Date = Date(), formats: DateFormats = .current) -> String {
        let calendar = formats.calendar
        if calendar.isDate(date, inSameDayAs: now) { return formats.time.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return formats.day.string(from: date)
    }

    /// A message's opening words on one line: every run of spaces, tabs and line breaks becomes
    /// one space, so that a line break cannot end the preview early.
    public static func preview(_ snippet: String) -> String {
        guard snippet.contains(where: { $0.isWhitespace && $0 != " " }) || snippet.contains("  ")
                || snippet.first == " " || snippet.last == " " else { return snippet }
        return snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The formatters the list's dates are written with. Making a formatter is slow, so the list
    /// shares one set; tests make their own for a fixed locale.
    public final class DateFormats: @unchecked Sendable {
        public let calendar: Calendar
        let time: DateFormatter
        let day: DateFormatter

        /// The Mac's region settings, as Outlook uses them: its 24 or 12 hour clock and its short
        /// date, such as 23.09.2026, or whatever the owner set in Language & Region. The
        /// formatters are left on their defaults, which follow those settings as they change.
        public static let current = DateFormats(calendar: .autoupdatingCurrent, time: DateFormatter(), day: DateFormatter())

        public convenience init(locale: Locale, timeZone: TimeZone) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            calendar.timeZone = timeZone
            let time = DateFormatter()
            let day = DateFormatter()
            for formatter in [time, day] {
                formatter.locale = locale
                formatter.calendar = calendar
                formatter.timeZone = timeZone
            }
            self.init(calendar: calendar, time: time, day: day)
        }

        private init(calendar: Calendar, time: DateFormatter, day: DateFormatter) {
            self.calendar = calendar
            self.time = time
            self.day = day
            time.dateStyle = .none
            time.timeStyle = .short
            day.dateStyle = .short
            day.timeStyle = .none
        }
    }
}
