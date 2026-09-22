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
    /// What the field holds; its last fragment is what the rows would replace.
    let text: String
    /// Hands over the field's text with a row in place of the fragment; the list is already shut.
    let accept: (String) -> Void
    let dismiss: () -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.text = text
        view.accept = accept
        view.dismiss = dismiss
        view.show(contacts, for: RecipientText.lastFragment(of: text))
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.show([], for: "")
    }

    final class AnchorView: NSView {
        var text = ""
        var accept: (String) -> Void = { _ in }
        var dismiss: () -> Void = {}
        private var contacts: [ContactInfo] = []
        private var fragment = ""
        /// The row Return and Tab take. None while the fragment is a whole address that the top
        /// row does not have, so the list never looks as if it will replace what was typed.
        private var highlighted: Int?
        /// Set once the arrow keys move the highlight: a row picked that way is the user's choice,
        /// even over a whole address they typed. Hovering is not a choice.
        private var chosen = false
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

        func show(_ list: [ContactInfo], for typed: String) {
            guard list != contacts || typed != fragment else { return }
            contacts = list
            fragment = typed
            chosen = false
            highlighted = list.first.flatMap { RecipientText.mayComplete(typed, with: $0.email) ? 0 : nil }
            if list.isEmpty { hide() } else { open() }
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

        private func hide() {
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers = []
        }

        /// Empties and hides the list there and then rather than on SwiftUI's next update, so a
        /// key already queued behind the one that closed it finds nothing left to act on.
        private func shut() {
            contacts = []
            highlighted = nil
            chosen = false
            hide()
        }

        /// Puts the contact in place of the fragment. The field editor is given the new text at
        /// once with the caret at its end, as typing would leave it, so keys queued behind this
        /// one follow the recipient instead of landing on the text it replaced.
        private func take(_ contact: ContactInfo) {
            let editor = fieldEditor
            let completed = RecipientText.completing(editor?.string ?? text,
                                                     with: EmailAddress(name: contact.name, address: contact.email))
            shut()
            if let editor {
                let whole = NSRange(location: 0, length: (editor.string as NSString).length)
                if editor.shouldChangeText(in: whole, replacementString: completed) {
                    editor.replaceCharacters(in: whole, with: completed)
                    editor.didChangeText()
                }
                editor.setSelectedRange(NSRange(location: (completed as NSString).length, length: 0))
            }
            accept(completed)
        }

        /// The field editor, while it is editing the field this list hangs from rather than
        /// another one in the same window.
        private var fieldEditor: NSTextView? {
            guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSView else { return nil }
            let box = convert(bounds, to: nil)
            let frame = field.convert(field.bounds, to: nil)
            return box.contains(NSPoint(x: frame.midX, y: frame.midY)) ? editor : nil
        }

        private func render() {
            panel?.list.rootView = SuggestionList(contacts: contacts, highlighted: highlighted,
                                                  accept: { [weak self] in self?.take($0) },
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
                    MainActor.assumeIsolated {
                        self?.shut()
                        self?.dismiss()
                    }
                },
                centre.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reposition() }
                },
            ]
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard !contacts.isEmpty, event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
                  let editor = fieldEditor else { return false }
            // An input method composing a character owns Return and Escape until it is done.
            if editor.hasMarkedText() { return false }
            switch event.keyCode {
            case KeyRouter.Code.downArrow:
                chosen = true
                highlight(highlighted.map { min($0 + 1, contacts.count - 1) } ?? 0)
            case KeyRouter.Code.upArrow:
                chosen = true
                highlight(highlighted.map { max($0 - 1, 0) } ?? 0)
            case KeyRouter.Code.returnKey, KeyRouter.Code.keypadEnter, KeyRouter.Code.tab:
                // A whole address typed or pasted stays as it is unless the arrows picked another
                // row; the key goes on to the field instead, so Tab moves to the next one.
                guard let row = highlighted,
                      chosen || RecipientText.mayComplete(RecipientText.lastFragment(of: editor.string), with: contacts[row].email)
                else { return false }
                take(contacts[row])
            case KeyRouter.Code.escape:
                shut()
                dismiss()
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
    let list = FirstClickHostingView(rootView: SuggestionList(contacts: [], highlighted: nil, accept: { _ in }, highlight: { _ in }))

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
    let highlighted: Int?
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
