import SwiftUI
import AppKit

enum ComposeTab: String, CaseIterable {
    case message, options

    var title: String { self == .message ? "Message" : "Options" }
}

struct ComposeRibbon: View {
    @Binding var tab: ComposeTab
    var formatter: TextFormatter
    var showsBcc: Binding<Bool>
    var canSend: Bool
    var onSend: () -> Void
    var onAttachFile: () -> Void
    var onAttachFromDrive: () -> Void
    var onInsertSignature: () -> Void
    var onEditSignatures: () -> Void
    var onCycleBackground: () -> Void

    @AppStorage(Pref.composeHTML) private var usesHTML = true
    @AppStorage(Pref.checkSpelling) private var checkSpelling = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RibbonTabStrip(tabs: ComposeTab.allCases.map { ($0, $0.title) }, selection: $tab)
                .padding(.horizontal, RibbonMetrics.edgeInset)
                .padding(.top, 6)
            Divider().opacity(0.4)
            switch tab {
            case .message: messageTab
            case .options: optionsTab
            }
        }
        .background(ChromeBackground())
    }

    private var messageTab: some View {
        RibbonBody {
            RibbonTile(title: "Send", symbol: "paperplane", tint: .accentColor, enabled: canSend, action: onSend)
            RibbonSeparator()
            pasteGroup
            RibbonSeparator()
            fontGroup
            RibbonSeparator()
            paragraphGroup
            RibbonSeparator()
            RibbonTile(title: "Switch\nBackground", symbol: "sun.max", tint: .yellow, action: onCycleBackground)
            RibbonSplitTile(title: "Attach\nFile", symbol: "paperclip", tint: .blue, action: onAttachFile) {
                Button("From this Mac…") { onAttachFile() }
                Button("From Google Drive…") { onAttachFromDrive() }
            }
            RibbonSplitTile(title: "Table", symbol: "tablecells", tint: .green, action: { formatter.insertTable() }) {
                Button("Insert 3 × 3") { formatter.insertTable(rows: 3, columns: 3) }
                Button("Insert 4 × 4") { formatter.insertTable(rows: 4, columns: 4) }
                Button("Insert 2 × 5") { formatter.insertTable(rows: 2, columns: 5) }
            }
            RibbonSeparator()
            RibbonMiniColumn {
                RibbonMiniItem(title: "Pictures", symbol: "photo") { formatter.insertPicture() }
                RibbonMiniItem(title: "Signature", symbol: "signature") { onInsertSignature() }
                RibbonMiniItem(title: "Link", symbol: "link") { formatter.insertLink() }
            }
        }
    }

    private var pasteGroup: some View {
        HStack(spacing: 2) {
            RibbonSplitTile(title: "Paste", symbol: "doc.on.clipboard", action: { formatter.pasteMatchingStyle() }) {
                Button("Paste and Match FalconMail") { formatter.pasteMatchingStyle() }
                Button("Paste Keeping Source Formatting") { formatter.pasteKeepingSource() }
                Button("Paste as Plain Text") { formatter.pastePlain() }
            }
            RibbonMiniColumn {
                RibbonMiniItem(title: "Cut", symbol: "scissors") { formatter.cut() }
                RibbonMiniItem(title: "Copy", symbol: "doc.on.doc") { formatter.copy() }
                RibbonMiniItem(title: "Format", symbol: "paintbrush") { formatter.copyFormatting() }
            }
        }
    }

    private var fontGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Picker("", selection: Binding(get: { formatter.fontName }, set: { formatter.setFontName($0) })) {
                    ForEach(TextFormatter.families, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 132).help("Font")
                Picker("", selection: Binding(get: { formatter.fontSize }, set: { formatter.setFontSize($0) })) {
                    ForEach(TextFormatter.sizes, id: \.self) { Text("\(Int($0))").tag($0) }
                }
                .labelsHidden().frame(width: 64).help("Size")
                FormatIcon("textformat.size.larger", "Grow text") { formatter.stepFontSize(2) }
                FormatIcon("textformat.size.smaller", "Shrink text") { formatter.stepFontSize(-2) }
                FormatIcon("eraser", "Clear formatting") { formatter.clearFormatting() }
            }
            HStack(spacing: 3) {
                FormatIcon("bold", "Bold") { formatter.toggleBold() }
                FormatIcon("italic", "Italic") { formatter.toggleItalic() }
                FormatIcon("underline", "Underline") { formatter.toggleUnderline() }
                FormatIcon("strikethrough", "Strikethrough") { formatter.toggleStrikethrough() }
                FormatIcon("textformat.subscript", "Subscript") { formatter.setBaseline(-4) }
                FormatIcon("textformat.superscript", "Superscript") { formatter.setBaseline(6) }
                ColorPicker("", selection: Binding(get: { formatter.highlight }, set: { formatter.setHighlight($0) }), supportsOpacity: false)
                    .labelsHidden().frame(width: 36).help("Highlight")
                ColorPicker("", selection: Binding(get: { formatter.textColour }, set: { formatter.setTextColour($0) }), supportsOpacity: false)
                    .labelsHidden().frame(width: 36).help("Text colour")
            }
        }
        .frame(width: 292, height: RibbonMetrics.tileHeight, alignment: .leading)
    }

    private var paragraphGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                FormatIcon("list.bullet", "Bulleted list") { formatter.applyList(.disc) }
                FormatIcon("list.number", "Numbered list") { formatter.applyList(.decimal) }
                FormatIcon("decrease.indent", "Decrease indent") { formatter.changeIndent(by: -24) }
                FormatIcon("increase.indent", "Increase indent") { formatter.changeIndent(by: 24) }
                FormatIcon("text.line.first.and.arrowtriangle.forward", "Line spacing") { formatter.cycleLineSpacing() }
            }
            HStack(spacing: 3) {
                FormatIcon("text.alignleft", "Align left") { formatter.align(.left) }
                FormatIcon("text.aligncenter", "Centre") { formatter.align(.center) }
                FormatIcon("text.alignright", "Align right") { formatter.align(.right) }
                FormatIcon("text.justify", "Justify") { formatter.align(.justified) }
            }
        }
        .frame(width: 146, height: RibbonMetrics.tileHeight, alignment: .leading)
    }

    private var optionsTab: some View {
        RibbonBody {
            RibbonPill(onLabel: "HTML", offLabel: "Plain", caption: "Format Text", isOn: $usesHTML)
            RibbonSeparator()
            RibbonTile(title: "Switch\nBackground", symbol: "sun.max", tint: .yellow, action: onCycleBackground)
            RibbonSeparator()
            RibbonTile(title: "BCC", symbol: "rectangle.stack.badge.person.crop", tint: .blue) { showsBcc.wrappedValue.toggle() }
            RibbonSeparator()
            RibbonTile(title: "Zoom", symbol: "magnifyingglass") { formatter.showZoomPanel() }
            RibbonSeparator()
            RibbonMenuTile(title: "Encrypt", symbol: "lock") {
                Text("Encryption needs S/MIME or OpenPGP keys for this account.")
                Divider()
                Button("Learn about message encryption") {
                    if let url = URL(string: "https://support.google.com/a/answer/6374496") { NSWorkspace.shared.open(url) }
                }
            }
            RibbonSeparator()
            RibbonTile(title: "Spelling &\nGrammar", symbol: "textformat.abc.dottedunderline", tint: .green) { formatter.checkSpelling() }
            RibbonMenuTile(title: "Language", symbol: "character.book.closed") {
                Toggle("Check Spelling While Typing", isOn: Binding(
                    get: { checkSpelling },
                    set: { checkSpelling = $0; formatter.editor?.isContinuousSpellCheckingEnabled = $0 }))
                Divider()
                Button("Show Spelling and Grammar…") { formatter.editor?.showGuessPanel(nil) }
            }
            RibbonSeparator()
            RibbonTile(title: "Check\nAccessibility", symbol: "figure.stand", tint: .blue) { runAccessibilityCheck() }
        }
    }

    private func runAccessibilityCheck() {
        let alert = NSAlert()
        let problems = accessibilityProblems()
        alert.messageText = problems.isEmpty ? "No accessibility problems found" : "\(problems.count) things to look at"
        alert.informativeText = problems.isEmpty
            ? "Images have descriptions and the text has enough contrast."
            : problems.joined(separator: "\n")
        alert.runModal()
    }

    private func accessibilityProblems() -> [String] {
        guard let storage = formatter.editor?.textStorage else { return [] }
        var problems: [String] = []
        var images = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { images += 1 }
        }
        if images > 0 { problems.append("\(images) image\(images == 1 ? "" : "s") without a written description.") }
        if storage.string.count > 40, storage.string.uppercased() == storage.string {
            problems.append("The whole message is in capitals, which screen readers spell out letter by letter.")
        }
        return problems
    }
}

struct FormatIcon: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, _ title: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 25, height: 22)
                .background(hovering ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}
