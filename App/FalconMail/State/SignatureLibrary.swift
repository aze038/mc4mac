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
    /// Carried-over signatures already read as HTML this session, so one that cannot be read
    /// is not fetched for again.
    @ObservationIgnored private var importedHTML: Set<UUID> = []
    /// HTML just pasted into an editor as a signature, kept with the signature while its text
    /// still reads as that HTML did (see Signature.setEditedText).
    @ObservationIgnored private var pastedHTML: [UUID: SignatureSource] = [:]

    init(store: SignatureStore) {
        let opened = store.open()
        self.store = store
        book = opened.book
        problem = opened.problem
        writable = opened.writable
        // A draft kept with a signature sends the signature's own HTML after a relaunch too.
        SignatureSources.register(book.signatures)
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

    /// Each account signature carried over as HTML source, as one pasted into an older build's
    /// account settings from a web page is, becomes the formatted signature it describes, once:
    /// its pictures from the web are fetched this one time, and one that cannot be fetched stays
    /// an empty box that is sent from its address. A signature the owner has written or changed
    /// is never touched, nor is one of plain words.
    func importCarriedOverHTML(loader: RemotePictureLoader) async {
        var changed = false
        for candidate in book.carriedOverHTML where importedHTML.insert(candidate.id).inserted {
            let addresses = RemotePictures.addresses(inHTML: candidate.html)
            let pictures = addresses.isEmpty ? [:] : await loader.fetch(addresses)
            guard let text = Signature.text(fromHTML: candidate.html, pictures: pictures, attributes: RichText.bodyAttributes),
                  book.replaceCarriedOverHTML(candidate.id, source: candidate.html, with: text, plainIn: RichText.bodyAttributes)
            else { continue }
            changed = true
        }
        if changed { saveNow() }
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

    /// A signature's HTML pasted into its editor as `text`, which it is sent as while the
    /// editor's text still reads as it.
    func pasted(html: String, as text: NSAttributedString, into id: UUID) {
        pastedHTML[id] = SignatureSource(html: html, text: text)
    }

    private func takePendingTexts() {
        for (id, text) in pendingTexts {
            book.setEditedText(text, of: id, plainIn: RichText.bodyAttributes, pasted: pastedHTML[id])
            pastedHTML[id] = nil
        }
        pendingTexts = [:]
        SignatureSources.register(book.signatures)
    }

    /// Brings in signatures imported from Outlook or Gmail, as SignatureBook.importing does, and
    /// keeps them at once. What an editor still holds is taken first, so a signature being
    /// written that an import replaces is replaced, not written back over it.
    @discardableResult
    func importSignatures(_ items: [SignatureImportItem]) -> SignatureImportOutcome {
        takePendingTexts()
        let outcome = book.importing(items)
        saveNow()
        return outcome
    }

    func setDefault(_ id: UUID?, for accountID: UUID, _ use: SignatureUse) {
        book.setDefault(id, for: accountID, use)
        saveNow()
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        takePendingTexts()
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
