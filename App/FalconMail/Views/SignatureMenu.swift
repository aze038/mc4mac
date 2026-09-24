import SwiftUI
import FalconCore

/// Outlook's Signature menu: every signature by name, then Signatures… for the settings pane
/// where they are written.
struct SignatureMenuItems: View {
    let signatures: [Signature]
    let insert: (Signature) -> Void
    let edit: () -> Void

    var body: some View {
        if !signatures.isEmpty {
            ForEach(signatures) { signature in
                Button(signature.name) { insert(signature) }
            }
            Divider()
        }
        Button("Signatures…", action: edit)
    }
}
