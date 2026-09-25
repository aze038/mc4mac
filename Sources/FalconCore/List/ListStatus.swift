import Foundation

// The words the list and the status bar show about the list itself: how many items a view
// holds, how far a listing has got, and the lines under the rows while some cannot fill.

/// A line under the list's rows.
public enum ListFooter: Hashable, Sendable {
    /// Rows are waiting for the account's Gmail budget, which refills in seconds.
    case loading(email: String)
    /// Offline, or paused by Gmail for more than a minute: only rows whose text is on this Mac
    /// are shown, and this many messages are not.
    case offline(hidden: Int)
    /// A sort by sender, recipient or subject: rows whose text is known are grouped at the top,
    /// and the rest, older than this, follow by date.
    case listedByDate(before: Date, sort: ListSortKey)

    public var text: String { ListStatusText.footer(self) }
}

/// A listing the status bar reports while it runs, in FalconMail's existing words.
public struct ListSyncProgress: Hashable, Sendable {
    public var email: String
    public var listed: Int
    public var total: Int

    public init(email: String, listed: Int, total: Int) {
        self.email = email
        self.listed = listed
        self.total = total
    }

    public var text: String { ListStatusText.progress(self) }
}

public enum ListStatusText {
    /// The group a text sort's rows without known text fall into.
    public static let olderByDate = "Older messages, by date"
    public static let upToDate = "All folders are up to date."
    /// The rule for a command given more than 1,000 selected rows that cannot act on a whole view.
    public static let tooManySelected = "Select 1,000 messages or fewer for this command."

    /// Numbers as the status bar writes them, with the Mac's grouping, such as 200,000.
    public static func number(_ value: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// The status bar's Items: every message of the view, as Outlook counts them, never the rows
    /// loaded so far.
    public static func items(_ count: Int, locale: Locale = .current) -> String {
        "Items: " + number(count, locale: locale)
    }

    public static func progress(_ progress: ListSyncProgress, locale: Locale = .current) -> String {
        "Syncing \(progress.email): \(number(progress.listed, locale: locale)) of \(number(progress.total, locale: locale)) messages"
    }

    /// "All folders are up to date." only once every folder the sidebar shows has been listed in
    /// full and every account can be reached; before that it would not be true.
    public static func state(everyFolderListed: Bool, everyAccountReachable: Bool, progress: ListSyncProgress?) -> String? {
        if let progress { return progress.text }
        return everyFolderListed && everyAccountReachable ? upToDate : nil
    }

    public static func footer(_ footer: ListFooter, locale: Locale = .current) -> String {
        switch footer {
        case .loading(let email):
            return "Loading more of \(email)'s messages…"
        case .offline(let hidden):
            let count = number(hidden, locale: locale)
            return hidden == 1 ? "1 older message is on Gmail. It'll show when you're back online."
                : "\(count) older messages are on Gmail. They'll show when you're back online."
        case .listedByDate(let before, let sort):
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            let who: String
            switch sort {
            case .to: who = "Search to find mail to someone."
            case .subject: who = "Search to find mail by its subject."
            default: who = "Search to find mail from a sender."
            }
            return "Messages from before \(formatter.string(from: before)) are listed by date. \(who)"
        }
    }
}
