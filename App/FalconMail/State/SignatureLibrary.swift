import AppKit
import FalconCore

/// The signatures the Signatures pane, its editor windows and the composer share. Every change
/// shows at once everywhere; typing in an editor reaches the disk a moment after it stops.
@MainActor
@Observable
final class SignatureLibrary {
    private(set) var book: SignatureBook
    @ObservationIgnored private let store: SignatureStore?
    @ObservationIgnored private let writable: Bool
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(store: SignatureStore) {
        let opened = store.open()
        self.store = store
        book = opened.book
        writable = opened.writable
    }

    #if DEBUG
    /// Held in memory only, for the debug snapshots.
    init(book: SignatureBook) {
        store = nil
        self.book = book
        writable = false
    }
    #endif

    var sorted: [Signature] { book.sorted }

    func signature(_ id: UUID?) -> Signature? { book.signature(id) }

    func signature(for accountID: UUID, _ use: SignatureUse) -> Signature? { book.signature(for: accountID, use) }

    /// Carries the accounts' own signatures over the first time each account is seen.
    func adopt(_ accounts: [AccountInfo]) {
        guard book.adopt(accounts) else { return }
        saveNow()
    }

    func add() -> Signature {
        let signature = book.add()
        saveNow()
        return signature
    }

    func remove(_ id: UUID) {
        book.remove(id)
        saveNow()
    }

    func rename(_ id: UUID, to name: String) {
        book.rename(id, to: name)
        scheduleSave()
    }

    func setText(_ text: NSAttributedString, of id: UUID) {
        book.setText(text, of: id)
        scheduleSave()
    }

    func setDefault(_ id: UUID?, for accountID: UUID, _ use: SignatureUse) {
        book.setDefault(id, for: accountID, use)
        saveNow()
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard writable, let store else { return }
        try? store.save(book)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }
}
