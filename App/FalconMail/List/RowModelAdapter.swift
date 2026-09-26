import AppKit
import FalconCore

/// Turns what the list knows of a row into the input of the row the list draws, `MessageRowModel`,
/// so the table shows the same rows as the list it replaces, unchanged. The row only draws; the
/// table supplies whether it is selected, and the text comes from the row's content, the flags
/// from the index, so a row can lag behind but never contradict it.
///
/// A row whose text has not arrived is drawn from the same model, with its unread dot, flag, clip
/// and count already right, and grey bars where its words will be.
enum RowModelAdapter {
    struct Row {
        var model: MessageRowModel
        /// No text yet: the table draws bars over the words' places and offers no quick actions.
        var isPlaceholder: Bool
    }

    /// Text of typical length whose widths size a placeholder's bars, so they look like the rows
    /// that will replace them. It is never drawn.
    enum Dummy {
        static let sender = "Firstname Lastname, Another"
        static let subject = "A subject of a typical length"
        static let preview = "The opening words of a message run on to the end of the line"
        static let date = "23.09.2026"
        static let child = "Firstname Lastname"
    }

    /// The row for `record`: a conversation's or lone message's, or one message of an opened
    /// conversation. Headers are the table's own and never come here.
    static func row(_ record: DisplayRecord, content: MessageRowContent?, selection: MessageRowModel.Selection,
                    showsPreview: Bool, namesRecipients: Bool = false, categories: [NSColor] = [], actionsWidth: CGFloat = 0,
                    isLastChild: Bool = false, density: ListDensity = .cozy, now: Date = Date()) -> Row {
        let bits = record.displayBits
        let unread = record.unread > 0 || bits.contains(.unread)
        if record.displayKind == .child {
            guard let content else {
                return Row(model: MessageRowModel(kind: .child(last: isLastChild), sender: "", date: "", isUnread: unread,
                                                  selection: selection), isPlaceholder: true)
            }
            let sender = namesRecipients ? recipients(content.to).nonEmpty ?? content.from.displayName : content.from.displayName
            return Row(model: MessageRowModel(kind: .child(last: isLastChild), sender: sender,
                                              date: MessageListText.date(content.date, now: now), isUnread: unread,
                                              selection: selection), isPlaceholder: false)
        }

        let isConversation = record.displayKind == .conversation
        let expanded = bits.contains(.expanded)
        let disclosure: MessageRowModel.Disclosure = isConversation ? (expanded ? .expanded : .collapsed) : .none
        // An opened conversation drops its preview, as Outlook's does: its messages follow.
        let preview: String? = showsPreview && density.hasPreviewLine && !(isConversation && expanded) ? "" : nil
        var model = MessageRowModel(kind: .conversation, disclosure: disclosure, sender: "", subject: "", date: "",
                                    preview: preview, isUnread: unread, unreadCount: isConversation ? Int(record.unread) : 0,
                                    hasAttachments: bits.contains(.hasAttachment), isFlagged: bits.contains(.flagged),
                                    categories: categories, selection: selection, actionsWidth: 0, density: density)
        guard let content else { return Row(model: model, isPlaceholder: true) }

        model.sender = sender(content, isConversation: isConversation, namesRecipients: namesRecipients)
        model.subject = content.subject.isEmpty ? "(no subject)" : content.subject
        model.date = MessageListText.date(content.conversation?.newestDate ?? content.date, now: now)
        if preview != nil { model.preview = MessageListText.preview(content.preview) }
        model.hasAttachments = model.hasAttachments || content.hasAttachments == true
        model.actionsWidth = actionsWidth
        return Row(model: model, isPlaceholder: false)
    }

    /// Everyone who wrote in the conversation, newest first and each once, as the list names
    /// them; in Sent and Drafts, who the mail went to.
    static func sender(_ content: MessageRowContent, isConversation: Bool, namesRecipients: Bool) -> String {
        if namesRecipients, let named = recipients(content.to).nonEmpty { return named }
        guard isConversation, let senders = content.conversation?.senders, senders.count > 1 else { return content.from.displayName }
        return names(senders.reversed())
    }

    private static func recipients(_ people: [EmailAddress]) -> String { names(people) }

    /// Names in the order given, each person once: the same address in another case is the same
    /// person, and one without an address is known by name.
    static func names<S: Sequence>(_ people: S) -> String where S.Element == EmailAddress {
        var seen = Set<String>()
        var out: [String] = []
        for person in people {
            let address = person.address.trimmingCharacters(in: .whitespaces).lowercased()
            let name = person.displayName.trimmingCharacters(in: .whitespaces)
            let key = address.isEmpty ? "name:" + name.lowercased() : address
            guard !name.isEmpty, seen.insert(key).inserted else { continue }
            out.append(name)
        }
        return out.joined(separator: ", ")
    }

    /// Where a placeholder's grey bars go: one for each piece of text the row will show, as long
    /// as the dummy text would be, within the row's `width`.
    static func placeholderBars(for model: MessageRowModel, width: CGFloat) -> [CGRect] {
        let barHeight: CGFloat = 8
        func bar(_ text: String, font: NSFont, x: CGFloat, baseline: CGFloat, limit: CGFloat, fromRight: Bool = false) -> CGRect? {
            let measured = (text as NSString).size(withAttributes: [.font: font]).width
            let length = min(measured, limit)
            guard length > 4 else { return nil }
            let y = baseline - font.xHeight / 2 - barHeight / 2
            return CGRect(x: fromRight ? x - length : x, y: y, width: length, height: barHeight)
        }
        let text = NSFont.systemFont(ofSize: OL.listTextFont)
        let senderFont = NSFont.systemFont(ofSize: OL.listSenderFont, weight: .medium)
        switch model.kind {
        case .child:
            let dateEnd = min(OL.listChildDateEnd, width - OL.listTextRight)
            let date = bar(Dummy.date, font: text, x: dateEnd, baseline: OL.listChildBaseline, limit: 80, fromRight: true)
            let senderLimit = (date?.minX ?? dateEnd) - OL.listDateGap - OL.listChildTextX
            return [bar(Dummy.child, font: text, x: OL.listChildTextX, baseline: OL.listChildBaseline, limit: senderLimit), date]
                .compactMap { $0 }
        case .conversation:
            let right = width - OL.listTextRight
            // The icons and the count stand at the first line's end; the writers stop short of them.
            let iconRoom: CGFloat = (model.unreadCount > 0 ? 34 : 0) + (model.isFlagged ? 20 : 0) + (model.hasAttachments ? 16 : 0)
            let senderLimit = width - OL.listSenderRight - iconRoom - OL.listTextX
            var bars = [bar(Dummy.sender, font: senderFont, x: OL.listTextX, baseline: OL.listBaseline, limit: senderLimit)]
            let baseline2 = OL.listBaseline + OL.listLinePitch
            let date = bar(Dummy.date, font: text, x: right, baseline: baseline2, limit: 90, fromRight: true)
            bars.append(date)
            bars.append(bar(Dummy.subject, font: text, x: OL.listTextX, baseline: baseline2,
                            limit: (date?.minX ?? right) - OL.listDateGap - OL.listTextX))
            if model.preview != nil {
                bars.append(bar(Dummy.preview, font: text, x: OL.listTextX, baseline: baseline2 + OL.listLinePitch,
                                limit: right - OL.listTextX))
            }
            // Moved with the row's text in Roomy and Compact.
            return bars.compactMap { $0?.offsetBy(dx: 0, dy: model.density.textShift) }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
