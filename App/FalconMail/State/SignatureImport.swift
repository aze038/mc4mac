import AppKit
import FalconCore

/// One import of signatures from Legacy Outlook for Mac or from Gmail, as the Signatures pane's
/// import sheet shows it: reading them, which only starts when the owner asks, then each
/// signature with a preview, what to do when its name is taken, and which accounts it becomes
/// the default for.
@MainActor
@Observable
final class SignatureImportSession: Identifiable {
    enum Source {
        case outlook, gmail
    }

    enum Stage {
        case reading
        case ready
        /// Nothing to import, and why, in a plain sentence; `privacy` when macOS refused, so the
        /// sheet can open the setting that allows it.
        case failed(String, privacy: Bool)
        /// Imported: what came in and which accounts now start with it, in sentences.
        case done(String)
    }

    /// A signature on offer.
    struct Row: Identifiable {
        var id: UUID { candidate.id }
        let candidate: SignatureCandidate
        /// As it will come in.
        let signature: Signature
        var included = true
        /// Whether a signature here has its name, and so what to do about it is asked.
        let nameTaken: Bool
        var clash: SignatureNameClash = .keepBoth
    }

    /// One account whose messages an imported signature is to start.
    struct DefaultChoice: Identifiable {
        var id: String { "\(candidateID.uuidString)-\(accountID.uuidString)" }
        let candidateID: UUID
        let accountID: UUID
        let account: String
        var chosen = true
    }

    let id = UUID()
    let source: Source
    var stage: Stage = .reading
    var rows: [Row] = []
    var defaults: [DefaultChoice] = []
    var selection: UUID?
    /// What else the owner should know, such as a picture left out or an account Gmail did not
    /// answer for.
    var notes: [String] = []
    /// Where the signatures came from, under the sheet's title.
    var origin = ""
    /// Whether the defaults are the source's own, as Gmail's are, or suggested.
    var defaultsKnown = true

    init(source: Source) {
        self.source = source
    }

    var title: String {
        source == .outlook ? "Import Signatures from Outlook" : "Import Signatures from Gmail"
    }

    var canImport: Bool {
        guard case .ready = stage else { return false }
        return rows.contains(where: \.included)
    }

    // MARK: - Reading

    /// Reads the signatures, off the main thread, and lays them out. macOS may ask the owner
    /// once whether FalconMail may read Outlook's data; that question comes now, when the owner
    /// has asked for the import, and never at launch.
    func start(model: AppModel) async {
        switch source {
        case .outlook: await readOutlook(model: model)
        case .gmail: await readGmail(model: model)
        }
    }

    private func readOutlook(model: AppModel) async {
        let read = await Task.detached(priority: .userInitiated) { () -> Result<[OutlookProfileSignatures], OutlookSignatureImport.Problem> in
            do {
                return .success(try OutlookSignatureImport.read())
            } catch let problem as OutlookSignatureImport.Problem {
                return .failure(problem)
            } catch {
                return .failure(.unreadable)
            }
        }.value
        switch read {
        case .failure(let problem):
            stage = .failed(Self.sentence(for: problem), privacy: problem == .notAllowed)
        case .success(let profiles):
            let names = profiles.filter { !$0.signatures.isEmpty }.map { "“\($0.profile.name)”" }
            origin = names.count > 1 ? "From the Outlook profiles \(names.joined(separator: " and "))."
                : names.first.map { "From the Outlook profile \($0)." } ?? ""
            defaultsKnown = false
            prepare(profiles.flatMap(SignatureCandidate.outlook), model: model, remote: [:])
            if rows.isEmpty, case .ready = stage {
                stage = .failed("Outlook has no signatures to import.", privacy: false)
            }
        }
    }

    static func sentence(for problem: OutlookSignatureImport.Problem) -> String {
        switch problem {
        case .noOutlook:
            return "There’s no Outlook for Mac profile on this Mac, so there are no Outlook signatures to import."
        case .notAllowed:
            return "macOS didn’t let FalconMail read Outlook’s signatures. To allow it, turn on FalconMail in System Settings › "
                + "Privacy & Security › Full Disk Access, then try again."
        case .unreadable:
            return "FalconMail couldn’t read Outlook’s signatures. Quit Outlook if it is open, then try again."
        }
    }

    private func readGmail(model: AppModel) async {
        let accounts = model.accounts.filter(model.usesGmailAPI)
        guard !accounts.isEmpty else {
            stage = .failed("None of your accounts is a Google account signed in with Google, so there are no Gmail signatures to import.",
                            privacy: false)
            return
        }
        var candidates: [SignatureCandidate] = []
        var refusals: [String] = []
        for account in accounts {
            guard let client = model.gmailClient(for: account.id) else { continue }
            do {
                candidates += SignatureCandidate.gmail(try await client.sendAs(), account: account.email)
            } catch let error as GoogleAPIError {
                refusals.append(Self.sentence(for: error, account: account.email))
            } catch {
                refusals.append("Gmail didn’t answer for \(account.email). Try again later.")
            }
        }
        origin = "From the Gmail settings of \(accounts.map(\.email).joined(separator: ", "))."
        defaultsKnown = true
        // Each picture from the web is fetched once, however many signatures show it.
        let addresses = candidates.flatMap(\.remoteAddresses)
        let fetched = addresses.isEmpty ? [:] : await model.remotePictureLoader.fetch(addresses)
        prepare(candidates, model: model, remote: fetched)
        notes = refusals + notes
        if rows.isEmpty {
            let reason = refusals.isEmpty ? "Gmail has no signatures for \(accounts.map(\.email).joined(separator: " or "))." : refusals.joined(separator: " ")
            stage = .failed(reason, privacy: false)
        }
    }

    static func sentence(for error: GoogleAPIError, account: String) -> String {
        switch error.kind {
        case .needsSignIn:
            return "\(account) needs to sign in to Google again (Settings › Accounts)."
        case .insufficientPermissions, .clientRejected:
            return "Google didn’t let FalconMail read the Gmail settings of \(account). Sign in to it again to allow it."
        case .offline:
            return "FalconMail is offline, so Gmail couldn’t be asked for the signatures of \(account)."
        case .apiDisabled:
            return "The Gmail API is turned off for FalconMail, so the signatures of \(account) couldn’t be read."
        default:
            return "Gmail didn’t answer for \(account). Try again later."
        }
    }

    /// Lays the candidates out as rows, each already the signature it will become, and each
    /// account it is for as a chosen default.
    func prepare(_ candidates: [SignatureCandidate], model: AppModel, remote: [String: Data]) {
        rows = []
        defaults = []
        for candidate in candidates {
            guard let signature = candidate.signature(remote: remote, attributes: RichText.bodyAttributes) else {
                notes.append("“\(candidate.name)” couldn’t be read and is left out.")
                continue
            }
            if candidate.missingPictures > 0 {
                notes.append(candidate.missingPictures == 1
                             ? "A picture in “\(candidate.name)” couldn’t be found and is left out."
                             : "\(candidate.missingPictures) pictures in “\(candidate.name)” couldn’t be found and are left out.")
            }
            rows.append(Row(candidate: candidate, signature: signature, nameTaken: model.signatures.book.hasSignature(named: signature.name)))
            for accountID in candidate.defaultAccounts(in: model.accounts) {
                guard let account = model.accounts.first(where: { $0.id == accountID }) else { continue }
                // One account starts with one signature: the first offered for it is chosen.
                let taken = defaults.contains { $0.accountID == accountID && $0.chosen }
                defaults.append(DefaultChoice(candidateID: candidate.id, accountID: accountID, account: account.email, chosen: !taken))
            }
        }
        selection = rows.first?.id
        stage = .ready
    }

    // MARK: - Choosing

    func row(_ id: UUID?) -> Row? {
        rows.first { $0.id == id }
    }

    func setIncluded(_ included: Bool, _ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].included = included
    }

    func setClash(_ clash: SignatureNameClash, _ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].clash = clash
    }

    /// Choosing a signature for an account unchooses any other for it.
    func setDefault(_ chosen: Bool, _ choice: DefaultChoice) {
        for index in defaults.indices where defaults[index].accountID == choice.accountID {
            if defaults[index].id == choice.id {
                defaults[index].chosen = chosen
            } else if chosen {
                defaults[index].chosen = false
            }
        }
    }

    /// The defaults that apply: chosen, for a signature that comes in.
    var effectiveDefaults: [DefaultChoice] {
        defaults.filter { choice in
            choice.chosen && rows.contains { $0.id == choice.candidateID && $0.included && !($0.nameTaken && $0.clash == .skip) }
        }
    }

    // MARK: - Importing

    /// Brings the chosen signatures in, says in the sheet what was done, and returns what came
    /// in and a line saying so for the pane.
    @discardableResult
    func importChosen(into library: SignatureLibrary, accounts: [AccountInfo]) -> (outcome: SignatureImportOutcome, line: String) {
        let chosenDefaults = effectiveDefaults
        let items = rows.filter(\.included).map { row in
            SignatureImportItem(signature: row.signature, clash: row.nameTaken ? row.clash : .keepBoth,
                                defaultFor: chosenDefaults.filter { $0.candidateID == row.id }.map(\.accountID))
        }
        let outcome = library.importSignatures(items)
        stage = .done(Self.summary(outcome, library: library, accounts: accounts))
        return (outcome, Self.line(outcome, library: library))
    }

    /// "Imported “Main”. “Main” now starts new messages, replies and forwards from alex@example.com."
    static func summary(_ outcome: SignatureImportOutcome, library: SignatureLibrary, accounts: [AccountInfo]) -> String {
        guard !outcome.imported.isEmpty else {
            return outcome.skipped.isEmpty ? "Nothing was imported." : "Nothing was imported: \(list(outcome.skipped.map { "“\($0)”" })) skipped."
        }
        var sentences = [line(outcome, library: library)]
        for id in outcome.imported {
            let addresses = outcome.defaults.filter { $0.signatureID == id }
                .compactMap { choice in accounts.first { $0.id == choice.accountID }?.email }
            guard !addresses.isEmpty, let name = library.signature(id)?.name else { continue }
            sentences.append("“\(name)” now starts new messages, replies and forwards from \(list(addresses)).")
        }
        if !outcome.skipped.isEmpty { sentences.append("Skipped \(list(outcome.skipped.map { "“\($0)”" })).") }
        if outcome.defaults.isEmpty {
            sentences.append("Choose which accounts use \(outcome.imported.count == 1 ? "it" : "them") under Choose default signature.")
        }
        return sentences.joined(separator: " ")
    }

    /// "Imported “Main” and “Short”."
    static func line(_ outcome: SignatureImportOutcome, library: SignatureLibrary) -> String {
        let names = outcome.imported.compactMap { library.signature($0)?.name }.map { "“\($0)”" }
        return names.isEmpty ? "Nothing was imported." : "Imported \(list(names))."
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
