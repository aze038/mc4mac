import SwiftUI
import AppKit

enum Preferences {
    static func bool(_ key: String, default d: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? d }
    static func int(_ key: String, default d: Int) -> Int { UserDefaults.standard.object(forKey: key) as? Int ?? d }
    static func string(_ key: String, default d: String) -> String { UserDefaults.standard.string(forKey: key) ?? d }
    static func set(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}

enum Pref {
    static let theme = "themeColour"
    static let transparency = "windowTransparency"
    static let textSize = "textDisplaySize"
    static let showAllAccountFolders = "showAllAccountFolders"
    static let hideLocalFolders = "hideLocalFolders"
    static let allowFolderReordering = "allowFolderReordering"

    static let showPreview = "showMessagePreview"
    static let showSenderImage = "showSenderImage"
    static let showEventRSVP = "showEventRSVP"
    static let showGroupHeaders = "showGroupHeaders"
    static let focusedInbox = "focusedInbox"
    static let autoExpandConversation = "autoExpandConversation"
    static let showSentInConversations = "showSentInConversations"
    static let leftSwipe = "leftSwipeAction"
    static let rightSwipe = "rightSwipeAction"
    static let openInOfficeApps = "openAttachmentsInOfficeApps"
    static let quickActions = "quickActions"

    static let indentOriginal = "indentOriginalMessage"
    static let attributionMode = "attributionMode"
    static let attributionFormat = "attributionFormat"
    static let replyUsesOriginalFormat = "replyUsesOriginalFormat"
    static let closeOriginalAfterReply = "closeOriginalAfterReply"
    static let autoCopySelf = "autoCopySelf"
    static let autoCopyMode = "autoCopyMode"
    static let showCcByDefault = "showCcByDefault"
    static let showBccByDefault = "showBccByDefault"
    static let replyToSelectedText = "replyToSelectedText"
    static let composeInWindow = "composeInSeparateWindow"
    static let composeHTML = "composeUsesHTML"
    static let checkSpelling = "checkSpellingWhileTyping"
    static let checkGrammar = "checkGrammarWithSpelling"
    static let correctAutomatically = "correctSpellingAutomatically"
    static let smartQuotes = "smartQuotesAndDashes"
    static let smartLinks = "smartLinks"

    static let workDayStart = "workDayStart"
    static let workDayEnd = "workDayEnd"
    static let workWeek = "workWeekDays"
    static let firstWeekday = "firstWeekday"
    static let defaultReminder = "defaultReminderOn"
    static let reminderMinutes = "defaultReminderMinutes"
    static let showWeekNumbers = "showWeekNumbers"
    static let proposeNewTime = "allowProposeNewTime"

    static let replaceAsYouType = "replaceTextAsYouType"
    static let fixTwoCapitals = "correctTwoInitialCapitals"
    static let capitaliseSentences = "capitaliseSentences"
    static let capitaliseDays = "capitaliseDays"
    static let replacements = "textReplacements"
    static let writingStyle = "writingStyle"

    static let ribbonTab = "ribbonTab"
    static let readingPane = "readingPanePosition"
    static let sidebarWidth = "sidebarWidth"
    static let listWidth = "listWidth"
    static let messagePreviewLines = "messagePreviewLines"
    static let offlineMode = "workOffline"
}

enum ListDensity: String, CaseIterable, Identifiable {
    case roomy, cozy, compact

    var id: String { rawValue }

    /// Earlier builds stored "comfortable"; it maps to the middle density.
    static func stored(_ raw: String) -> ListDensity {
        ListDensity(rawValue: raw) ?? (raw == "comfortable" ? .roomy : .cozy)
    }

    var title: LocalizedStringKey {
        switch self {
        case .roomy: return "Roomy"
        case .cozy: return "Cozy"
        case .compact: return "Compact"
        }
    }

    var previewLines: Int {
        switch self {
        case .roomy: return 2
        case .cozy: return 1
        case .compact: return 0
        }
    }

    var rowPadding: CGFloat {
        switch self {
        case .roomy: return 8
        case .cozy: return 5
        case .compact: return 3
        }
    }

    /// Whether a row has room for the preview line at all: Compact keeps only the sender, and
    /// the subject with the date.
    var hasPreviewLine: Bool { self != .compact }

    /// How much taller a conversation's row is than Outlook's own (Cozy); its drawing moves down
    /// by half of it, so the extra room is shared above and below.
    var extraHeight: CGFloat {
        switch self {
        case .roomy: return 12
        case .cozy: return 0
        case .compact: return -6
        }
    }

    var textShift: CGFloat { extraHeight / 2 }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static func apply(_ raw: String) {
        switch AppAppearance(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum AccentTheme: String, CaseIterable, Identifiable {
    case blue, purple, pink, orange, red, green

    var id: String { rawValue }

    var colour: Color {
        switch self {
        case .blue: return Color(red: 0.11, green: 0.42, blue: 0.79)
        case .purple: return Color(red: 0.64, green: 0.21, blue: 0.93)
        case .pink: return Color(red: 0.93, green: 0.22, blue: 0.56)
        case .orange: return Color(red: 0.95, green: 0.38, blue: 0.13)
        case .red: return Color(red: 0.89, green: 0.13, blue: 0.31)
        case .green: return Color(red: 0.18, green: 0.75, blue: 0.53)
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .blue: return "Blue (default)"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .orange: return "Orange"
        case .red: return "Red"
        case .green: return "Green"
        }
    }

    static func current() -> AccentTheme {
        AccentTheme(rawValue: Preferences.string(Pref.theme, default: AccentTheme.blue.rawValue)) ?? .blue
    }
}

enum SwipeAction: String, CaseIterable, Identifiable {
    case none, archive, delete, markRead, flag, move, junk

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .none: return "Nothing"
        case .archive: return "Archive"
        case .delete: return "Delete"
        case .markRead: return "Mark as Read or Unread"
        case .flag: return "Flag"
        case .move: return "Move"
        case .junk: return "Junk"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "minus"
        case .archive: return "archivebox"
        case .delete: return "trash"
        case .markRead: return "envelope.open"
        case .flag: return "flag"
        case .move: return "folder"
        case .junk: return "xmark.bin"
        }
    }
}

enum QuickAction: String, CaseIterable, Identifiable {
    case delete, archive, flag, move, markRead, snooze

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .delete: return "Delete"
        case .archive: return "Archive"
        case .flag: return "Flag"
        case .move: return "Move"
        case .markRead: return "Mark as Read or Unread"
        case .snooze: return "Snooze"
        }
    }

    var symbol: String {
        switch self {
        case .delete: return "trash"
        case .archive: return "archivebox"
        case .flag: return "flag"
        case .move: return "folder"
        case .markRead: return "envelope.open"
        case .snooze: return "clock"
        }
    }

    static let defaults = "delete,flag"

    static func enabled() -> [QuickAction] {
        Preferences.string(Pref.quickActions, default: defaults)
            .split(separator: ",").compactMap { QuickAction(rawValue: String($0)) }
    }
}

enum AttributionMode: String, CaseIterable, Identifiable {
    case none, standard, custom

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .none: return "None"
        case .standard: return "Include From, Date, To, and Subject lines from original message"
        case .custom: return "Customised attribution format"
        }
    }
}

enum ReadingPanePosition: String, CaseIterable, Identifiable {
    case right, below, off

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .right: return "Right"
        case .below: return "Below"
        case .off: return "Off"
        }
    }

    var symbol: String {
        switch self {
        case .right: return "rectangle.righthalf.inset.filled"
        case .below: return "rectangle.bottomhalf.inset.filled"
        case .off: return "rectangle"
        }
    }
}

enum SystemSounds {
    static let none = "None"

    static var names: [String] {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let names = files.filter { $0.pathExtension == "aiff" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
        return names.isEmpty ? ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"] : names
    }

    static func play(_ name: String) {
        guard name != none else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
