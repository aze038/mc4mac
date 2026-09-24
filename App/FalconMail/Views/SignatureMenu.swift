import SwiftUI
import FalconCore

/// Outlook's Signature menu: Edit Signatures… for the settings pane where they are written,
/// a line, then every signature by name.
struct SignatureMenuItems: View {
    let signatures: [Signature]
    let insert: (Signature) -> Void
    let edit: () -> Void

    var body: some View {
        Button("Edit Signatures…", action: edit)
        if !signatures.isEmpty {
            Divider()
            ForEach(signatures) { signature in
                Button(signature.name) { insert(signature) }
            }
        }
    }
}
