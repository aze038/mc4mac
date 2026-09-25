import Foundation

/// What is selected in the list: rows of the snapshot by their places, or every row of the view
/// except some, as after Select All. Select All over 200,000 rows costs a few bytes, and an
/// action on it is described by the view, never by a list of every id in it.
public struct ListSelection: Hashable, Sendable {
    public enum Form: Hashable, Sendable {
        case rows(IndexSet)
        case allExcept(IndexSet)
    }

    public var form: Form

    public init(rows: IndexSet = []) {
        form = .rows(rows)
    }

    public static let none = ListSelection()

    public static func all(except: IndexSet = []) -> ListSelection {
        var selection = ListSelection()
        selection.form = .allExcept(except)
        return selection
    }

    public var isEmpty: Bool {
        if case .rows(let rows) = form { return rows.isEmpty }
        return false
    }

    public func contains(_ row: Int) -> Bool {
        switch form {
        case .rows(let rows): return rows.contains(row)
        case .allExcept(let except): return !except.contains(row)
        }
    }

    /// The selected rows that stand for messages, header rows left out.
    public func indexes(in snapshot: ListSnapshot) -> IndexSet {
        let all = IndexSet(integersIn: 0..<snapshot.rows.count)
        let chosen: IndexSet
        switch form {
        case .rows(let rows): chosen = rows.intersection(all)
        case .allExcept(let except): chosen = all.subtracting(except)
        }
        return chosen.filteredIndexSet { snapshot.rows[$0].displayKind != .header }
    }

    /// How many message rows are selected, counted without listing them.
    public func count(in snapshot: ListSnapshot) -> Int {
        switch form {
        case .rows: return indexes(in: snapshot).count
        case .allExcept(let except):
            let excepted = except.filter { snapshot.rows.indices.contains($0) && snapshot.rows[$0].displayKind != .header }.count
            return snapshot.messageRowCount - excepted
        }
    }

    /// The rows not selected, when the selection is the whole view but for at most 1,000 of them.
    func unselected(in snapshot: ListSnapshot) -> IndexSet? {
        let all = IndexSet(integersIn: 0..<snapshot.rows.count).filteredIndexSet { snapshot.rows[$0].displayKind != .header }
        let rest: IndexSet
        switch form {
        case .rows(let rows): rest = all.subtracting(rows)
        case .allExcept(let except): rest = all.intersection(except)
        }
        return rest.count <= ActionTargets.largestItemList ? rest : nil
    }

    /// What a command acts on. At most 1,000 rows are named one by one. Above that, a command
    /// that can act on a whole view does so, as long as the rows left out are 1,000 or fewer;
    /// every other command refuses. None ever acts on the first 1,000 and quietly leaves the rest.
    public func targets(for command: ListCommand, in snapshot: ListSnapshot) -> ListTargets {
        let count = count(in: snapshot)
        guard count > 0 else { return .refused(ListStatusText.nothingSelected) }
        if count <= ActionTargets.largestItemList {
            return .items(ListSelection.items(indexes(in: snapshot), in: snapshot))
        }
        guard command.actsOnWholeView, let rest = unselected(in: snapshot) else {
            return .refused(ListStatusText.tooManySelected)
        }
        return .wholeView(except: ListSelection.items(rest, in: snapshot))
    }

    /// The rows' ids for code that still passes ids around, such as the reading pane; nil above
    /// 1,000 rows, where such code must not be handed a part of the selection.
    public func rowKeys(in snapshot: ListSnapshot) -> [RowKey]? {
        guard count(in: snapshot) <= ActionTargets.largestItemList else { return nil }
        return indexes(in: snapshot).compactMap { snapshot.rowKey(at: $0) }
    }

    static func items(_ rows: IndexSet, in snapshot: ListSnapshot) -> [ActionItem] {
        rows.compactMap { row in
            guard let key = snapshot.rowKey(at: row) else { return nil }
            return snapshot.rows[row].displayKind == .conversation ? .conversation(key) : .message(key)
        }
    }
}

/// What a command was given to act on.
public enum ListTargets: Hashable, Sendable {
    case items([ActionItem])
    case wholeView(except: [ActionItem])
    /// The command does nothing, and the status line says why.
    case refused(String)

    /// As the engine takes them; nil when refused.
    public var actionTargets: ActionTargets? {
        switch self {
        case .items(let items): return .items(items)
        case .wholeView(let except): return .wholeView(except: except)
        case .refused: return nil
        }
    }
}

/// The commands that act on the list's selection.
public enum ListCommand: String, CaseIterable, Hashable, Sendable {
    case markRead, markUnread, flag, unflag, archive, move, copy, delete, deleteForever
    case junk, notJunk, categorise, mute, unmute, moveToFocused, moveToOther
    case open, reply, replyAll, forward, forwardAsAttachment, saveAs, print, createRule

    /// Move, Archive, Delete, read state, flags, Junk and categories can be described by the view
    /// as a whole and sent as bulk work. The rest need each message, so they stop at 1,000.
    public var actsOnWholeView: Bool {
        switch self {
        case .markRead, .markUnread, .flag, .unflag, .archive, .move, .delete, .junk, .notJunk, .categorise:
            return true
        default:
            return false
        }
    }

    /// The engine's verb for the command on a whole view, as after Select All; nil for a command
    /// that needs each message, and for Move, which asks which folder a thousand at a time.
    public var wholeViewVerb: MailActionRequest.Verb? {
        switch self {
        case .markRead: return .markRead
        case .markUnread: return .markUnread
        case .flag: return .flag
        case .unflag: return .unflag
        case .archive: return .archive
        case .delete: return .delete
        case .junk: return .junk
        case .notJunk: return .notJunk
        default: return nil
        }
    }

    public init?(_ verb: MailActionRequest.Verb) {
        switch verb {
        case .markRead: self = .markRead
        case .markUnread: self = .markUnread
        case .flag: self = .flag
        case .unflag: self = .unflag
        case .archive: self = .archive
        case .move: self = .move
        case .copy: self = .copy
        case .delete: self = .delete
        case .deleteForever: self = .deleteForever
        case .junk: self = .junk
        case .notJunk: self = .notJunk
        case .mute: self = .mute
        case .unmute: self = .unmute
        case .moveToFocused: self = .moveToFocused
        case .moveToOther: self = .moveToOther
        }
    }
}

extension ListStatusText {
    static let nothingSelected = "Select a message first."
}
