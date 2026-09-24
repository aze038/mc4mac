import Foundation

public struct MutedThread: Codable, Hashable, Sendable, Identifiable {
    public var accountID: UUID
    public var threadKey: String
    public var messageIDs: Set<String>
    public var normalizedSubject: String
    public var subject: String
    public var mutedAt: Date

    public var id: String { "\(accountID.uuidString):\(threadKey)" }

    public init(accountID: UUID, threadKey: String, messageIDs: Set<String>, normalizedSubject: String,
                subject: String, mutedAt: Date = Date()) {
        self.accountID = accountID
        self.threadKey = threadKey
        self.messageIDs = messageIDs
        self.normalizedSubject = normalizedSubject
        self.subject = subject
        self.mutedAt = mutedAt
    }
}

public actor MuteStore {
    private let url: URL
    private var muted: [MutedThread] = []
    private var loaded = false
    private var writable = true

    public init(layout: FileLayout = FileLayout()) {
        self.url = layout.mutedFile
    }

    public func all() -> [MutedThread] {
        loadIfNeeded()
        return muted
    }

    public func mute(_ record: MutedThread) {
        loadIfNeeded()
        guard let index = index(of: record.accountID, threadKey: record.threadKey) else {
            muted.append(record)
            save()
            return
        }
        muted[index].messageIDs.formUnion(record.messageIDs)
        muted[index].subject = record.subject
        muted[index].normalizedSubject = record.normalizedSubject
        save()
    }

    public func unmute(accountID: UUID, threadKey: String) {
        loadIfNeeded()
        let before = muted.count
        muted.removeAll { $0.accountID == accountID && $0.threadKey == threadKey }
        if muted.count != before { save() }
    }

    public func remember(messageID: String, accountID: UUID, threadKey: String) {
        guard !messageID.isEmpty else { return }
        loadIfNeeded()
        guard let index = index(of: accountID, threadKey: threadKey) else { return }
        guard !muted[index].messageIDs.contains(messageID) else { return }
        muted[index].messageIDs.insert(messageID)
        save()
    }

    public func match(accountID: UUID, threadKey: String, messageID: String, references: [String],
                      inReplyTo: String) -> MutedThread? {
        loadIfNeeded()
        return MuteStore.match(in: muted, accountID: accountID, threadKey: threadKey, messageID: messageID,
                               references: references, inReplyTo: inReplyTo)
    }

    public static func match(in list: [MutedThread], accountID: UUID, threadKey: String, messageID: String,
                             references: [String], inReplyTo: String) -> MutedThread? {
        let ancestors = Set((references + [inReplyTo]).filter { !$0.isEmpty })
        for record in list where record.accountID == accountID {
            if !threadKey.isEmpty, record.threadKey == threadKey { return record }
            if !messageID.isEmpty, record.messageIDs.contains(messageID) { return record }
            if !ancestors.isDisjoint(with: record.messageIDs) { return record }
        }
        return nil
    }

    private func index(of accountID: UUID, threadKey: String) -> Int? {
        muted.firstIndex { $0.accountID == accountID && $0.threadKey == threadKey }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let stored = AtomicFile.loadJSON([MutedThread].self, from: url, what: "the muted conversations")
        muted = stored.value ?? []
        writable = stored.canSave
    }

    private func save() {
        guard writable else { return }
        do {
            try AtomicFile.writeJSON(muted, to: url)
        } catch {
            Log.error("Store", "could not save the muted conversations: \(error.localizedDescription)", error: error, logAs: "store")
        }
    }
}
