#if DEBUG
import AppKit
import FalconCore

/// Launch arguments that open a compose window on a stand-in draft, with no account, so the
/// ribbon and the body can be captured and measured without driving the interface:
/// `-FalconMailDemoComposeRibbon YES` opens the window with the caret in the body;
/// `-FalconMailDemoTablePicker 3x4` opens the Table picker with that size under the pointer;
/// `-FalconMailDemoTable 3x2` inserts a table of that size with some figures in it;
/// `-FalconMailDemoSelection YES` selects a word, so Cut and Copy light up;
/// `-FalconMailDemoSignature YES` inserts a stand-in signature at the end, through
/// the Signature menu's own path, and `-FalconMailDemoUndo YES` then undoes the last insertion;
/// `-FalconMailDemoSignatures YES` does what the menu's Edit Signatures… does.
enum ComposeRibbonDemo {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "FalconMailDemoComposeRibbon") }
    static var tablePicker: TableSize? { isRequested ? size("FalconMailDemoTablePicker") : nil }

    @MainActor static func draft(in model: AppModel) -> UUID {
        var draft = ComposeDraft(accountID: UUID())
        draft.body = "Hello,\n\nThe figures for this week are below.\n\n"
        return model.newDraft(draft)
    }

    @MainActor static func prepare(_ editor: NSTextView, formatter: TextFormatter, editSignatures: @escaping () -> Void) {
        guard isRequested else { return }
        let defaults = UserDefaults.standard
        // Wait for the body to be in its window and laid out, so the table takes its width. AppKit
        // closes an Undo step when it has handled an event, so each step posts one, as the click
        // that would have started it does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            editor.window?.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            if let size = size("FalconMailDemoTable") { fill(editor, formatter: formatter, size: size) }
            postStep()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if defaults.bool(forKey: "FalconMailDemoSignature") {
                // Never saved: it only lends the menu a signature.
                let signature = Signature(name: "Demo", plain: "Alex Example\nExample Ltd")
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                formatter.insertSignature(signature)
            }
            postStep()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            if defaults.bool(forKey: "FalconMailDemoUndo") { editor.undoManager?.undo() }
            if defaults.bool(forKey: "FalconMailDemoSelection") {
                editor.setSelectedRange((editor.string as NSString).range(of: "figures"))
            }
            if defaults.bool(forKey: "FalconMailDemoSignatures") { editSignatures() }
        }
    }

    @MainActor private static func fill(_ editor: NSTextView, formatter: TextFormatter, size: TableSize) {
        formatter.insertTable(rows: size.rows, columns: size.columns)
        guard let storage = editor.textStorage else { return }
        let first = editor.selectedRange().location
        let words = ["Region", "This week", "Last week", "North", "1,240", "1,180", "South", "985", "1,020"]
        // Every cell is still an empty paragraph, so cell n starts n characters in; filling from
        // the last keeps the earlier offsets true.
        for cell in (0..<(size.rows * size.columns)).reversed() {
            let at = first + cell
            let word = words[cell % words.count]
            guard editor.shouldChangeText(in: NSRange(location: at, length: 0), replacementString: word) else { continue }
            storage.insert(NSAttributedString(string: word, attributes: storage.attributes(at: at, effectiveRange: nil)), at: at)
            editor.didChangeText()
        }
    }

    @MainActor private static func postStep() {
        guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private static func size(_ key: String) -> TableSize? {
        let parts = (UserDefaults.standard.string(forKey: key) ?? "").split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return TableSize(columns: parts[0], rows: parts[1])
    }
}
#endif
