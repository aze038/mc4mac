import Foundation

/// Where a Google account's Gmail engine keeps its files: `Accounts/<id>/Gmail/`, beside the
/// IMAP store, which it never writes. An earlier build ignores this folder, so going back to one
/// loses nothing and the next upgrade finds it as it was left.
public struct GmailFiles: Hashable, Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(layout: FileLayout, accountID: UUID) {
        self.init(directory: layout.accountDirectory(accountID).appendingPathComponent("Gmail", isDirectory: true))
    }

    /// The index as last compacted.
    public var indexSnapshot: URL { file("index.snap") }
    /// Everything since, appended: changes with their cursor, and listing pages.
    public var indexJournal: URL { file("index.journal") }
    public var labels: URL { file("labels.json") }
    public var dateAnchors: URL { file("anchors.json") }
    public var threadSummaries: URL { file("threads.json") }
    /// Rows and reply headers of the newest 1,000.
    public var cacheDirectory: URL { directory.appendingPathComponent("cache", isDirectory: true) }
    public var bodiesDirectory: URL { directory.appendingPathComponent("bodies", isDirectory: true) }
    /// Words of the kept messages' headers and previews, for searching them offline.
    public var terms: URL { file("terms.json") }
    /// Ids FalconMail imported itself over the last 7 days, so their echo is never new mail.
    public var importLog: URL { file("imports.json") }
    /// Changes waiting to reach Gmail. An earlier build never reads it.
    public var pendingOps: URL { file("pendingOps.json") }
    /// Which Gmail draft each message id belongs to.
    public var drafts: URL { file("drafts.json") }
    /// The engine's own state. It never holds the history cursor, which lives in the journal only.
    public var state: URL { file("state.json") }
    /// How far moving local state to Gmail ids has got.
    public var migration: URL { file("migration.json") }

    /// One cached message's reduced body.
    public func body(_ id: GmailMessageID) -> URL {
        bodiesDirectory.appendingPathComponent("\(id.hex).lzfse")
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
}
