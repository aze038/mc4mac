import SwiftUI
import AppKit
import FalconCore

/// Legacy Outlook's address completion under a recipient field: a popover whose arrow points up
/// at the field, headed Contacts and Recent Addresses, a row to an address with its name, the
/// address and the contact list's label, and a button that forgets an address known only from
/// mail sent. It is a borderless child window hung from the view this sits behind, so it floats
/// over the header band and the message body without moving either. It never takes the
/// keyboard: the field goes on receiving the typing, and Down, Up, Return, Tab and Escape are
/// read on their way to it while the list is open.
struct RecipientSuggestions: NSViewRepresentable {
    static let maxRows = 8

    let rows: [RecipientSuggestion]
    /// What the field holds; its last fragment is what the rows would replace.
    let text: String
    /// Hands over the field's text with a row in place of the fragment; the list is already shut.
    let accept: (String) -> Void
    let dismiss: () -> Void
    /// Forgets a recent address; the field works the rows out again.
    let remove: (RecipientSuggestion) -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.text = text
        view.accept = accept
        view.dismiss = dismiss
        view.remove = remove
        view.show(rows, for: RecipientText.lastFragment(of: text))
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.show([], for: "")
    }

    /// Where the middle of row `row`, counted from one, stands in a list window `height` points
    /// tall, measured up from its foot as AppKit measures.
    static func rowMidY(_ row: Int, inPanelOfHeight height: CGFloat) -> CGFloat {
        height - SuggestionLook.listTop - (CGFloat(row) - 0.5) * SuggestionLook.rowHeight
    }

    /// Where a list window `size` points big goes under a field whose box is `box`, both in the
    /// coordinates of the field's window: as Outlook hangs it, the arrow's tip five points below
    /// the box and the body fifteen points in from its left, counted from the outside of the
    /// box's border, which straddles the box's edge and so ends half a point beyond it.
    static func panelFrame(under box: NSRect, size: NSSize) -> NSRect {
        let outside = box.insetBy(dx: -SuggestionLook.boxBorderOutside, dy: -SuggestionLook.boxBorderOutside)
        return NSRect(x: outside.minX + SuggestionLook.bodyX, y: outside.minY - SuggestionLook.drop - size.height,
                      width: size.width, height: size.height)
    }

    final class AnchorView: NSView {
        var text = ""
        var accept: (String) -> Void = { _ in }
        var dismiss: () -> Void = {}
        var remove: (RecipientSuggestion) -> Void = { _ in }
        private var rows: [RecipientSuggestion] = []
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

        func show(_ list: [RecipientSuggestion], for typed: String) {
            guard list != rows || typed != fragment else { return }
            rows = list
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
            rows = []
            highlighted = nil
            chosen = false
            hide()
        }

        /// Puts the row's address in place of the fragment. The field editor is given the new
        /// text at once with the caret at its end, as typing would leave it, so keys queued behind
        /// this one follow the recipient instead of landing on the text it replaced.
        private func take(_ row: RecipientSuggestion) {
            let editor = fieldEditor
            let completed = RecipientText.completing(editor?.string ?? text, with: row.address)
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
            panel?.list.rootView = SuggestionList(rows: rows, highlighted: highlighted,
                                                  accept: { [weak self] in self?.take($0) },
                                                  highlight: { [weak self] in self?.highlight($0) },
                                                  remove: { [weak self] in self?.remove($0) })
        }

        private func highlight(_ index: Int) {
            guard rows.indices.contains(index), index != highlighted else { return }
            highlighted = index
            render()
        }

        private func reposition() {
            guard let panel, panel.isVisible, let window else { return }
            place(panel, in: window)
        }

        private func place(_ panel: SuggestionPanel, in window: NSWindow) {
            let frame = RecipientSuggestions.panelFrame(under: convert(bounds, to: nil), size: panel.list.fittingSize)
            panel.setFrame(window.convertToScreen(frame), display: true)
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
            guard !rows.isEmpty, event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
                  let editor = fieldEditor else { return false }
            // An input method composing a character owns Return and Escape until it is done.
            if editor.hasMarkedText() { return false }
            switch event.keyCode {
            case KeyRouter.Code.downArrow:
                chosen = true
                highlight(highlighted.map { min($0 + 1, rows.count - 1) } ?? 0)
            case KeyRouter.Code.upArrow:
                chosen = true
                highlight(highlighted.map { max($0 - 1, 0) } ?? 0)
            case KeyRouter.Code.returnKey, KeyRouter.Code.keypadEnter, KeyRouter.Code.tab:
                // A whole address typed or pasted stays as it is unless the arrows picked another
                // row; the key goes on to the field instead, so Tab moves to the next one.
                guard let row = highlighted,
                      chosen || RecipientText.mayComplete(RecipientText.lastFragment(of: editor.string), with: rows[row].email)
                else { return false }
                take(rows[row])
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

/// The popover measured off Outlook's (2x, dark): hung with its arrow's tip five points under the
/// To box, a 486 point body with a one point border, its arrow ten points tall on a seventeen
/// point base, then inside it a 27 point header band and 27 point rows, their text in 13 points
/// with its capitals from 6.5 points down.
enum SuggestionLook {
    static let drop: CGFloat = 5
    /// How far a header field's one point border reaches outside its box.
    static let boxBorderOutside: CGFloat = 0.5
    static let bodyX: CGFloat = 15
    static let bodyWidth: CGFloat = 486
    static let arrowHeight: CGFloat = 10
    static let arrowTipX: CGFloat = 14.5
    static let arrowBase: CGFloat = 17
    static let corner: CGFloat = 2
    static let border: CGFloat = 1
    static let insetX: CGFloat = 3
    static let insetTop: CGFloat = 10
    static let insetBottom: CGFloat = 5
    static let rowHeight: CGFloat = 27
    /// Outlook's list stops this far short of its last row, which it cuts off.
    static let lastRowCut: CGFloat = 5
    static let font: CGFloat = 13
    static let textTop: CGFloat = 3.5
    static let headerTextX: CGFloat = 25
    static let nameX: CGFloat = 33
    static let nameWidth: CGFloat = 180.5
    static let addressX: CGFloat = 236.5
    static let addressWidth: CGFloat = 180
    static let labelInset: CGFloat = 5.5
    static let removeSize: CGFloat = 13
    /// The remove button's circle ends five points in from the rows' right edge, centred on its
    /// row; the symbol's own margin takes a point and a half of that and sets it half a point low.
    static let removeInset: CGFloat = 3.5
    static let removeLift: CGFloat = 0.5

    /// From the window's top to the first row: the arrow, the body's inset and the header.
    static var listTop: CGFloat { arrowHeight + insetTop + rowHeight }

    static let fill = OLColor.dynamic(light: 0xE9E9E9, dark: 0x323232)
    static let line = OLColor.dynamic(light: 0xC4C4C4, dark: 0x424242)
    static let header = OLColor.dynamic(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let row = OLColor.dynamic(light: 0xF5F5F5, dark: 0x3C3C3C)
    static let selected = OLColor.dynamic(light: 0x0064E1, dark: 0x2458CA)
    static let text = OLColor.dynamic(light: 0x000000, dark: 0xFFFFFF)
    static let removeGlyph = OLColor.dynamic(light: 0x8C8C8C, dark: 0xB8B8B8)
}

/// A child window that never becomes key, so the field it hangs from keeps the caret.
private final class SuggestionPanel: NSPanel {
    let list = FirstClickHostingView(rootView: SuggestionList(rows: [], highlighted: nil, accept: { _ in }, highlight: { _ in },
                                                              remove: { _ in }))

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        list.sizingOptions = [.intrinsicContentSize]
        contentView = list
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a row of a window that is not key still picks the row.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Outlook's list: the header, then a row to an address, the highlighted one blue with white
/// text. The rows sit in a frame that stops short of the last one, as Outlook's does.
struct SuggestionList: View {
    let rows: [RecipientSuggestion]
    let highlighted: Int?
    let accept: (RecipientSuggestion) -> Void
    let highlight: (Int) -> Void
    let remove: (RecipientSuggestion) -> Void

    private typealias Look = SuggestionLook

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line("Contacts and Recent Addresses", weight: .bold)
                .foregroundStyle(Look.text)
                .padding(.leading, Look.headerTextX)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Look.header)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    self.row(row, highlighted: index == highlighted)
                        .onHover { if $0 { highlight(index) } }
                        .onTapGesture { accept(row) }
                }
            }
            .frame(height: max(CGFloat(rows.count) * Look.rowHeight - Look.lastRowCut, 0), alignment: .top)
            .clipped()
        }
        .padding(.top, Look.arrowHeight + Look.insetTop)
        .padding(.bottom, Look.insetBottom)
        .padding(.horizontal, Look.insetX)
        .frame(width: Look.bodyWidth)
        .background {
            PopoverOutline().fill(Look.fill)
            PopoverOutline().stroke(Look.line, lineWidth: Look.border)
        }
    }

    /// A line of the list's text, placed in its 27 point row as Outlook places it.
    private func line(_ string: String, weight: Font.Weight = .regular) -> some View {
        Text(string)
            .font(.system(size: Look.font, weight: weight))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.top, Look.textTop)
            .frame(height: Look.rowHeight, alignment: .top)
    }

    private func row(_ row: RecipientSuggestion, highlighted: Bool) -> some View {
        HStack(spacing: 0) {
            line(row.name.isEmpty ? row.email : row.name)
                .frame(width: Look.nameWidth, alignment: .leading)
            line(row.email)
                .frame(width: Look.addressWidth, alignment: .leading)
                .padding(.leading, Look.addressX - Look.nameX - Look.nameWidth)
            Spacer(minLength: 0)
            if row.isRecentAddress {
                Button { remove(row) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Look.removeSize, weight: .bold))
                        .foregroundStyle(Look.removeGlyph)
                }
                .buttonStyle(.plain)
                .help("Remove from Recent Addresses")
                .padding(.trailing, Look.removeInset)
                .offset(y: -Look.removeLift)
            } else if !row.label.isEmpty {
                line(row.label)
                    .padding(.trailing, Look.labelInset)
            }
        }
        .foregroundStyle(highlighted ? Color.white : Look.text)
        .padding(.leading, Look.nameX)
        .frame(maxWidth: .infinity, minHeight: Look.rowHeight, maxHeight: Look.rowHeight)
        .background(highlighted ? Look.selected : Look.row)
        .contentShape(Rectangle())
    }
}

/// The popover's edge: a rectangle with slightly rounded corners and the arrow rising from its
/// top, drawn half a point in so a one point line along it stays inside the window.
private struct PopoverOutline: Shape {
    func path(in rect: CGRect) -> Path {
        typealias Look = SuggestionLook
        let box = rect.insetBy(dx: Look.border / 2, dy: Look.border / 2)
        let top = rect.minY + Look.arrowHeight + Look.border / 2
        let tip = CGPoint(x: rect.minX + Look.arrowTipX, y: rect.minY + Look.border / 2)
        let half = Look.arrowBase / 2
        let r = Look.corner
        var path = Path()
        path.move(to: CGPoint(x: box.minX + r, y: top))
        path.addLine(to: CGPoint(x: tip.x - half, y: top))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x + half, y: top))
        path.addLine(to: CGPoint(x: box.maxX - r, y: top))
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: top), tangent2End: CGPoint(x: box.maxX, y: box.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: top), radius: r)
        path.addArc(tangent1End: CGPoint(x: box.minX, y: top), tangent2End: CGPoint(x: box.maxX, y: top), radius: r)
        path.closeSubpath()
        return path
    }
}
