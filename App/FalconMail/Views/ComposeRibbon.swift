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
    var importance: Binding<String>
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
                .padding(.horizontal, OL.tabInset)
            switch tab {
            case .message: messageTab
            case .options: optionsTab
            }
        }
        // Pinned to its own frame: a background left to ignore the safe area spreads up over the
        // title row above it.
        .background(OLColor.chrome, ignoresSafeAreaEdges: [])
        .background(ChromeBackground())
    }

    /// Outlook's Message ribbon: Send · Paste with cut/copy/format · the two-row format block
    /// (fonts, paragraph marks above; styles, colours, alignment below) · Switch Background ·
    /// Attach File · Table · Pictures/Signature/Link.
    private var messageTab: some View {
        RibbonBody {
            RibbonTile(title: "Send", symbol: "paperplane", enabled: canSend, action: onSend)
            RibbonSeparator()
            RibbonSplitTile(title: "Paste", symbol: "doc.on.clipboard", action: { formatter.pasteMatchingStyle() }) {
                Button("Paste and Match FalconMail") { formatter.pasteMatchingStyle() }
                Button("Paste Keeping Source Formatting") { formatter.pasteKeepingSource() }
                Button("Paste as Plain Text") { formatter.pastePlain() }
            }
            VStack(spacing: 2) {
                FmtButton("scissors", "Cut", size: 16) { formatter.cut() }
                FmtButton("doc.on.doc", "Copy", size: 16) { formatter.copy() }
                FmtButton("paintbrush", "Copy formatting", size: 16) { formatter.copyFormatting() }
            }
            .padding(.top, OL.ribbonIconTop + 2)
            .frame(height: OL.ribbon, alignment: .top)
            RibbonSeparator()
            formatBlock
            RibbonSeparator()
            RibbonTile(title: "Switch\nBackground", symbol: "sun.max", action: onCycleBackground)
            RibbonSeparator()
            RibbonSplitTile(title: "Attach\nFile", symbol: "paperclip", action: onAttachFile) {
                Button("From this Mac…") { onAttachFile() }
                Button("From Google Drive…") { onAttachFromDrive() }
            }
            RibbonSeparator()
            RibbonSplitTile(title: "Table", symbol: "tablecells", action: { formatter.insertTable() }) {
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

    /// Two rows of twenty-two point controls, the upper at y 71, the lower at y 101 of the
    /// window, spaced as Outlook spaces them.
    private var formatBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                FmtPopup(text: formatter.fontName, width: 90) {
                    ForEach(TextFormatter.families, id: \.self) { name in Button(name) { formatter.setFontName(name) } }
                }
                FmtPopup(text: "\(Int(formatter.fontSize))", width: 53) {
                    ForEach(TextFormatter.sizes, id: \.self) { size in Button("\(Int(size))") { formatter.setFontSize(size) } }
                }
                .padding(.leading, 12)
                FmtButton("textformat.size.larger", "Grow text") { formatter.stepFontSize(2) }.padding(.leading, 4)
                FmtButton("textformat.size.smaller", "Shrink text") { formatter.stepFontSize(-2) }.padding(.leading, 4)
                FmtSeparator()
                FmtButton("eraser", "Clear formatting") { formatter.clearFormatting() }
                FmtSeparator()
                FmtMenuButton("list.bullet", "Bulleted list", action: { formatter.applyList(.disc) }) {
                    Button("Bullets") { formatter.applyList(.disc) }
                }
                FmtMenuButton("list.number", "Numbered list", action: { formatter.applyList(.decimal) }) {
                    Button("Numbers") { formatter.applyList(.decimal) }
                }
                .padding(.leading, 4)
                FmtSeparator()
                FmtButton("decrease.indent", "Decrease indent") { formatter.changeIndent(by: -24) }
                FmtButton("increase.indent", "Increase indent") { formatter.changeIndent(by: 24) }.padding(.leading, 4)
                FmtSeparator()
                FmtButton("paragraphsign", "Show paragraph marks") { formatter.cycleLineSpacing() }
            }
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    FmtButton("bold", "Bold") { formatter.toggleBold() }
                    FmtButton("italic", "Italic") { formatter.toggleItalic() }
                    FmtButton("underline", "Underline") { formatter.toggleUnderline() }
                    FmtButton("strikethrough", "Strikethrough") { formatter.toggleStrikethrough() }
                    FmtButton("textformat.subscript", "Subscript") { formatter.setBaseline(-4) }
                    FmtButton("textformat.superscript", "Superscript") { formatter.setBaseline(6) }
                }
                .padding(.leading, 2)
                FmtSeparator()
                FmtColourButton("highlighter", "Highlight", colour: formatter.highlight, palette: TextFormatter.highlightPalette) { formatter.setHighlight($0) }
                FmtColourButton("textformat", "Text colour", colour: formatter.textColour, palette: TextFormatter.textPalette) { formatter.setTextColour($0) }
                    .padding(.leading, 4)
                FmtSeparator()
                HStack(spacing: 4) {
                    FmtButton("text.alignleft", "Align left") { formatter.align(.left) }
                    FmtButton("text.aligncenter", "Centre") { formatter.align(.center) }
                    FmtButton("text.alignright", "Align right") { formatter.align(.right) }
                    FmtButton("text.justify", "Justify") { formatter.align(.justified) }
                }
            }
        }
        .padding(.top, OL.ribbonIconTop + 5)
        .frame(height: OL.ribbon, alignment: .top)
    }

    private var optionsTab: some View {
        RibbonBody {
            RibbonMenuTile(title: "Importance", symbol: "exclamationmark") {
                Picker("Importance", selection: importance) {
                    Text("Low").tag("low")
                    Text("Normal").tag("normal")
                    Text("High").tag("high")
                }
                .pickerStyle(.inline)
            }
            RibbonSeparator()
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

/// A twenty-two point format control in Outlook's grey.
struct FmtButton: View {
    let symbol: String
    let title: String
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, _ title: String, size: CGFloat = 13, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(OLColor.icon)
                .frame(width: size > 14 ? 18 : 22, height: 22)
                .background(hovering ? OLColor.hover : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// A format control with Outlook's small chevron beside it that opens a menu.
struct FmtMenuButton<Content: View>: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @ViewBuilder var menu: () -> Content

    init(_ symbol: String, _ title: String, action: @escaping () -> Void, @ViewBuilder menu: @escaping () -> Content) {
        self.symbol = symbol
        self.title = title
        self.action = action
        self.menu = menu
    }

    var body: some View {
        HStack(spacing: 2) {
            FmtButton(symbol, title, action: action)
            Menu { menu() } label: {
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(OLColor.ribbonLabel)
                    .frame(width: 10, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// Highlight and text colour: the glyph over a bar in the current colour, a chevron for the palette.
struct FmtColourButton: View {
    let symbol: String
    let title: String
    let colour: Color
    let palette: [(String, Color)]
    let apply: (Color) -> Void

    init(_ symbol: String, _ title: String, colour: Color, palette: [(String, Color)], apply: @escaping (Color) -> Void) {
        self.symbol = symbol
        self.title = title
        self.colour = colour
        self.palette = palette
        self.apply = apply
    }

    var body: some View {
        HStack(spacing: 2) {
            Button { apply(colour) } label: {
                VStack(spacing: 1) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .regular)).foregroundStyle(OLColor.icon).frame(height: 15)
                    RoundedRectangle(cornerRadius: 1).fill(colour).frame(width: 16, height: 3)
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
            Menu {
                ForEach(palette, id: \.0) { entry in
                    Button(entry.0) { apply(entry.1) }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(OLColor.ribbonLabel)
                    .frame(width: 10, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// The font family and size boxes: dark fields with a chevron.
struct FmtPopup<Content: View>: View {
    let text: String
    let width: CGFloat
    @ViewBuilder var menu: () -> Content

    var body: some View {
        Menu { menu() } label: {
            HStack(spacing: 4) {
                Text(text).font(.system(size: 13)).foregroundStyle(OLColor.text).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(OLColor.icon)
            }
            .padding(.horizontal, 7)
            .frame(width: width, height: 22)
            .background(OLColor.ribbonField, in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct FmtSeparator: View {
    var body: some View {
        Rectangle().fill(OLColor.ribbonSeparator).frame(width: 1, height: 22).padding(.horizontal, 8)
    }
}
