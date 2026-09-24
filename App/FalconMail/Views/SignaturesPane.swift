import SwiftUI
import AppKit
import FalconCore

/// Legacy Outlook's Signatures pane: the signatures by name with + and − under the list, the
/// selected one's preview beside it, and each account's defaults below.
struct SignaturesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var accountID: UUID?
    @State private var removing: Signature?

    private var library: SignatureLibrary { model.signatures }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit signature:")
                .font(.system(size: 13, weight: .bold))
                .padding(.bottom, SignaturesMetrics.headingGap)
            HStack(alignment: .top, spacing: SignaturesMetrics.boxGap) {
                // The buttons' top edge lies on the list's bottom edge, one line for both.
                VStack(alignment: .leading, spacing: -1) {
                    SignatureTable(signatures: library.sorted, selection: $selection,
                                   open: { edit($0) }, remove: { askToRemove() })
                        .frame(width: SignaturesMetrics.listWidth, height: SignaturesMetrics.boxHeight)
                    AddRemoveButtons(canRemove: selection != nil, add: { add() }, remove: { askToRemove() })
                        .frame(width: AddRemoveButtons.width, height: AddRemoveButtons.height)
                }
                SignaturePreview(text: library.signature(selection).map(previewText))
                    .frame(maxWidth: .infinity)
                    .frame(height: SignaturesMetrics.boxHeight)
            }
            Divider()
                .padding(.top, SignaturesMetrics.sectionGap)
                .padding(.bottom, SignaturesMetrics.sectionGap)
            Text("Choose default signature:")
                .font(.system(size: 13, weight: .bold))
                .padding(.bottom, SignaturesMetrics.headingGap + 4)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: SignaturesMetrics.rowGap) {
                GridRow {
                    label("Account:")
                    PopUpField(title: "Account:", items: model.accounts.map { ($0.email, Optional($0.id)) },
                               selection: accountBinding)
                        .frame(width: SignaturesMetrics.accountPopup)
                }
                GridRow {
                    label("New messages:")
                    defaultPopup(.newMessages, title: "New messages:")
                }
                GridRow {
                    label("Replies/forwards:")
                    defaultPopup(.replies, title: "Replies/forwards:")
                }
            }
            .disabled(model.accounts.isEmpty)
        }
        .padding(.horizontal, SignaturesMetrics.inset)
        .padding(.top, SignaturesMetrics.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(removing.map { "Delete the signature “\($0.name)”?" } ?? "",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { signature in
            Button("Delete", role: .destructive) { remove(signature) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Accounts that use it will have no signature. You can’t undo this.")
        }
        .onAppear {
            if selection == nil { selection = library.sorted.first?.id }
            if accountID == nil { accountID = model.accounts.first?.id }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .frame(width: SignaturesMetrics.labelWidth, alignment: .trailing)
            .gridColumnAlignment(.trailing)
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
        return PopUpField(title: title, items: items, selection: Binding(
            get: { account.flatMap { library.book.defaultID(for: $0, use) } },
            set: { id in if let account { library.setDefault(id, for: account, use) } }))
            .frame(width: SignaturesMetrics.defaultPopup)
    }

    private func add() {
        let signature = library.add()
        selection = signature.id
        edit(signature.id)
    }

    private func edit(_ id: UUID) {
        SignatureEditorWindows.shared.open(id, library: library)
    }

    private func askToRemove() {
        removing = library.signature(selection)
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

/// The pane's measures: an AppKit preference pane's twenty point margins, the list and preview
/// the same height side by side, popups at the widths their longest usual entries need.
enum SignaturesMetrics {
    static let inset: CGFloat = 20
    static let top: CGFloat = 18
    static let headingGap: CGFloat = 8
    static let boxGap: CGFloat = 20
    static let listWidth: CGFloat = 220
    static let boxHeight: CGFloat = 200
    static let sectionGap: CGFloat = 18
    static let rowGap: CGFloat = 10
    static let labelWidth: CGFloat = 150
    static let accountPopup: CGFloat = 300
    static let defaultPopup: CGFloat = 220
}

/// The signature list: an AppKit table in a bordered scroll view with one column headed
/// "Signature name". Double-click and Delete act on a row as Outlook's do.
struct SignatureTable: NSViewRepresentable {
    let signatures: [Signature]
    @Binding var selection: UUID?
    let open: (UUID) -> Void
    let remove: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DeletingTableView()
        let column = NSTableColumn(identifier: Coordinator.column)
        column.title = "Signature name"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.style = .fullWidth
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.onDelete = { [weak coordinator = context.coordinator] in coordinator?.parent.remove() }
        table.setAccessibilityLabel("Signatures")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = scroll.documentView as? NSTableView else { return }
        coordinator.syncing = true
        defer { coordinator.syncing = false }
        let rows = signatures.map { Coordinator.Row(id: $0.id, name: $0.name) }
        if rows != coordinator.rows {
            coordinator.rows = rows
            table.reloadData()
        }
        if let row = rows.firstIndex(where: { $0.id == selection }) {
            if table.selectedRow != row {
                table.selectRowIndexes([row], byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
        } else if table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct Row: Equatable {
            let id: UUID
            let name: String
        }

        static let column = NSUserInterfaceItemIdentifier("name")
        var parent: SignatureTable
        var rows: [Row] = []
        /// Set while the table is brought into line with SwiftUI, whose state must not change
        /// in the middle of an update.
        var syncing = false

        init(_ parent: SignatureTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: Coordinator.column, owner: nil) as? NSTableCellView ?? makeCell()
            cell.textField?.stringValue = rows[row].name
            return cell
        }

        private func makeCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = Coordinator.column
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table = notification.object as? NSTableView else { return }
            let row = table.selectedRow
            parent.selection = rows.indices.contains(row) ? rows[row].id : nil
        }

        @objc func doubleClicked(_ table: NSTableView) {
            let row = table.clickedRow
            guard rows.indices.contains(row) else { return }
            parent.open(rows[row].id)
        }
    }
}

/// A table that hands Delete and Forward Delete on a selected row to its owner.
final class DeletingTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]
        if deleteKeys.contains(event.keyCode), selectedRow >= 0, let onDelete {
            onDelete()
            return
        }
        super.keyDown(with: event)
    }
}

/// The joined + and − under a list: two small square bezel buttons twenty-two points tall
/// sharing their middle edge, as AppKit's preference panes draw them.
struct AddRemoveButtons: NSViewRepresentable {
    static let buttonWidth: CGFloat = 24
    static let height: CGFloat = 22
    static var width: CGFloat { buttonWidth * 2 - 1 }

    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        let plus = button(NSImage.addTemplateName, label: "Add", action: #selector(Coordinator.addPressed(_:)), context: context)
        let minus = button(NSImage.removeTemplateName, label: "Remove", action: #selector(Coordinator.removePressed(_:)), context: context)
        plus.frame = NSRect(x: 0, y: 0, width: Self.buttonWidth, height: Self.height)
        minus.frame = NSRect(x: Self.buttonWidth - 1, y: 0, width: Self.buttonWidth, height: Self.height)
        view.addSubview(plus)
        view.addSubview(minus)
        context.coordinator.minus = minus
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onAdd = add
        context.coordinator.onRemove = remove
        context.coordinator.minus?.isEnabled = canRemove
    }

    private func button(_ image: NSImage.Name, label: String, action: Selector, context: Context) -> NSButton {
        let button = NSButton(image: NSImage(named: image) ?? NSImage(), target: context.coordinator, action: action)
        button.bezelStyle = .smallSquare
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(label)
        return button
    }

    final class Coordinator: NSObject {
        var onAdd: () -> Void = {}
        var onRemove: () -> Void = {}
        weak var minus: NSButton?

        @objc func addPressed(_ sender: Any?) { onAdd() }
        @objc func removePressed(_ sender: Any?) { onRemove() }
    }
}

/// "Signature Preview": the selected signature as it will look, in a bordered box headed the
/// way the list is, by a one-column AppKit table whose single row holds the text.
struct SignaturePreview: NSViewRepresentable {
    let text: NSAttributedString?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preview"))
        column.title = "Signature Preview"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.style = .fullWidth
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.selectionHighlightStyle = .none
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityLabel("Signature Preview")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let shown = text ?? NSAttributedString()
        guard let table = scroll.documentView as? NSTableView, !shown.isEqual(to: context.coordinator.text.textStorage ?? NSAttributedString()) else { return }
        context.coordinator.text.textStorage?.setAttributedString(shown)
        table.noteHeightOfRows(withIndexesChanged: [0])
        table.reloadData()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let text: NSTextView = {
            let view = NSTextView()
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: SignaturePreview.inset, height: SignaturePreview.inset)
            view.isVerticallyResizable = false
            view.setAccessibilityLabel("Signature Preview")
            return view
        }()

        func numberOfRows(in tableView: NSTableView) -> Int { 1 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { text }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
            let storage = NSTextStorage(attributedString: text.textStorage ?? NSAttributedString())
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: max(1, width - 2 * SignaturePreview.inset), height: .greatestFiniteMagnitude))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            return max(ceil(layout.usedRect(for: container).height) + 2 * SignaturePreview.inset, 1)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            (notification.object as? NSTableView)?.noteHeightOfRows(withIndexesChanged: [0])
        }
    }

    static let inset: CGFloat = 6
}

/// An AppKit pop-up button as wide as it is placed, as preference panes size theirs; SwiftUI's
/// menu picker keeps to the width of its current choice.
struct PopUpField<Tag: Hashable>: NSViewRepresentable {
    let title: String
    let items: [(String, Tag)]
    @Binding var selection: Tag

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.chosen(_:))
        button.setAccessibilityLabel(title)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.isEnabled = context.environment.isEnabled
        let coordinator = context.coordinator
        coordinator.tags = items.map(\.1)
        coordinator.choose = { selection = $0 }
        let titles = items.map(\.0)
        if button.itemTitles != titles {
            button.removeAllItems()
            // Added one by one, so two signatures of the same name both stay in the menu.
            for title in titles {
                button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        if let index = items.firstIndex(where: { $0.1 == selection }), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }

    final class Coordinator: NSObject {
        var tags: [Tag] = []
        var choose: (Tag) -> Void = { _ in }

        @objc func chosen(_ button: NSPopUpButton) {
            let index = button.indexOfSelectedItem
            guard tags.indices.contains(index) else { return }
            choose(tags[index])
        }
    }
}
