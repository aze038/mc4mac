import Foundation

public enum MailActionKind: String, Codable, Sendable {
    case archive, delete, move, flag, unflag, read, unread

    public static func forFlag(_ flag: MessageFlags, enabled: Bool) -> MailActionKind {
        if flag.contains(.seen) { return enabled ? .read : .unread }
        return enabled ? .flag : .unflag
    }
}

public enum PendingServerVerb: String, Codable, Sendable {
    case archive, move, expunge, store
}

public struct PendingServerOperation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var accountID: UUID
    public var folderID: UUID
    public var verb: PendingServerVerb
    public var uids: [UInt32]
    public var uidValidity: UInt32?
    public var destinationPath: String
    public var flagNames: [String]
    public var enabled: Bool
    public var date: Date

    public init(id: UUID = UUID(), accountID: UUID, folderID: UUID, verb: PendingServerVerb, uids: [UInt32],
                uidValidity: UInt32? = nil, destinationPath: String = "", flagNames: [String] = [],
                enabled: Bool = true, date: Date = Date()) {
        self.id = id
        self.accountID = accountID
        self.folderID = folderID
        self.verb = verb
        self.uids = uids
        self.uidValidity = uidValidity
        self.destinationPath = destinationPath
        self.flagNames = flagNames
        self.enabled = enabled
        self.date = date
    }

    public func appliesTo(_ folder: FolderInfo) -> Bool {
        guard let recorded = uidValidity, recorded != 0, folder.uidValidity != 0 else { return true }
        return recorded == folder.uidValidity
    }
}

public actor PendingActionStore {
    private let url: URL
    private var operations: [PendingServerOperation] = []
    private var loaded = false

    public init(layout: FileLayout = FileLayout()) {
        self.url = layout.pendingActionsFile
    }

    public func all() -> [PendingServerOperation] {
        loadIfNeeded()
        return operations
    }

    public func add(_ operation: PendingServerOperation) {
        loadIfNeeded()
        operations.removeAll { $0.id == operation.id }
        operations.append(operation)
        save()
    }

    public func remove(_ id: UUID) {
        loadIfNeeded()
        let before = operations.count
        operations.removeAll { $0.id == id }
        if operations.count != before { save() }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        operations = AtomicFile.readJSON([PendingServerOperation].self, from: url) ?? []
    }

    private func save() {
        try? AtomicFile.writeJSON(operations, to: url)
    }
}

public struct MailActionRecord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kind: MailActionKind
    public let accountID: UUID
    public let folderID: UUID
    public let messages: [MessageSummary]
    public let destinationName: String
    public let date: Date
    public let isAutomatic: Bool

    public init(id: UUID, kind: MailActionKind, accountID: UUID, folderID: UUID,
                messages: [MessageSummary], destinationName: String, date: Date, isAutomatic: Bool = false) {
        self.id = id
        self.kind = kind
        self.accountID = accountID
        self.folderID = folderID
        self.messages = messages
        self.destinationName = destinationName
        self.date = date
        self.isAutomatic = isAutomatic
    }

    public var verbTitle: String {
        switch kind {
        case .archive: return "Archive"
        case .delete: return "Delete"
        case .move: return "Move"
        case .flag: return "Flag"
        case .unflag: return "Unflag"
        case .read: return "Mark as Read"
        case .unread: return "Mark as Unread"
        }
    }

    public var failurePrefix: String {
        switch kind {
        case .archive: return "Could not archive"
        case .delete: return "Could not delete"
        case .move: return "Could not move"
        case .flag, .unflag: return "Could not change the flag"
        case .read, .unread: return "Could not change the read state"
        }
    }

    public static func noun(_ count: Int) -> String {
        count == 1 ? "message" : "messages"
    }

    public static func summary(for records: [MailActionRecord]) -> String {
        guard let first = records.first else { return "" }
        let count = records.reduce(0) { $0 + $1.messages.count }
        let subject = "\(count) \(noun(count))"
        switch first.kind {
        case .archive: return "Archived \(subject)"
        case .delete: return "Deleted \(subject)"
        case .move:
            guard !first.destinationName.isEmpty else { return "Moved \(subject)" }
            return "Moved \(subject) to \(first.destinationName)"
        case .flag: return "Flagged \(subject)"
        case .unflag: return "Unflagged \(subject)"
        case .read: return "Marked \(subject) as read"
        case .unread: return "Marked \(subject) as unread"
        }
    }
}
