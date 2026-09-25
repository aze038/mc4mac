import SwiftUI
import AppKit
import FalconCore

/// Legacy Outlook's Signatures pane at its measured positions: under "Edit signature:", a group
/// box holding the signatures by name, with + − and Edit under the list and the chosen one's
/// preview on white beside it; under "Choose default signature:", a box with each account's
/// signatures for new messages and for replies and forwards.
///
/// Beside + and − a small action menu offers Import from Outlook… and Import from Gmail…, and
/// while there are no signatures the empty preview offers the same. An import shows its sheet
/// (SignatureImportSheet), and what it did is said in a line under the boxes.
struct SignaturesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var accountID: UUID?
    @State private var importing: SignatureImportSession?
    /// What the last import did, for the line under the boxes.
    @State private var imported: String?

    #if DEBUG
    /// What the debug snapshots show as the last import.
    static var snapshotImported: String?
    #endif

    private var library: SignatureLibrary { model.signatures }

    static let size = CGSize(width: 612, height: 425 - SettingsWindows.titleBarHeight)

    var body: some View {
        Placements(width: Self.size.width, height: Self.size.height) {
            ClassicText("Edit signature:", weight: .bold).at(x: 19, baseline: 24)
            ClassicBox(width: 572, height: 187).at(x: 20, y: 36)
            SignatureTable(signatures: library.sorted, selection: $selection,
                           open: { edit($0) }, remove: { askToRemove() })
                .frame(width: SignatureTable.size.width, height: SignatureTable.size.height)
                .at(x: 36, y: 53)
            SignatureListBar(canRemove: selection != nil, canEdit: selection != nil,
                             add: { add() }, remove: { askToRemove() }, edit: { selection.map(edit) },
                             importFrom: { beginImport($0) }, gmailAvailable: gmailAvailable)
                .at(x: 36, y: 184)
            SignaturePreview(text: library.signature(selection).map(previewText)).at(x: 276, y: 53)
            if library.sorted.isEmpty {
                SignatureImportOffer(gmailAvailable: gmailAvailable) { beginImport($0) }
                    .frame(width: 296, height: 134)
                    .at(x: 278, y: 71)
            }

            ClassicText("Choose default signature:", weight: .bold).at(x: 18.6, baseline: 244)
            ClassicBox(width: 572, height: 96).at(x: 20, y: 257)
            Group {
                ClassicText("Account:").at(rightX: 203, baseline: 282)
                ClassicPopUp(title: "Account", items: model.accounts.map { (accountTitle($0), Optional($0.id)) },
                             selection: accountBinding, small: true)
                    .frame(width: 350, height: ClassicPopUp<UUID?>.smallHeight)
                    .at(x: 206, y: 270)
                ClassicText("New messages:").at(rightX: 203, baseline: 308)
                defaultPopup(.newMessages, title: "New messages").at(x: 206, y: 293)
                ClassicText("Replies/Forwards:").at(rightX: 203, baseline: 332)
                defaultPopup(.replies, title: "Replies/Forwards").at(x: 206, y: 318)
            }
            .disabled(model.accounts.isEmpty)
            if let problem = library.problem {
                SignaturesNotice(problem: problem).frame(width: 572, alignment: .leading).at(x: 20, y: 357)
            } else if let imported {
                SignatureImportNotice(text: imported).frame(width: 572, alignment: .leading).at(x: 20, y: 357)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if selection == nil { selection = library.sorted.first?.id }
            if accountID == nil { accountID = model.accounts.first?.id }
            #if DEBUG
            if imported == nil { imported = Self.snapshotImported }
            #endif
        }
        .sheet(item: $importing) { session in
            SignatureImportSheet(session: session, perform: { performImport(session) }, close: { importing = nil })
        }
    }

    /// Whether any account can be asked for its Gmail signatures: a Google account signed in
    /// through Google.
    private var gmailAvailable: Bool {
        model.accounts.contains(where: model.usesGmailAPI)
    }

    /// Opens the import sheet and starts reading. Only here, when the owner asks, does FalconMail
    /// read Outlook's data or ask Gmail, so macOS asks its question about another app's data
    /// then and never at launch.
    private func beginImport(_ source: SignatureImportSession.Source) {
        guard importing == nil else { return }
        let session = SignatureImportSession(source: source)
        importing = session
        Task { await session.start(model: model) }
    }

    /// Imports what the sheet has chosen; the sheet then says what was done until it is closed,
    /// and the line under the boxes goes on saying what came in.
    private func performImport(_ session: SignatureImportSession) {
        guard session.canImport else { return }
        // A signature being written that the import replaces is closed first, so its editor
        // does not write the old words back over the new.
        for row in session.rows where row.included && row.nameTaken && row.clash == .replace {
            if let existing = library.book.signature(named: row.signature.name) { SignatureEditorWindows.shared.close(existing.id) }
        }
        let result = session.importChosen(into: library, accounts: model.accounts)
        if let first = result.outcome.imported.first { selection = first }
        if let account = result.outcome.defaults.first?.accountID { accountID = account }
        imported = result.line
    }

    /// Outlook names an account by its owner and address.
    private func accountTitle(_ account: AccountInfo) -> String {
        let name = account.displayName.trimmed
        return name.isEmpty ? account.email : "\(name) (\(account.email))"
    }

    /// Plain signatures carry no formatting, so they are shown in the composer's.
    private func previewText(_ signature: Signature) -> NSAttributedString {
        ComposedBody.filling(signature.text, with: RichText.bodyAttributes)
    }

    private var accountBinding: Binding<UUID?> {
        Binding(get: { accountID ?? model.accounts.first?.id }, set: { accountID = $0 })
    }

    private func defaultPopup(_ use: SignatureUse, title: String) -> some View {
        let account = accountBinding.wrappedValue
        let items = [("None", UUID?.none)] + library.sorted.map { ($0.name, Optional($0.id)) }
        return ClassicPopUp(title: title, items: items, selection: Binding(
            get: { account.flatMap { library.book.defaultID(for: $0, use) } },
            set: { id in if let account { library.setDefault(id, for: account, use) } }), small: true)
            .frame(width: 350, height: ClassicPopUp<UUID?>.smallHeight)
    }

    /// Outlook starts a new signature with the writer's name, taken here from the first
    /// account, and opens it at once.
    private func add() {
        let name = model.accounts.first.map { $0.displayName.trimmed } ?? ""
        let signature = library.add(startingWith: name.isEmpty ? NSFullUserName() : name)
        selection = signature.id
        edit(signature.id)
    }

    private func edit(_ id: UUID) {
        SignatureEditorWindows.shared.open(id, library: library)
    }

    private func askToRemove() {
        guard let signature = library.signature(selection) else { return }
        let alert = SignatureDeletion.alert()
        let confirmed: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { remove(signature) }
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: confirmed)
        } else {
            confirmed(alert.runModal())
        }
    }

    /// The row that takes the deleted one's place is selected, as a list in AppKit does.
    private func remove(_ signature: Signature) {
        let before = library.sorted
        let index = before.firstIndex { $0.id == signature.id } ?? 0
        SignatureEditorWindows.shared.close(signature.id)
        library.remove(signature.id)
        let after = library.sorted
        selection = after.isEmpty ? nil : after[min(index, after.count - 1)].id
    }
}

/// While there are no signatures, the empty preview offers to bring them in from Outlook or
/// Gmail, in small link-like buttons on its white page.
struct SignatureImportOffer: View {
    let gmailAvailable: Bool
    let begin: (SignatureImportSession.Source) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text("No signatures yet.")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.45))
            Button("Import from Outlook…") { begin(.outlook) }
            Button("Import from Gmail…") { begin(.gmail) }
                .disabled(!gmailAvailable)
                .help(gmailAvailable ? "" : "Add a Google account to import its Gmail signature.")
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .light)
    }
}

/// What the last import brought in, in the place of the notice about the signatures file, which
/// comes first when there is one: a green tick and a line, the whole of it in its help tag.
struct SignatureImportNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11))
        .help(text)
    }
}

/// Outlook's question before a signature goes, word for word, Delete being the default button.
enum SignatureDeletion {
    static func alert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Are you sure that you want to permanently delete the selected signature(s)?"
        alert.informativeText = "This action cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}

/// Says when the signatures file was left alone or moved aside, so that nothing done here is
/// lost, or turns up elsewhere, without a word. One line under the boxes; the whole of it is
/// in its help tag.
struct SignaturesNotice: View {
    let problem: SignatureStore.Problem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if case .setAside(let file) = problem {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .controlSize(.mini)
            }
        }
        .font(.system(size: 11))
        .help(message)
    }

    private var message: String {
        switch problem {
        case .newer:
            return "These signatures were saved by a newer version of FalconMail. Changes made here last only until FalconMail quits."
        case .unreadable:
            return "FalconMail couldn’t read its signatures file and has left it as it is. Changes made here last only until FalconMail quits."
        case .setAside(let file):
            return "The signatures file couldn’t be understood, so it was kept as “\(file.lastPathComponent)” and each account’s own signature was carried over again."
        }
    }
}

// MARK: - the list

/// The list's colours, measured: a darker header over a lighter line, rows striped dark and
/// clear so the box shows through, the chosen row grey until the list has the keyboard.
enum SignatureListColours {
    static let border = Classic.colour(light: 0xBEBEBE, dark: 0x353535)
    static let header = Classic.colour(light: 0xF7F7F7, dark: 0x1F222D)
    static let headerLine = Classic.colour(light: 0xD9D9D9, dark: 0x393C47)
    static let headerText = Classic.colour(light: 0x262626, dark: 0xFFFFFF)
    static let stripeEven = Classic.colour(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let stripeOdd = Classic.colour(light: 0xF4F5F5, dark: 0x292C37)
    static let selected = Classic.colour(light: 0xDCDCDC, dark: 0x464746)
    static let rowText = Classic.colour(light: 0x262626, dark: 0xDFDFE1)
}

/// The signature list: one column headed "Signature name", nineteen point rows striped down to
/// the list's bottom edge under a twenty-seven point header, in a one point frame. Arrow keys
/// move the choice, Return or a double-click edits it and Delete asks to remove it, as in
/// Outlook's.
struct SignatureTable: View {
    static let size = CGSize(width: 227, height: 131)
    static let rowHeight: CGFloat = 19
    static let headerHeight: CGFloat = 27

    let signatures: [Signature]
    @Binding var selection: UUID?
    let open: (UUID) -> Void
    let remove: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                SignatureListColours.header
                Text("Signature name").font(.system(size: 11)).foregroundStyle(SignatureListColours.headerText).fixedSize()
                    .at(x: 10, baseline: 18)
            }
            .frame(height: Self.headerHeight)
            SignatureListColours.headerLine.frame(height: 1)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(signatures) { signature in row(signature) }
                }
                .frame(maxWidth: .infinity, minHeight: Self.size.height - 3 - Self.headerHeight, alignment: .top)
                .background(stripes)
            }
            .scrollIndicators(.automatic)
        }
        .padding(1)
        .background(SignatureListColours.border)
        .frame(width: Self.size.width, height: Self.size.height)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) { selection.map(open); return .handled }
        .onKeyPress(.delete) { remove(); return .handled }
        .onKeyPress(.deleteForward) { remove(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Signatures")
    }

    private func row(_ signature: Signature) -> some View {
        let chosen = signature.id == selection
        return ZStack(alignment: .topLeading) {
            chosen ? (focused ? Color(nsColor: .selectedContentBackgroundColor) : SignatureListColours.selected) : Color.clear
            Text(signature.name)
                .font(.system(size: 13))
                .foregroundStyle(chosen && focused ? Color.white : SignatureListColours.rowText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: Self.size.width - 16, alignment: .leading)
                .at(x: 8, baseline: 14)
        }
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = signature.id
            focused = true
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(signature.id) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(signature.name)
        .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : [.isButton])
    }

    /// Every row's place is striped, filled or not, as Outlook's list is down to its bottom edge.
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

    private func move(_ step: Int) -> KeyPress.Result {
        guard !signatures.isEmpty else { return .ignored }
        let current = signatures.firstIndex { $0.id == selection }
        let next = current.map { min(max($0 + step, 0), signatures.count - 1) } ?? 0
        selection = signatures[next].id
        return .handled
    }
}

// MARK: - the bar under the list

/// Joined + and − at the left of a bar as wide as the list, Edit at its right end. Beside −
/// stands the action menu, a gear with a small arrow, holding the imports.
struct SignatureListBar: View {
    let canRemove: Bool
    let canEdit: Bool
    let add: () -> Void
    let remove: () -> Void
    let edit: () -> Void
    var importFrom: (SignatureImportSession.Source) -> Void = { _ in }
    var gmailAvailable = false

    private static let bar = Classic.colour(light: 0xE6E6E6, dark: 0x3B3D48)
    private static let barEdge = Classic.colour(light: 0xC4C4C4, dark: 0x464752)
    private static let button = Classic.colour(light: 0xFBFBFB, dark: 0x575963)
    private static let buttonEdge = Classic.colour(light: 0xB5B5B5, dark: 0x74757D)
    private static let joint = Classic.colour(light: 0xA8A8A8, dark: 0x919298)
    private static let inner = Classic.colour(light: 0xBDBDBD, dark: 0x6C6E76)
    private static let ink = Classic.colour(light: 0x3C3C3C, dark: 0xE5E5E7)

    var body: some View {
        Placements(width: SignatureTable.size.width, height: 22) {
            Self.barEdge.frame(width: 227, height: 22)
            Self.bar.frame(width: 225, height: 20).at(x: 1, y: 1)
            box(x: 0, width: 23)
            box(x: 22, width: 23)
            box(x: 44, width: 33)
            box(x: 171, width: 56)
            Self.joint.frame(width: 1, height: 20).at(x: 22, y: 1)
            Self.inner.frame(width: 1, height: 20).at(x: 44, y: 1)
            Self.inner.frame(width: 1, height: 20).at(x: 76, y: 1)
            Self.inner.frame(width: 1, height: 20).at(x: 171, y: 1)
            actionGlyph
                .frame(width: 31, height: 20)
                .overlay(MenuAnchor(title: "Import Signatures", items: [
                    ("Import from Outlook…", true, { importFrom(.outlook) }),
                    ("Import from Gmail…", gmailAvailable, { importFrom(.gmail) }),
                ]))
                .at(x: 45, y: 1)
            Button(action: add) { glyph(plus: true) }
                .buttonStyle(.plain).accessibilityLabel("Add").at(x: 1, y: 1)
            Button(action: remove) { glyph(plus: false) }
                .buttonStyle(.plain).accessibilityLabel("Remove").disabled(!canRemove).at(x: 23, y: 1)
            Button(action: edit) {
                Text("Edit").font(.system(size: 13)).foregroundStyle(Self.ink)
                    .opacity(canEdit ? 1 : 0.4)
                    .frame(width: 54, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canEdit)
            .at(x: 172, y: 1)
        }
    }

    private func box(x: CGFloat, width: CGFloat) -> some View {
        Self.button
            .frame(width: width - 2, height: 20)
            .overlay(Rectangle().strokeBorder(Self.buttonEdge, lineWidth: 1).padding(-1))
            .at(x: x + 1, y: 1)
    }

    /// AppKit's action gear and a small arrow under it saying it opens a menu.
    private var actionGlyph: some View {
        HStack(spacing: 2) {
            Image(nsImage: NSImage(named: NSImage.actionTemplateName) ?? NSImage())
                .renderingMode(.template)
                .resizable()
                .frame(width: 13, height: 13)
            Image(systemName: "chevron.down")
                .font(.system(size: 6, weight: .bold))
        }
        .foregroundStyle(Self.ink)
        .offset(x: 0.5)
    }

    /// The + and − in one point lines ten and a half points long.
    private func glyph(plus: Bool) -> some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2 + 0.25, y: size.height / 2 - (plus ? 0.25 : 0))
            var path = Path()
            path.move(to: CGPoint(x: centre.x - 5.25, y: centre.y))
            path.addLine(to: CGPoint(x: centre.x + 5.25, y: centre.y))
            if plus {
                path.move(to: CGPoint(x: centre.x, y: centre.y - 5.25))
                path.addLine(to: CGPoint(x: centre.x, y: centre.y + 5.25))
            }
            context.stroke(path, with: .color(Self.ink), lineWidth: 1)
        }
        .frame(width: 21, height: 20)
        .opacity(plus || canRemove ? 1 : 0.4)
        .contentShape(Rectangle())
    }
}

/// A transparent button over the view it overlays that opens `items` as a menu just under it,
/// as a pull-down does; an item given false is shown but cannot be chosen.
struct MenuAnchor: NSViewRepresentable {
    let title: String
    let items: [(String, Bool, () -> Void)]

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.menuButton)
        view.setAccessibilityLabel(title)
        view.toolTip = title
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.items = items
    }

    final class AnchorView: NSView {
        var items: [(String, Bool, () -> Void)] = []
        private var actions: [() -> Void] = []

        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) {
            popUp()
        }

        override func accessibilityPerformPress() -> Bool {
            popUp()
            return true
        }

        private func popUp() {
            let menu = NSMenu()
            menu.autoenablesItems = false
            actions = items.map(\.2)
            for (index, (title, enabled, _)) in items.enumerated() {
                let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.isEnabled = enabled
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
        }

        @objc private func choose(_ item: NSMenuItem) {
            guard actions.indices.contains(item.tag) else { return }
            actions[item.tag]()
        }
    }
}

// MARK: - the preview

/// "Signature Preview": a grey strip with the words centred over a white page on which the
/// signature is drawn as the recipient will see it, dark text on white in either appearance.
struct SignaturePreview: View {
    let text: NSAttributedString?

    static let size = CGSize(width: 300, height: 152)

    private static let strip = Classic.colour(light: 0xE8E8E8, dark: 0x4B4C57)
    private static let stripBottom = Classic.colour(light: 0xE0E0E0, dark: 0x464852)
    private static let stripEdge = Classic.colour(light: 0xC2C2C2, dark: 0x60626B)
    private static let stripText = Classic.colour(light: 0x262626, dark: 0xE4E4E5)

    var body: some View {
        Placements(width: Self.size.width, height: Self.size.height) {
            Self.stripEdge.frame(width: 300, height: 18)
            LinearGradient(colors: [Self.strip, Self.stripBottom], startPoint: .top, endPoint: .bottom)
                .frame(width: 298, height: 16).at(x: 1, y: 1)
            Text("Signature Preview").font(.system(size: 11)).foregroundStyle(Self.stripText).fixedSize()
                .at(centreX: 150, baseline: 13)
            PreviewPage(text: text ?? NSAttributedString())
                .frame(width: 296, height: 134)
                .at(x: 2, y: 18)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Signature Preview")
    }
}

/// The page itself: a read-only text view in the light appearance, so text in the automatic
/// colour is dark on it as it is in the message that goes out.
private struct PreviewPage: NSViewRepresentable {
    let text: NSAttributedString

    final class Coordinator { var canvas: SignatureCanvas? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.appearance = NSAppearance(named: .aqua)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = true
        view.backgroundColor = .white
        // The first line's text eight points in and its baseline twenty-one points down.
        view.textContainerInset = NSSize(width: 3, height: 7.5)
        view.setAccessibilityLabel("Signature Preview")
        // Shown at its own size, never squeezed into the box: what does not fit scrolls.
        context.coordinator.canvas = SignatureCanvas(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage, !storage.isEqual(to: text) else { return }
        storage.setAttributedString(text)
        context.coordinator.canvas?.fit()
        view.scroll(.zero)
    }
}
