import SwiftUI
import FalconCore

/// A signature the Signature menu offers. Each account keeps one, which Settings calls "Main".
/// Only the draft's own account's is plain "Main"; another account's carries its address, so
/// it is not taken for the draft's own when that account has none.
struct SignatureChoice: Identifiable {
    let id: UUID
    let name: String
    let block: String

    /// The draft's own account first, then the others that have a signature.
    static func choices(from accounts: [AccountInfo], preferring accountID: UUID?) -> [SignatureChoice] {
        let signed = accounts.filter { !$0.signature.trimmed.isEmpty }
        let ordered = signed.filter { $0.id == accountID } + signed.filter { $0.id != accountID }
        return ordered.map { account in
            SignatureChoice(id: account.id,
                            name: account.id == accountID ? "Main" : "Main (\(account.email))",
                            block: ComposeDraft.signatureBlock(account))
        }
    }
}

/// Outlook's Signature menu: the signatures by name, then Signatures… for the settings pane
/// where they are written.
struct SignatureMenuItems: View {
    let choices: [SignatureChoice]
    let insert: (SignatureChoice) -> Void
    let edit: () -> Void

    var body: some View {
        if choices.isEmpty {
            Button("No Signatures") {}.disabled(true)
        } else {
            ForEach(choices) { choice in
                Button(choice.name) { insert(choice) }
            }
        }
        Divider()
        Button("Signatures…", action: edit)
    }
}
