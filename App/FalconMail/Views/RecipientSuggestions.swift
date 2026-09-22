import SwiftUI
import AppKit
import FalconCore

/// Legacy Outlook's address completion under a recipient field. The list is a borderless child
/// window hung from the bottom-left corner of the view this sits behind, so it floats over the
/// header band and the message body without moving either. It never takes the keyboard: the
/// field goes on receiving the typing, and Down, Up, Return, Tab and Escape are read on their way
/// to it while the list is open.
struct RecipientSuggestions: NSViewRepresentable {
    static let maxRows = 8
    static let rowHeight: CGFloat = 22
    static let listInset: CGFloat = 3

    let contacts: [ContactInfo]
    let accept: (ContactInfo) -> Void
    let dismiss: () -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.accept = accept
        view.dismiss = dismiss
        view.show(contacts)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.show([])
    }

    final class AnchorView: NSView {
        var accept: (ContactInfo) -> Void = { _ in }
        var dismiss: () -> Void = {}
        private var contacts: [ContactInfo] = []
        private var highlighted = 0
        private var panel: SuggestionPanel?
        private var keyMonitor: Any?
        private var windowObservers: [NSObjectProtocol] = []

        // Sits behind the field, so it must never be what a click lands on.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            reposition()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            reposition()
        }

        func show(_ list: [ContactInfo]) {
            guard list != contacts else { return }
            contacts = list
            highlighted = 0
            if list.isEmpty { close() } else { open() }
        }

        private func open() {
            guard let window else { return }
            let panel = self.panel ?? SuggestionPanel()
            self.panel = panel
            panel.appearance = window.appearance
            render()
            place(panel, in: window)
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
            watch(window)
        }

        private func close() {
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers = []
        }

        private func render() {
            panel?.list.rootView = SuggestionList(contacts: contacts, highlighted: highlighted,
                                                  accept: { [weak self] in self?.accept($0) },
                                                  highlight: { [weak self] in self?.highlight($0) })
        }

        private func highlight(_ index: Int) {
            guard contacts.indices.contains(index), index != highlighted else { return }
            highlighted = index
            render()
        }

        private func reposition() {
            guard let panel, panel.isVisible, let window else { return }
            place(panel, in: window)
        }

        /// Hung from the anchor's bottom-left corner, as wide as the rows want but no wider than the
        /// field. The list sits a point inside the panel, so it starts on the field's left edge a
        /// point below it: its border runs down the field's and meets it under the box.
        private func place(_ panel: SuggestionPanel, in window: NSWindow) {
            let anchor = convert(bounds, to: nil)
            let size = panel.list.fittingSize
            let width = min(max(size.width, SuggestionList.minimumWidth), anchor.width)
            let corner = window.convertPoint(toScreen: NSPoint(x: anchor.minX - 1, y: anchor.minY))
            panel.setFrame(NSRect(x: corner.x, y: corner.y - size.height, width: width, height: size.height), display: true)
        }

        private func watch(_ window: NSWindow) {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                return MainActor.assumeIsolated { self.handle(event) } ? nil : event
            }
            let centre = NotificationCenter.default
            windowObservers = [
                // Focus leaving the window closes the list, as focus leaving the field does.
                centre.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                },
                centre.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reposition() }
                },
            ]
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard !contacts.isEmpty, event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) else { return false }
            // An input method composing a character owns Return and Escape until it is done.
            if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            switch event.keyCode {
            case KeyRouter.Code.downArrow: highlight(min(highlighted + 1, contacts.count - 1))
            case KeyRouter.Code.upArrow: highlight(max(highlighted - 1, 0))
            case KeyRouter.Code.returnKey, KeyRouter.Code.keypadEnter, KeyRouter.Code.tab: accept(contacts[highlighted])
            case KeyRouter.Code.escape: dismiss()
            default: return false
            }
            return true
        }

        deinit {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            windowObservers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// A child window that never becomes key, so the field it hangs from keeps the caret.
private final class SuggestionPanel: NSPanel {
    let list = FirstClickHostingView(rootView: SuggestionList(contacts: [], highlighted: 0, accept: { _ in }, highlight: { _ in }))

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // The anchor reads the rows' size off the list and sets the frame; a list wider than the
        // field is cut short rather than let widen the panel past it.
        list.sizingOptions = [.intrinsicContentSize]
        list.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentView = list
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a row of a window that is not key still picks the row.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Outlook's rows: the name, then the address in the secondary colour; the highlighted row in
/// the accent colour with white text.
private struct SuggestionList: View {
    static let minimumWidth: CGFloat = 280

    let contacts: [ContactInfo]
    let highlighted: Int
    let accept: (ContactInfo) -> Void
    let highlight: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(contacts.enumerated()), id: \.offset) { index, contact in
                row(contact, highlighted: index == highlighted)
                    .onHover { if $0 { highlight(index) } }
                    .onTapGesture { accept(contact) }
            }
        }
        .padding(.vertical, RecipientSuggestions.listInset)
        .background(OLColor.reading)
        // Boxed like the header fields, a one point line centred on the edge, with room in the
        // window for the half of it that falls outside.
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(OLColor.divider, lineWidth: 1))
        .padding(1)
        .themedRoot()
    }

    private func row(_ contact: ContactInfo, highlighted: Bool) -> some View {
        HStack(spacing: 6) {
            Text(contact.name.isEmpty ? contact.email : contact.name)
                .foregroundStyle(highlighted ? Color.white : OLColor.text)
            if !contact.name.isEmpty {
                Text(contact.email)
                    .foregroundStyle(highlighted ? Color.white : OLColor.textMuted)
            }
        }
        .font(.system(size: OL.composeLabelFont))
        .lineLimit(1)
        .padding(.horizontal, OL.composeTextInset)
        .frame(maxWidth: .infinity, minHeight: RecipientSuggestions.rowHeight, alignment: .leading)
        .background(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear))
        .contentShape(Rectangle())
    }
}
