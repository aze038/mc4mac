import AppKit
import SwiftUI
import FalconCore

/// Everything one row of the message list shows, worked out before it is drawn so that drawing
/// only lays out text. The list makes one for each row it shows; a table view can keep them
/// the same way.
struct MessageRowModel: Equatable {
    enum Kind: Equatable {
        /// A conversation's own row, or a lone message's: senders, then subject and date, then
        /// the preview.
        case conversation
        /// One message of an expanded conversation: its sender and date on one short line.
        /// `last` is the conversation's oldest, whose line underneath closes the conversation.
        case child(last: Bool)
    }

    enum Disclosure: Equatable { case none, collapsed, expanded }

    enum Selection: Equatable {
        case none
        /// Selected while the list has the keyboard: Outlook's blue, words and all.
        case focused
        /// Selected while something else has the keyboard, or the window is behind: grey.
        case unfocused
    }

    var kind: Kind = .conversation
    var disclosure: Disclosure = .none
    /// Everyone who wrote in the conversation, or the one message's sender.
    var sender: String
    var subject = ""
    var date: String
    /// Nil leaves the row without a preview line. An empty one keeps the line, blank, so that
    /// the row does not change height when the message's opening words arrive.
    var preview: String?
    var isUnread = false
    /// The count in the grey pill at a conversation's top right; zero shows none.
    var unreadCount = 0
    var hasAttachments = false
    var isFlagged = false
    var categories: [NSColor] = []
    var selection: Selection = .none
    /// How wide the quick actions are while the pointer is on the row and they stand where its
    /// icons were; zero shows the icons.
    var actionsWidth: CGFloat = 0
    /// Roomy, Cozy or Compact, from Message Preview on the ribbon or Settings.
    var density: ListDensity = .cozy

    var height: CGFloat { MessageRowModel.height(kind: kind, hasPreview: preview != nil, density: density) }

    static func height(kind: Kind, hasPreview: Bool, density: ListDensity) -> CGFloat {
        switch kind {
        case .child: return OL.listChildRow
        case .conversation: return (hasPreview ? OL.listRow : OL.listRowShort) + density.extraHeight
        }
    }
}

extension MessageRowModel {
    /// A conversation's own row, or a lone message's. `namesRecipients` names who the mail went
    /// to rather than who sent it, as Outlook does in Sent and Drafts.
    static func conversation(_ thread: MessageThread, expanded: Bool, showsPreview: Bool, selection: Selection,
                             namesRecipients: Bool = false, categories: [NSColor] = [], actionsWidth: CGFloat = 0,
                             density: ListDensity = .cozy, now: Date = Date()) -> MessageRowModel {
        let latest = thread.latest
        let many = thread.messages.count > 1
        let unread = thread.unreadCount
        return MessageRowModel(
            kind: .conversation,
            disclosure: many ? (expanded ? .expanded : .collapsed) : .none,
            sender: namesRecipients ? MessageListText.recipients(thread.messages)
                : many ? MessageListText.participants(thread.messages) : latest.from.displayName,
            subject: latest.subject.isEmpty ? "(no subject)" : latest.subject,
            date: MessageListText.date(latest.date, now: now),
            // An expanded conversation drops its preview, as Outlook's does: its messages follow.
            preview: showsPreview && density.hasPreviewLine && !(many && expanded) ? MessageListText.preview(latest.snippet) : nil,
            isUnread: unread > 0,
            unreadCount: many ? unread : 0,
            hasAttachments: thread.messages.contains { $0.hasAttachments },
            isFlagged: thread.messages.contains { $0.isFlagged },
            categories: categories,
            selection: selection,
            actionsWidth: actionsWidth,
            density: density)
    }

    /// One message of an expanded conversation.
    static func child(_ message: MessageSummary, last: Bool, selection: Selection, namesRecipients: Bool = false,
                      now: Date = Date()) -> MessageRowModel {
        MessageRowModel(kind: .child(last: last),
                        sender: namesRecipients ? MessageListText.recipients([message]) : message.from.displayName,
                        date: MessageListText.date(message.date, now: now), isUnread: !message.isRead,
                        selection: selection)
    }
}

/// Draws one row of the message list as Outlook draws it: with CoreText and font smoothing,
/// which SwiftUI's text cannot turn on and without which every stroke is thinner than
/// Outlook's. It only draws; clicks, hovers and menus belong to whatever holds it, so it never
/// takes an event.
final class MessageRowView: NSView {
    var model: MessageRowModel {
        didSet { if model != oldValue { needsDisplay = true } }
    }

    init(model: MessageRowModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: OL.listWidth, height: model.height))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func viewDidChangeBackingProperties() { needsDisplay = true }

    override func setFrameSize(_ newSize: NSSize) {
        // Dates, counts and icons stand from the right edge.
        if newSize.width != frame.width { needsDisplay = true }
        super.setFrameSize(newSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            MessageRowDrawing(model: model, size: bounds.size, pixel: 1 / max(1, window?.backingScaleFactor ?? 2))
                .draw(in: context)
        }
    }
}

/// One row's drawing, apart from the view so that it holds nothing between draws.
private struct MessageRowDrawing {
    let model: MessageRowModel
    let size: CGSize
    /// One device pixel, the thickness of Outlook's lines between rows.
    let pixel: CGFloat

    private enum Fonts {
        static let sender = NSFont.systemFont(ofSize: OL.listSenderFont, weight: .medium)
        static let text = NSFont.systemFont(ofSize: OL.listTextFont)
        static let unreadSubject = NSFont.boldSystemFont(ofSize: OL.listTextFont)
        static let unreadChild = NSFont.systemFont(ofSize: OL.listTextFont, weight: .medium)
        static let badge = NSFont.boldSystemFont(ofSize: OL.listBadgeFont)
    }

    private static let flag: NSImage? = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [OLListColor.flag])))

    private var focused: Bool { model.selection == .focused }

    func draw(in context: CGContext) {
        let bounds = CGRect(origin: .zero, size: size)
        background.setFill()
        bounds.fill()
        separator()

        context.saveGState()
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(true)
        context.setAllowsAntialiasing(true)
        // The view is flipped; CoreText draws upright only with its own matrix flipped back.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        switch model.kind {
        case .conversation:
            // Roomy and Compact move the whole drawing, chevron, icons and all, down or up by
            // half the height they add or take away.
            context.translateBy(x: 0, y: model.density.textShift)
            drawConversation(in: context)
        case .child: drawChild(in: context)
        }
        context.restoreGState()
    }

    private var background: NSColor {
        switch model.selection {
        case .none: return OLListColor.background
        case .focused: return OLListColor.focusedSelection
        case .unfocused: return OLListColor.selection
        }
    }

    /// The line under the row: set in at both ends, further in between two messages of one
    /// conversation. Outlook's blue selection covers it; its grey one runs it the full width.
    private func separator() {
        let y = size.height - pixel
        switch model.selection {
        case .focused:
            return
        case .unfocused:
            OLListColor.separator.setFill()
            CGRect(x: 0, y: y, width: size.width, height: pixel).fill()
        case .none:
            var left = OL.listSeparatorX
            if case .child(let last) = model.kind, !last { left = OL.listChildSeparatorX }
            OLListColor.separator.setFill()
            CGRect(x: left, y: y, width: max(0, size.width - left - OL.listSeparatorX), height: pixel).fill()
        }
    }

    // MARK: conversation

    private func drawConversation(in context: CGContext) {
        let right = size.width - OL.listTextRight
        let unreadBlue = OLListColor.unread
        let text = focused ? unreadBlue : OLListColor.text
        let secondary = focused ? unreadBlue : OLListColor.secondary

        chevron()

        // Line one: the writers, cut short before the icons or the quick actions at its end.
        let iconsStart = model.actionsWidth > 0 ? size.width - OL.listIconRight - model.actionsWidth : icons(in: context)
        let senderEnd = iconsStart.map { $0 - OL.listSenderGap } ?? size.width - OL.listSenderRight
        let baseline1 = OL.listBaseline
        TextLine(model.sender, font: Fonts.sender, color: text)
            .draw(in: context, x: OL.listTextX, baseline: baseline1, width: senderEnd - OL.listTextX)

        // Line two: the subject, and the date at the end.
        let baseline2 = baseline1 + OL.listLinePitch
        let date = TextLine(model.date, font: Fonts.text, color: model.isUnread ? unreadBlue : secondary)
        let dateX = right - date.width
        date.draw(in: context, x: dateX, baseline: baseline2)
        TextLine(model.subject, font: model.isUnread ? Fonts.unreadSubject : Fonts.text,
                 color: model.isUnread ? unreadBlue : text)
            .draw(in: context, x: OL.listTextX, baseline: baseline2, width: dateX - OL.listDateGap - OL.listTextX)
        if model.isUnread {
            unreadBlue.setFill()
            NSBezierPath(ovalIn: CGRect(x: OL.listDotX - OL.listDot / 2, y: OL.listDotY - OL.listDot / 2,
                                        width: OL.listDot, height: OL.listDot)).fill()
        }

        // Line three: the preview.
        if let preview = model.preview, !preview.isEmpty {
            TextLine(preview, font: Fonts.text, color: secondary)
                .draw(in: context, x: OL.listTextX, baseline: baseline2 + OL.listLinePitch, width: right - OL.listTextX)
        }
    }

    /// Outlook's chevron: a thin stroke, pointing right while the conversation is closed and
    /// down while it is open.
    private func chevron() {
        let points: [CGPoint]
        switch model.disclosure {
        case .none: return
        case .collapsed: points = [CGPoint(x: 9, y: 10.5), CGPoint(x: 13.5, y: 15), CGPoint(x: 9, y: 19.5)]
        case .expanded: points = [CGPoint(x: 6.5, y: 13), CGPoint(x: 11, y: 17.5), CGPoint(x: 15.5, y: 13)]
        }
        let path = NSBezierPath()
        path.move(to: points[0])
        path.line(to: points[1])
        path.line(to: points[2])
        path.lineWidth = 1
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        OLListColor.chevron.setStroke()
        path.stroke()
    }

    /// The count, the flag, the paperclip and the categories, laid from the right; returns where
    /// the leftmost begins, or nil when there are none.
    private func icons(in context: CGContext) -> CGFloat? {
        var start: CGFloat?
        var end = size.width - OL.listClipRight
        if model.unreadCount > 0 {
            let digits = TextLine("\(model.unreadCount)", font: Fonts.badge, color: OLListColor.badgeText)
            let width = digits.width + 2 * OL.listBadgePadding
            let pill = CGRect(x: size.width - OL.listIconRight - width, y: OL.listBadgeTop, width: width, height: OL.listBadgeHeight)
            OLListColor.badge.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            digits.draw(in: context, x: pill.minX + OL.listBadgePadding, baseline: pill.midY + Fonts.badge.capHeight / 2)
            start = pill.minX
            end = pill.minX - OL.listIconGap
        }
        if model.isFlagged, let flag = Self.flag {
            let rect = CGRect(x: end - flag.size.width, y: OL.listBadgeTop + (OL.listBadgeHeight - flag.size.height) / 2,
                              width: flag.size.width, height: flag.size.height)
            flag.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            start = rect.minX
            end = rect.minX - OL.listIconGap
        }
        if model.hasAttachments {
            paperclip(right: end)
            start = end - Paperclip.width
            end = end - Paperclip.width - OL.listIconGap
        }
        for colour in model.categories.reversed() {
            let dot = CGRect(x: end - 8, y: OL.listBadgeTop + 3, width: 8, height: 8)
            colour.setFill()
            NSBezierPath(ovalIn: dot).fill()
            start = dot.minX
            end = dot.minX - 4
        }
        return start
    }

    private enum Paperclip {
        static let width: CGFloat = 8
    }

    /// Outlook's upright paperclip, eight points wide and sixteen and a half tall, drawn with a
    /// one point line: an outer loop open at the top right, an inner one hanging from the top.
    private func paperclip(right: CGFloat) {
        let x = right - Paperclip.width
        let y = OL.listClipTop
        let path = NSBezierPath()
        path.move(to: CGPoint(x: x + 7.5, y: y + 4.25))
        path.line(to: CGPoint(x: x + 7.5, y: y + 12.25))
        path.appendArc(withCenter: CGPoint(x: x + 4, y: y + 12.25), radius: 3.5, startAngle: 0, endAngle: 180, clockwise: false)
        path.line(to: CGPoint(x: x + 0.5, y: y + 3))
        path.appendArc(withCenter: CGPoint(x: x + 3, y: y + 3), radius: 2.5, startAngle: 180, endAngle: 0, clockwise: false)
        path.line(to: CGPoint(x: x + 5.5, y: y + 12))
        path.appendArc(withCenter: CGPoint(x: x + 4, y: y + 12), radius: 1.5, startAngle: 0, endAngle: 180, clockwise: false)
        path.line(to: CGPoint(x: x + 2.5, y: y + 4.25))
        path.lineWidth = 1
        path.lineCapStyle = .butt
        path.lineJoinStyle = .round
        OLListColor.paperclip.setStroke()
        path.stroke()
    }

    // MARK: child

    private func drawChild(in context: CGContext) {
        let unreadBlue = OLListColor.unread
        let blue = focused || model.isUnread
        let date = TextLine(model.date, font: Fonts.text, color: blue ? unreadBlue : OLListColor.secondary)
        let dateEnd = min(OL.listChildDateEnd, size.width - OL.listTextRight)
        let dateX = dateEnd - date.width
        date.draw(in: context, x: dateX, baseline: OL.listChildBaseline)
        TextLine(model.sender, font: model.isUnread ? Fonts.unreadChild : Fonts.text,
                 color: blue ? unreadBlue : OLListColor.childName)
            .draw(in: context, x: OL.listChildTextX, baseline: OL.listChildBaseline,
                  width: dateX - OL.listDateGap - OL.listChildTextX)
    }
}

/// One line of text as CoreText lays it out, cut short with an ellipsis when it is too wide.
private struct TextLine {
    private let line: CTLine
    private let attributes: [NSAttributedString.Key: Any]
    let width: CGFloat

    init(_ string: String, font: NSFont, color: NSColor) {
        attributes = [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]
        line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    func draw(in context: CGContext, x: CGFloat, baseline: CGFloat, width available: CGFloat = .greatestFiniteMagnitude) {
        guard available > 0 else { return }
        var shown = line
        if width > available {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
            guard let cut = CTLineCreateTruncatedLine(line, Double(available), .end, ellipsis) else { return }
            shown = cut
        }
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(shown, context)
    }
}

/// A `MessageRowView` in SwiftUI. It takes no events; the list lays its buttons and menus over
/// it.
struct MessageRowCell: NSViewRepresentable {
    let model: MessageRowModel

    func makeNSView(context: Context) -> MessageRowView { MessageRowView(model: model) }

    func updateNSView(_ view: MessageRowView, context: Context) { view.model = model }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageRowView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? OL.listWidth, height: model.height)
    }
}
