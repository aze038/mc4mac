import AppKit
import FalconCore

/// The signatures the Signatures pane, its editor windows and the composer share. Every change
/// shows at once everywhere but typing, which is taken when it pauses and reaches the disk with
/// it; saveNow takes whatever is still waiting.
@MainActor
@Observable
final class SignatureLibrary {
    private(set) var book: SignatureBook
    /// Why changes are not being kept, or where a damaged file went, for the pane to say.
    let problem: SignatureStore.Problem?
    @ObservationIgnored private let store: SignatureStore?
    @ObservationIgnored private let writable: Bool
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// Editors' text not yet in the book, so the pane's preview and every open message's
    /// Signature menu are not redrawn at each keystroke.
    @ObservationIgnored private var pendingTexts: [UUID: NSAttributedString] = [:]

    init(store: SignatureStore) {
        let opened = store.open()
        self.store = store
        book = opened.book
        problem = opened.problem
        writable = opened.writable
    }

    #if DEBUG
    /// Held in memory only, for the debug snapshots.
    init(book: SignatureBook, problem: SignatureStore.Problem? = nil) {
        store = nil
        self.book = book
        self.problem = problem
        writable = false
    }
    #endif

    var sorted: [Signature] { book.sorted }

    func signature(_ id: UUID?) -> Signature? { book.signature(id) }

    func signature(for accountID: UUID, _ use: SignatureUse) -> Signature? { book.signature(for: accountID, use) }

    /// Carries the accounts' own signatures over the first time each account is seen, and again
    /// when an older build has changed one.
    func adopt(_ accounts: [AccountInfo]) {
        guard book.adopt(accounts) else { return }
        saveNow()
    }

    func add(startingWith text: String = "") -> Signature {
        let signature = book.add(startingWith: text)
        saveNow()
        return signature
    }

    func remove(_ id: UUID) {
        pendingTexts[id] = nil
        book.remove(id)
        saveNow()
    }

    func rename(_ id: UUID, to name: String) {
        book.rename(id, to: name)
        scheduleSave()
    }

    /// The editor's text, which fills plain signatures in with the composer's formatting; text
    /// with no more than that stays plain.
    func setText(_ text: NSAttributedString, of id: UUID) {
        pendingTexts[id] = text
        scheduleSave()
    }

    func setDefault(_ id: UUID?, for accountID: UUID, _ use: SignatureUse) {
        book.setDefault(id, for: accountID, use)
        saveNow()
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        for (id, text) in pendingTexts { book.setText(text, of: id, plainIn: RichText.bodyAttributes) }
        pendingTexts = [:]
        guard writable, let store else { return }
        try? store.save(book)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }
}
