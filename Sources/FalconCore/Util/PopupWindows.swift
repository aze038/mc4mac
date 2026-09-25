import Foundation

/// What a window of its own holds: a message being read, or one being written.
public enum PopupKey: Hashable, Codable, Sendable {
    case message(String)
    case compose(UUID)
}

/// Where opening a message puts it. Legacy Outlook opens a double-clicked message in a window of
/// its own, and so does FalconMail unless the owner chose tabs in Settings → Reading.
public enum MessageOpening {
    public enum Destination: Equatable, Sendable {
        /// A draft in the Drafts folder opens to be written, never to be read.
        case editDraft
        case window
        case tab
    }

    /// Whether a message opens in a window when the owner has never chosen.
    public static let opensInWindowByDefault = true

    /// The setting's key in the app's defaults: the one earlier builds kept, unset there unless
    /// changed by hand, so the same choice means the same in either build.
    public static let preferenceKey = "openInWindowOnDoubleClick"

    /// The owner's choice from what the defaults hold under `preferenceKey`, nil when unset.
    public static func opensInWindow(stored: Bool?) -> Bool {
        stored ?? opensInWindowByDefault
    }

    /// Where a message opens: by double-click, Return or Open (`forceWindow` false), which follow
    /// the setting, or by Open in Separate Window (`forceWindow` true).
    public static func destination(inDraftsFolder: Bool, opensInWindow: Bool, forceWindow: Bool) -> Destination {
        if inDraftsFolder { return .editDraft }
        return forceWindow || opensInWindow ? .window : .tab
    }
}

/// What the Message menu's commands, and their shortcuts, act on. They follow the window in
/// front, as Outlook's do: in a message window, its message alone, whatever the mailbox window
/// has selected; while a message is being written, nothing, so that Command-Delete deletes text
/// there rather than mail; otherwise the mailbox window's selection.
public enum MenuTarget: Equatable, Sendable {
    case selection
    case messageWindow(String)
    case nothing

    /// `front` is the message or compose window in front, nil for any other; `writingInMailbox`
    /// says the mailbox window in front shows a message being written in a tab.
    public static func of(front: PopupKey?, writingInMailbox: Bool) -> MenuTarget {
        switch front {
        case .message(let id)?: return .messageWindow(id)
        case .compose?: return .nothing
        case nil: return writingInMailbox ? .nothing : .selection
        }
    }
}

/// The message and compose windows that are open, each either on screen or minimised into the
/// tray along the foot of the mailbox window, where FalconMail keeps them instead of the Dock.
public struct WindowTrayBook: Equatable, Sendable {
    public enum Place: Equatable, Sendable {
        case showing
        case tray
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let key: PopupKey
        public var title: String
        public var place: Place
        public var id: PopupKey { key }
    }

    /// Every window, in the order each was opened or last minimised.
    public private(set) var entries: [Entry] = []

    public init() {}

    /// What asking for a window for `key` does.
    public enum Opening: Equatable, Sendable {
        /// No window holds it: open one.
        case open
        /// Its window is on screen: bring it to the front rather than open a second one.
        case bringForward
        /// Its window waits in the tray: take it out and show it.
        case restoreFromTray
    }

    public func opening(_ key: PopupKey) -> Opening {
        switch entry(key)?.place {
        case nil: return .open
        case .showing: return .bringForward
        case .tray: return .restoreFromTray
        }
    }

    public func entry(_ key: PopupKey) -> Entry? {
        entries.first { $0.key == key }
    }

    /// The windows in the tray, left to right: the one minimised first comes first.
    public var tray: [Entry] {
        entries.filter { $0.place == .tray }
    }

    /// A window for `key` is on screen, newly opened or brought back.
    public mutating func showing(_ key: PopupKey, title: String) {
        if let i = index(key) {
            entries[i].place = .showing
            if !title.isEmpty { entries[i].title = title }
        } else {
            entries.append(Entry(key: key, title: title, place: .showing))
        }
    }

    /// `key`'s window goes into the tray, at its end. An empty `title` keeps the one it had.
    public mutating func minimise(_ key: PopupKey, title: String) {
        let earlier = index(key).map { entries.remove(at: $0) }
        entries.append(Entry(key: key, title: title.isEmpty ? earlier?.title ?? "" : title, place: .tray))
    }

    /// Takes `key` out of the tray. False when it was not in the tray.
    @discardableResult
    public mutating func restore(_ key: PopupKey) -> Bool {
        guard let i = index(key), entries[i].place == .tray else { return false }
        entries[i].place = .showing
        return true
    }

    /// `key`'s window closed, from the screen or from the tray.
    public mutating func closed(_ key: PopupKey) {
        entries.removeAll { $0.key == key }
    }

    private func index(_ key: PopupKey) -> Int? {
        entries.firstIndex { $0.key == key }
    }

    // MARK: Sessions

    /// The message windows to bring back at the next launch: every one open, on screen or in the
    /// tray, and which of those were in the tray. Messages being written are not among them;
    /// what they held goes to Drafts instead.
    public var messageWindows: (all: [String], inTray: [String]) {
        var all: [String] = []
        var inTray: [String] = []
        for entry in entries {
            guard case .message(let id) = entry.key else { continue }
            all.append(id)
            if entry.place == .tray { inTray.append(id) }
        }
        return (all, inTray)
    }

    /// What a launch does with the message windows the last session left: which open on screen
    /// and which go straight back into the tray without showing. A session saved by a build
    /// that did not remember the tray has none there, and each window it lists opens.
    public static func restoring(messageWindows all: [String], inTray: [String]?) -> (open: [String], tray: [String]) {
        let trayed = Set(inTray ?? [])
        var seen = Set<String>()
        var open: [String] = []
        var tray: [String] = []
        for id in all where seen.insert(id).inserted {
            if trayed.contains(id) { tray.append(id) } else { open.append(id) }
        }
        return (open, tray)
    }
}
