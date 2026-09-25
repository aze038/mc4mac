import SwiftUI
import AppKit
import FalconCore

/// The sheet an import from Outlook or Gmail shows over the Signatures pane, drawn with the
/// pane's own controls: the signatures on offer, each with a box to leave it out, the chosen
/// one's preview as the pane shows a signature, what to do when its name is taken, which
/// accounts each is to start messages from, and Import. While the signatures are read it says
/// so; when there is nothing to import it says why in a sentence.
struct SignatureImportSheet: View {
    @Bindable var session: SignatureImportSession
    /// Imports what is chosen, which then says in the sheet what it did.
    let perform: () -> Void
    /// Closes the sheet.
    let close: () -> Void

    static let size = CGSize(width: 612, height: 452)
    /// The sheet while it reads, and when it has only a sentence to say.
    static let shortHeight: CGFloat = 170

    var body: some View {
        Group {
            switch session.stage {
            case .reading: reading
            case .failed(let reason, let privacy): message(reason, symbol: privacy ? "lock.fill" : "exclamationmark.triangle.fill",
                                                           tint: privacy ? .secondary : .yellow, privacy: privacy, button: "Close")
            case .done(let summary): message(summary, symbol: "checkmark.circle.fill", tint: .green, privacy: false, button: "Done")
            case .ready: ready
            }
        }
        .frame(width: Self.size.width, height: height, alignment: .topLeading)
        .background(Classic.pane)
    }

    private var height: CGFloat {
        if case .ready = session.stage { return Self.size.height }
        return Self.shortHeight
    }

    // MARK: - Reading and failing

    private var reading: some View {
        Placements(width: Self.size.width, height: Self.shortHeight) {
            ClassicText(session.title, weight: .bold).at(x: 20, baseline: 32)
            ProgressView().controlSize(.small).at(x: 20, y: 52)
            ClassicText(session.source == .outlook ? "Reading Outlook’s signatures…" : "Asking Gmail for your signatures…")
                .at(x: 46, baseline: 64)
            ClassicButton(title: "Cancel", width: 82) { close() }
                .keyboardShortcut(.cancelAction).at(x: Self.size.width - 20 - 82, y: Self.shortHeight - 40)
        }
    }

    /// A sentence under the title with a symbol before it: why there is nothing to import, or
    /// what the import did.
    private func message(_ text: String, symbol: String, tint: Color, privacy: Bool, button: String) -> some View {
        Placements(width: Self.size.width, height: Self.shortHeight) {
            ClassicText(session.title, weight: .bold).at(x: 20, baseline: 32)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .font(.system(size: 20))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Classic.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.size.width - 80, alignment: .leading)
            }
            .at(x: 20, y: 50)
            if privacy {
                ClassicButton(title: "Open Privacy & Security", width: 180) { SignatureImportSheet.openPrivacySettings() }
                    .at(x: Self.size.width - 20 - 82 - 12 - 180, y: Self.shortHeight - 40)
            }
            DefaultButton(title: button, width: 82) { close() }
                .keyboardShortcut(.defaultAction).at(x: Self.size.width - 20 - 82, y: Self.shortHeight - 40)
        }
    }

    /// System Settings at Full Disk Access, where FalconMail can be let read Outlook's data.
    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - What is on offer

    private var ready: some View {
        Placements(width: Self.size.width, height: Self.size.height) {
            ClassicText(session.title, weight: .bold).at(x: 20, baseline: 28)
            if !session.origin.isEmpty {
                ClassicText(session.origin, size: 11).opacity(0.75).at(x: 20, baseline: 46)
            }
            ClassicBox(width: 572, height: 204).at(x: 20, y: 58)
            ImportList(session: session)
                .frame(width: ImportList.size.width, height: ImportList.size.height)
                .at(x: 36, y: 74)
            SignaturePreview(text: session.row(session.selection).map { ComposedBody.filling($0.signature.text, with: RichText.bodyAttributes) })
                .at(x: 276, y: 74)
            clashLine.at(x: 36, y: 234)

            ClassicText("Use for new messages, replies and forwards from:", weight: .bold).at(x: 19, baseline: 285)
            ClassicBox(width: 572, height: 84).at(x: 20, y: 296)
            defaultsList.frame(width: 540, height: 70, alignment: .topLeading).at(x: 36, y: 303)
            footnote.frame(width: 572, alignment: .leading).at(x: 20, y: 386)

            ClassicButton(title: "Cancel", width: 82) { close() }
                .keyboardShortcut(.cancelAction).at(x: Self.size.width - 20 - 82 - 12 - 82, y: 418)
            DefaultButton(title: "Import", width: 82) { perform() }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canImport)
                .at(x: Self.size.width - 20 - 82, y: 418)
        }
    }

    /// Under the list, for the chosen signature: what to do with its name when one here has it.
    @ViewBuilder private var clashLine: some View {
        if let row = session.row(session.selection), row.nameTaken, row.included {
            HStack(alignment: .center, spacing: 8) {
                ClassicText("A signature named “\(row.signature.name)” already exists:", size: 11)
                ClassicPopUp(title: "Name already taken", items: [("Keep Both", SignatureNameClash.keepBoth), ("Replace", .replace), ("Skip", .skip)],
                             selection: Binding(get: { row.clash }, set: { session.setClash($0, row.id) }), small: true)
                    .frame(width: 110, height: ClassicPopUp<SignatureNameClash>.smallHeight)
            }
        }
    }

    @ViewBuilder private var defaultsList: some View {
        if session.defaults.isEmpty {
            Text(session.source == .outlook
                 ? "No account in FalconMail has the address of an account in Outlook. Choose each account’s signatures in the Signatures pane after importing."
                 : "No account in FalconMail sends from these addresses. Choose each account’s signatures in the Signatures pane after importing.")
                .font(.system(size: 11))
                .foregroundStyle(Classic.label.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.defaults) { choice in
                        let row = session.row(choice.candidateID)
                        ClassicCheckbox("\(choice.account): “\(row?.signature.name ?? "")”",
                                        isOn: Binding(get: { choice.chosen }, set: { session.setDefault($0, choice) }))
                            .disabled(!(row?.included ?? false) || (row?.nameTaken == true && row?.clash == .skip))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
    }

    /// Why the defaults are suggested, and anything left out.
    private var footnote: some View {
        var lines = session.notes
        if !session.defaultsKnown, !session.defaults.isEmpty {
            lines.insert("Outlook doesn’t say which account used which signature, so the accounts with the same address as in Outlook are suggested.", at: 0)
        }
        return Text(lines.joined(separator: " "))
            .font(.system(size: 11))
            .foregroundStyle(Classic.label.opacity(0.75))
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .help(lines.joined(separator: "\n"))
    }
}

/// The signatures on offer, as the pane lists its own: one column headed "Signature name",
/// striped rows, each with a box that leaves it out when cleared. A click on a name shows it.
private struct ImportList: View {
    static let size = CGSize(width: 227, height: 152)
    @Bindable var session: SignatureImportSession

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                SignatureListColours.header
                Text("Signature name").font(.system(size: 11)).foregroundStyle(SignatureListColours.headerText).fixedSize()
                    .at(x: 10, baseline: 18)
            }
            .frame(height: SignatureTable.headerHeight)
            SignatureListColours.headerLine.frame(height: 1)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(session.rows) { row in line(row) }
                }
                .frame(maxWidth: .infinity, minHeight: Self.size.height - 3 - SignatureTable.headerHeight, alignment: .top)
                .background(stripes)
            }
            .scrollIndicators(.automatic)
        }
        .padding(1)
        .background(SignatureListColours.border)
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Signatures to import")
    }

    private static let rowHeight: CGFloat = 22

    private func line(_ row: SignatureImportSession.Row) -> some View {
        let chosen = row.id == session.selection
        return ZStack(alignment: .leading) {
            chosen ? SignatureListColours.selected : Color.clear
            HStack(spacing: 6) {
                ClassicCheckbox("", isOn: Binding(get: { row.included }, set: { session.setIncluded($0, row.id) }))
                    .fixedSize()
                    .accessibilityLabel("Import “\(row.signature.name)”")
                Text(row.signature.name)
                    .font(.system(size: 13))
                    .foregroundStyle(SignatureListColours.rowText.opacity(row.included ? 1 : 0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
        }
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { session.selection = row.id }
    }

    private var stripes: some View {
        Canvas { context, size in
            var index = 0
            while CGFloat(index) * Self.rowHeight < size.height {
                let rect = CGRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: size.width, height: Self.rowHeight)
                context.fill(Path(rect), with: .color(index.isMultiple(of: 2) ? SignatureListColours.stripeEven : SignatureListColours.stripeOdd))
                index += 1
            }
        }
    }
}

/// The blue push button a sheet's default action is, as Outlook's are, twenty points tall.
private struct DefaultButton: View {
    let title: String
    let width: CGFloat
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            ZStack {
                if enabled {
                    ClassicBezel(highlight: Classic.smallCapTop, fill: Classic.onBottom, radius: 5)
                } else {
                    ClassicBezel(highlight: Classic.buttonHighlight, fill: Classic.buttonFill, radius: 5)
                }
                Text(title).font(.system(size: 13))
                    .foregroundStyle(enabled ? Color.white : Color(nsColor: Classic.buttonText).opacity(0.5))
                    .offset(y: -0.5)
            }
            .frame(width: width, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
