import AppKit
import SwiftUI
import FalconCore

/// The message list as a table that draws only the rows on screen, so a folder of 200,000 messages
/// scrolls as smoothly as one of fifty. Each cell holds the list's own row, `MessageRowView`,
/// given a model by `RowModelAdapter`; when a cell is reused only its model changes. Every answer
/// the table needs, a row's height, kind or text, comes at once from the controller, which never
/// waits: a row without its text yet is drawn grey and fills in when the text arrives.
///
/// Not yet in the window: the list the owner sees is still `MessageListView`'s. The Gmail engine's
/// integration swaps it in.
struct MessageTableView: NSViewRepresentable {
    let controller: ListController
    var showsPreview = true
    /// Sent and Drafts name who the mail went to, as Outlook's do.
    var namesRecipients = false
    var quickActions: [QuickAction] = []
    var categories: (RowKey) -> [NSColor] = { _ in [] }
    /// Double-click, Return and Command-O, with the row's key.
    var onOpen: (RowKey) -> Void = { _ in }
    var onQuickAction: (QuickAction, RowKey) -> Void = { _, _ in }
    /// The menu for the rows a right-click acts on.
    var menu: (ListSelection) -> NSMenu? = { _ in nil }
    var onSelectionChange: (ListSelection) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MessageTableContainer {
        let container = MessageTableContainer()
        context.coordinator.attach(container)
        return container
    }

    func updateNSView(_ container: MessageTableContainer, context: Context) {
        let coordinator = context.coordinator
        let old = coordinator.parent
        coordinator.parent = self
        // Reading the footers here lets SwiftUI update the view when they change.
        container.setFooters(controller.footers.map(\.text))
        if old.showsPreview != showsPreview || old.namesRecipients != namesRecipients || old.quickActions != quickActions {
            coordinator.showsPreviewChanged()
        }
    }

    /// Whatever it is offered: the table scrolls, and its lines wrap, so nothing inside it may
    /// widen the list.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTableContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? OL.listWidth, height: proposal.height ?? 600)
    }

    static func dismantleNSView(_ container: MessageTableContainer, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: MessageTableView
        private weak var container: MessageTableContainer?
        private var table: MessageNSTableView? { container?.table }
        private var scrollObserver: NSObjectProtocol?
        private var keyObservers: [NSObjectProtocol] = []
        private var hoveredRow = -1
        /// Set while the table itself changes the selection, so the change is not sent back.
        private var applying = false

        init(_ parent: MessageTableView) {
            self.parent = parent
        }

        var controller: ListController { parent.controller }

        func attach(_ container: MessageTableContainer) {
            self.container = container
            let table = container.table
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.doubleAction = #selector(doubleClicked)
            table.events = self
            controller.onChange = { [weak self] change in self?.apply(change) }
            let clip = container.scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrolled() }
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self, let window = note.object as? NSWindow, window === self.table?.window else { return }
                        self.refreshVisible()
                    }
                })
            }
            table.reloadData()
        }

        func detach() {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
            keyObservers = []
            controller.onChange = nil
        }

        func showsPreviewChanged() {
            guard let table else { return }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
            refreshVisible()
        }

        // MARK: Changes from the controller

        private func apply(_ change: ListControllerChange) {
            guard let table else { return }
            switch change {
            case .reload:
                applying = true
                table.reloadData()
                table.selectRowIndexes(controller.selection.indexes(in: controller.snapshot), byExtendingSelection: false)
                applying = false
                hoveredRow = -1
                scrolled()
            case .diff(let diff):
                applying = true
                table.beginUpdates()
                if !diff.removed.isEmpty { table.removeRows(at: diff.removed, withAnimation: .effectFade) }
                if !diff.inserted.isEmpty { table.insertRows(at: diff.inserted, withAnimation: .effectFade) }
                table.endUpdates()
                if !diff.reloaded.isEmpty {
                    table.noteHeightOfRows(withIndexesChanged: diff.reloaded)
                    for row in diff.reloaded { configure(row: row) }
                }
                applying = false
            case .content(let keys):
                let visible = table.rows(in: table.visibleRect)
                for row in visible.lowerBound..<(visible.lowerBound + visible.length) {
                    let record = controller.record(at: row)
                    // A child row's text is its conversation's, which may be what arrived.
                    if record?.displayKind == .child || controller.key(at: row).map(keys.contains) == true { configure(row: row) }
                }
            }
        }

        private func scrolled() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            controller.scrolled(visible: visible.lowerBound..<(visible.lowerBound + visible.length))
        }

        /// Draws the rows on screen again, as after the list gains or loses the keyboard.
        func refreshVisible() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            for row in visible.lowerBound..<(visible.lowerBound + visible.length) { configure(row: row) }
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { controller.snapshot.rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard let record = controller.record(at: row) else { return OL.listRow }
            return MessageTableView.height(of: record, showsPreview: parent.showsPreview)
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("MessageTableRow")
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? MessageTableRowView { return reused }
            let rowView = MessageTableRowView()
            rowView.identifier = id
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let record = controller.record(at: row) else { return nil }
            if record.displayKind == .header {
                let id = NSUserInterfaceItemIdentifier("MessageTableHeader")
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? MessageTableHeaderCell ?? {
                    let made = MessageTableHeaderCell()
                    made.identifier = id
                    return made
                }()
                cell.title = controller.header(at: row) ?? ""
                return cell
            }
            let id = NSUserInterfaceItemIdentifier("MessageTableCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? MessageTableCell ?? {
                let made = MessageTableCell()
                made.identifier = id
                made.onAction = { [weak self] action, cell in self?.quickAction(action, from: cell) }
                made.onToggle = { [weak self] cell in self?.toggle(row: cell.row) }
                return made
            }()
            fill(cell, row: row, record: record)
            return cell
        }

        private func configure(row: Int) {
            guard let table, row >= 0, row < table.numberOfRows, let record = controller.record(at: row) else { return }
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell {
                fill(cell, row: row, record: record)
            } else if let header = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableHeaderCell {
                header.title = controller.header(at: row) ?? ""
            }
        }

        private func fill(_ cell: MessageTableCell, row: Int, record: DisplayRecord) {
            guard let table else { return }
            let selected = table.isRowSelected(row)
            let keyboard = table.window?.isKeyWindow == true && table.window?.firstResponder === table
            let selection: MessageRowModel.Selection = selected ? (keyboard || MessageTableView.snapshotHasKeyboard ? .focused : .unfocused) : .none
            let key = controller.key(at: row)
            let hovered = row == hoveredRow && record.displayKind != .child
            let actions = hovered ? parent.quickActions : []
            let shown = RowModelAdapter.row(
                record, content: controller.rowContent(at: row), selection: selection, showsPreview: parent.showsPreview,
                namesRecipients: parent.namesRecipients, categories: key.map(parent.categories) ?? [],
                actionsWidth: MessageTableCell.actionsWidth(actions.count), isLastChild: controller.isLastChild(row))
            // Nobody can act on a row he cannot read, so a grey row has no quick actions.
            cell.show(shown, actions: shown.isPlaceholder ? [] : actions, row: row,
                      folder: record.displayKind == .child && !shown.isPlaceholder ? controller.childFolderName(at: row) : nil,
                      toggle: record.displayKind == .conversation
                          ? (record.displayBits.contains(.expanded) ? "Collapse conversation" : "Expand conversation") : nil)
        }

        // MARK: Selection

        func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
            proposed.filteredIndexSet { controller.record(at: $0)?.displayKind != .header }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table else { return }
            let rows = table.selectedRowIndexes
            let messageRows = controller.snapshot.rows.lazy.filter { $0.displayKind != .header }.count
            let selection = rows.count == messageRows && messageRows > 0 ? ListSelection.all() : ListSelection(rows: rows)
            controller.setSelection(selection)
            parent.onSelectionChange(selection)
            refreshVisible()
        }

        // MARK: Events

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0, let key = controller.key(at: table.clickedRow) else { return }
            parent.onOpen(key)
        }

        func openSelected() {
            guard let table, let row = table.selectedRowIndexes.first, let key = controller.key(at: row) else { return }
            parent.onOpen(key)
        }

        func toggle(row: Int) {
            Task { await controller.toggleExpanded(row: row) }
        }

        /// Right arrow opens the selected conversation out; left closes it, from any of its rows.
        func expandSelected(_ open: Bool) -> Bool {
            guard let table, table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first,
                  let record = controller.record(at: row) else { return false }
            let target = record.displayKind == .child ? controller.parentRow(of: row) : row
            guard let target, controller.record(at: target)?.displayKind == .conversation,
                  controller.isExpanded(target) != open else { return false }
            if record.displayKind == .child { table.selectRowIndexes([target], byExtendingSelection: false) }
            toggle(row: target)
            return true
        }

        func isChevron(row: Int, at point: NSPoint) -> Bool {
            controller.record(at: row)?.displayKind == .conversation && point.x < MessageTableView.chevronWidth
        }

        func hover(row: Int) {
            guard row != hoveredRow else { return }
            let old = hoveredRow
            hoveredRow = row
            configure(row: old)
            configure(row: row)
        }

        func menu(forRow row: Int) -> NSMenu? {
            guard let table, row >= 0 else { return nil }
            if !table.isRowSelected(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
            return parent.menu(controller.selection)
        }

        private func quickAction(_ action: QuickAction, from cell: MessageTableCell) {
            guard let key = controller.key(at: cell.row) else { return }
            parent.onQuickAction(action, key)
        }
    }

    // MARK: - Measures

    /// The chevron's button over the drawn chevron at a conversation's left end.
    static let chevronWidth: CGFloat = 26
    static let headerHeight: CGFloat = 30

    /// Four fixed heights, answered from the row's kind alone.
    static func height(of record: DisplayRecord, showsPreview: Bool) -> CGFloat {
        switch record.displayKind {
        case .header: return headerHeight
        case .child: return OL.listChildRow
        case .conversation, .message:
            let opened = record.displayKind == .conversation && record.displayBits.contains(.expanded)
            return showsPreview && !opened ? OL.listRow : OL.listRowShort
        }
    }

    #if DEBUG
    /// Set by the offscreen snapshots, whose window never has the keyboard.
    static var snapshotHasKeyboard = false
    #else
    static let snapshotHasKeyboard = false
    #endif
}

// MARK: - The views

/// The table, and the lines under its rows.
final class MessageTableContainer: NSView {
    let scrollView = NSScrollView()
    let table = MessageNSTableView()
    private let footer = NSStackView()
    private var footerHeight: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = OLListColor.background
        table.gridStyleMask = []
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = OLListColor.background
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 2
        footer.edgeInsets = NSEdgeInsets(top: 6, left: OL.listSeparatorX, bottom: 6, right: OL.listSeparatorX)
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        footerHeight = footer.heightAnchor.constraint(equalToConstant: 0)
        footerHeight?.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The lines under the rows: that rows are loading, or that older mail is on Gmail.
    func setFooters(_ lines: [String]) {
        let shown = footer.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
        guard shown != lines else { return }
        for view in footer.arrangedSubviews { view.removeFromSuperview() }
        for line in lines {
            // One sentence each, wrapping once in a narrow list rather than losing its end.
            let label = NSTextField(wrappingLabelWithString: line)
            label.font = .systemFont(ofSize: OL.statusFont)
            label.textColor = OLListColor.secondary
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = true
            label.toolTip = line
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.preferredMaxLayoutWidth = max(0, bounds.width - 2 * OL.listSeparatorX)
            footer.addArrangedSubview(label)
        }
        footerHeight?.isActive = lines.isEmpty
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 2 * OL.listSeparatorX)
        var changed = false
        for case let label as NSTextField in footer.arrangedSubviews where label.preferredMaxLayoutWidth != width {
            label.preferredMaxLayoutWidth = width
            label.invalidateIntrinsicContentSize()
            changed = true
        }
        // The lines' heights follow their width, which is known only now.
        if changed { super.layout() }
    }
}

/// Events the table passes to its coordinator.
@MainActor
protocol MessageTableEvents: AnyObject {
    func openSelected()
    func toggle(row: Int)
    func expandSelected(_ open: Bool) -> Bool
    func isChevron(row: Int, at point: NSPoint) -> Bool
    func hover(row: Int)
    func menu(forRow row: Int) -> NSMenu?
    func refreshVisible()
}

extension MessageTableView.Coordinator: MessageTableEvents {}

final class MessageNSTableView: NSTableView {
    weak var events: MessageTableEvents?
    private var tracking: NSTrackingArea?

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        switch event.keyCode {
        case 36, 76:
            // Return opens the selected message in its own window, as a double-click does.
            events?.openSelected()
            return
        case 124:
            if events?.expandSelected(true) == true { return }
        case 123:
            if events?.expandSelected(false) == true { return }
        default:
            if command, event.charactersIgnoringModifiers == "o" {
                events?.openSelected()
                return
            }
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // The chevron opens or closes the conversation and leaves the selection alone.
        if row >= 0, events?.isChevron(row: row, at: point) == true, event.clickCount == 1 {
            events?.toggle(row: row)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return events?.menu(forRow: row)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        events?.hover(row: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        events?.hover(row: -1)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        events?.refreshVisible()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        events?.refreshVisible()
        return resigned
    }
}

/// Draws nothing of its own: the row draws Outlook's selection itself.
final class MessageTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A date or sort group's title, as the list draws its groups.
final class MessageTableHeaderCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set { if label.stringValue != newValue { label.stringValue = newValue } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = OLListColor.background.cgColor
        label.font = .systemFont(ofSize: OL.listLineFont, weight: .semibold)
        label.textColor = OLListColor.text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OL.listSeparatorX),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -OL.listSeparatorX),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateLayer() {
        layer?.backgroundColor = OLListColor.background.cgColor
    }
}

/// One row of the list: the list's own drawn row, grey bars over it while its text is on its way,
/// the quick actions over its icons while the pointer is on it, and, on a message of an opened
/// conversation filed elsewhere, such as the owner's reply in Sent, that folder's name in the room
/// right of its date, where Outlook names it.
final class MessageTableCell: NSTableCellView {
    private let rowView = MessageRowView(model: MessageRowModel(sender: "", date: ""))
    private let bars = PlaceholderBars()
    private let folder = NSTextField(labelWithString: "")
    private var folderX: NSLayoutConstraint?
    private let actions = NSStackView()
    private var shownActions: [QuickAction] = []
    private(set) var row = -1
    var onAction: ((QuickAction, MessageTableCell) -> Void)?
    /// Opens or closes the row's conversation, for VoiceOver, since the chevron is drawn.
    var onToggle: ((MessageTableCell) -> Void)?

    static let actionButton = CGSize(width: 18, height: 16)
    static let actionSpacing: CGFloat = 6

    static func actionsWidth(_ count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * actionButton.width + CGFloat(count - 1) * actionSpacing
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [rowView, bars] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
        }
        folder.font = .systemFont(ofSize: OL.listTextFont)
        folder.textColor = OLListColor.secondary
        folder.lineBreakMode = .byTruncatingTail
        folder.isHidden = true
        folder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(folder)
        let folderX = folder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OL.listChildDateEnd + OL.listDateGap)
        self.folderX = folderX
        NSLayoutConstraint.activate([
            folderX,
            folder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -OL.listTextRight),
            folder.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: OL.listChildBaseline)
        ])
        actions.orientation = .horizontal
        actions.spacing = Self.actionSpacing
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)
        NSLayoutConstraint.activate([
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OL.listIconRight),
            actions.topAnchor.constraint(equalTo: topAnchor, constant: OL.listBadgeTop - 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ shown: RowModelAdapter.Row, actions wanted: [QuickAction], row: Int, folder name: String? = nil,
              toggle: String? = nil) {
        self.row = row
        if let toggle {
            setAccessibilityCustomActions([NSAccessibilityCustomAction(name: toggle) { [weak self] in
                guard let self else { return false }
                self.onToggle?(self)
                return true
            }])
        } else if accessibilityCustomActions()?.isEmpty == false {
            setAccessibilityCustomActions([])
        }
        rowView.model = shown.model
        folder.isHidden = name == nil
        if let name, folder.stringValue != name { folder.stringValue = name }
        folder.textColor = shown.model.selection == .focused ? OLListColor.unread : OLListColor.secondary
        bars.bars = shown.isPlaceholder ? RowModelAdapter.placeholderBars(for: shown.model, width: bounds.width > 0 ? bounds.width : OL.listWidth) : []
        bars.isHidden = !shown.isPlaceholder
        let spoken = MessageTableCell.spoken(shown.model) + (name.map { ", in " + $0 } ?? "")
        setAccessibilityLabel(shown.isPlaceholder ? "Loading" : spoken)
        guard wanted != shownActions else { return }
        shownActions = wanted
        for view in actions.arrangedSubviews { view.removeFromSuperview() }
        for action in wanted {
            let button = NSButton(image: NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) ?? NSImage(),
                                  target: self, action: #selector(tapped(_:)))
            button.isBordered = false
            button.contentTintColor = OLListColor.secondary
            button.tag = QuickAction.allCases.firstIndex(of: action) ?? 0
            button.widthAnchor.constraint(equalToConstant: Self.actionButton.width).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.actionButton.height).isActive = true
            actions.addArrangedSubview(button)
        }
    }

    override func layout() {
        super.layout()
        // The date column ends where the list's row puts it, which a narrow list moves left.
        folderX?.constant = min(OL.listChildDateEnd, bounds.width - OL.listTextRight) + OL.listDateGap
        if !bars.isHidden {
            bars.bars = RowModelAdapter.placeholderBars(for: rowView.model, width: bounds.width)
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        guard QuickAction.allCases.indices.contains(sender.tag) else { return }
        onAction?(QuickAction.allCases[sender.tag], self)
    }

    /// What VoiceOver reads for a row that is drawn rather than made of text views.
    static func spoken(_ row: MessageRowModel) -> String {
        var parts = [row.sender]
        if !row.subject.isEmpty { parts.append(row.subject) }
        parts.append(row.date)
        if row.isUnread { parts.append("unread") }
        if row.hasAttachments { parts.append("has attachments") }
        if row.isFlagged { parts.append("flagged") }
        if let preview = row.preview, !preview.isEmpty { parts.append(preview) }
        return parts.joined(separator: ", ")
    }
}

/// Grey bars where a row's words will be, the placeholder's text.
final class PlaceholderBars: NSView {
    var bars: [CGRect] = [] {
        didSet { if bars != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !bars.isEmpty else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            OLListColor.secondary.withAlphaComponent(0.28).setFill()
            for bar in bars {
                NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
            }
        }
    }
}
