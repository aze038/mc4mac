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
    var signatures: [SignatureChoice]
    var onInsertSignature: (SignatureChoice) -> Void
    var onEditSignatures: () -> Void
    var onInsertTableDialog: () -> Void
    var onCycleBackground: () -> Void

    @AppStorage(Pref.composeHTML) private var usesHTML = true
    @AppStorage(Pref.checkSpelling) private var checkSpelling = true
    @State private var tableTile: NSView?
    @State private var tableOpen = false

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
        #if DEBUG
        .task {
            guard let size = ComposeRibbonDemo.tablePicker else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            openTablePicker(hovering: size)
        }
        #endif
    }

    /// Outlook's Message ribbon: Send · Paste with cut/copy/format · the two-row format block
    /// (fonts, paragraph marks above; styles, colours, alignment below) · Switch Background ·
    /// Attach File · Table · Pictures/Signature/Link.
    private var messageTab: some View {
        RibbonBody {
            RibbonTile(title: "Send", symbol: "paperplane", enabled: canSend, action: onSend)
                .padding(.horizontal, OL.composeSendPad)
            RibbonSeparator()
            RibbonSplitTile(title: "Paste", symbol: "doc.on.clipboard", action: { formatter.pasteMatchingStyle() }) {
                Button("Paste and Match FalconMail") { formatter.pasteMatchingStyle() }
                Button("Paste Keeping Source Formatting") { formatter.pasteKeepingSource() }
                Button("Paste as Plain Text") { formatter.pastePlain() }
            }
            .padding(.leading, OL.composePasteLead)
            RibbonSmallColumn {
                RibbonSmallButton(symbol: "scissors", title: "Cut", size: 12.8, turn: .degrees(-90),
                                  enabled: formatter.editorHasFocus && formatter.hasSelection) { formatter.cut() }
                RibbonSmallButton(symbol: "doc.on.doc", title: "Copy", size: 13.3,
                                  enabled: formatter.editorHasFocus && formatter.hasSelection) { formatter.copy() }
                RibbonSmallButton(symbol: "paintbrush", title: "Format Painter", size: 13, turn: .degrees(180),
                                  enabled: formatter.editorHasFocus || formatter.isPaintingFormat,
                                  isOn: formatter.isPaintingFormat) { formatter.toggleFormatPainter() }
            }
            .padding(.horizontal, OL.composeClipboardPad)
            RibbonSeparator()
            formatBlock
            RibbonSeparator()
            RibbonTile(title: "Switch\nBackground", symbol: "sun.max", action: onCycleBackground)
            RibbonSeparator()
            RibbonTile(title: "Attach\nFile", symbol: "paperclip", action: onAttachFile)
            RibbonSeparator()
            RibbonDropdownTile(title: "Table", symbol: "tablecells", isOpen: tableOpen) { openTablePicker() }
                .background(ScreenAnchor { tableTile = $0 })
            RibbonSeparator()
            RibbonSmallColumn {
                RibbonSmallItem(title: "Pictures", symbol: "photo", size: 13.5) { formatter.insertPicture() }
                RibbonSmallMenu(title: "Signature", symbol: "signature", size: 12) {
                    SignatureMenuItems(choices: signatures, insert: onInsertSignature, edit: onEditSignatures)
                }
                RibbonSmallItem(title: "Link", symbol: "link", size: 13, turn: .degrees(45)) { formatter.insertLink() }
            }
        }
    }

    private func openTablePicker(hovering size: TableSize? = nil) {
        guard let tableTile else { return }
        tableOpen = true
        TableGridPanel.show(below: tableTile, hovering: size,
                            insert: { formatter.insertTable(rows: $0.rows, columns: $0.columns) },
                            insertCustom: onInsertTableDialog,
                            closed: { tableOpen = false })
    }

    /// Two rows of twenty-two point controls, the upper at y 71, the lower at y 101 of the
    /// window, spaced as Outlook spaces them: the upper row's separators fall at x 375, 416, 507
    /// and 574, and the block ends where the line before Switch Background stands at 617.
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
                FmtSeparator().padding(.leading, 1)
                FmtButton("eraser", "Clear formatting") { formatter.clearFormatting() }
                FmtSeparator().padding(.leading, 2)
                FmtMenuButton("list.bullet", "Bulleted list", action: { formatter.applyList(.disc) }) {
                    Button("Bullets") { formatter.applyList(.disc) }
                }
                FmtMenuButton("list.number", "Numbered list", action: { formatter.applyList(.decimal) }) {
                    Button("Numbers") { formatter.applyList(.decimal) }
                }
                .padding(.leading, 4)
                FmtSeparator().padding(.leading, 2)
                FmtButton("decrease.indent", "Decrease indent") { formatter.changeIndent(by: -24) }.padding(.leading, 1.5)
                FmtButton("increase.indent", "Increase indent") { formatter.changeIndent(by: 24) }.padding(.leading, 4)
                FmtSeparator().padding(.leading, 0.5)
                FmtButton("paragraphsign", "Show paragraph marks") { formatter.cycleLineSpacing() }.padding(.leading, 1)
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
        .padding(.trailing, 2)
        .frame(height: OL.ribbon, alignment: .top)
    }

    private var optionsTab: some View {
        RibbonBody {
            RibbonTile(title: "Google\nDrive", symbol: "externaldrive", action: onAttachFromDrive)
            RibbonSeparator()
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

/// Outlook's small-icon columns: rows of twenty-two points from the top of the tiles, so the
/// glyphs centre at y 77, 99 and 121 of the window and the last stops seven points above the
/// ribbon's line.
struct RibbonSmallColumn<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.top, OL.ribbonIconTop)
            .frame(height: OL.ribbon, alignment: .top)
    }
}

private struct SmallGlyph: View {
    let symbol: String
    let size: CGFloat
    var turn: Angle = .zero

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .light))
            .rotationEffect(turn)
            .foregroundStyle(OLColor.ribbonIcon)
            .frame(width: OL.ribbonSmallIcon, height: OL.ribbonSmallIcon)
    }
}

/// Cut, Copy and Format Painter beside Paste: a glyph alone in its row, grey, dimmed to a
/// third when there is nothing for it to act on, lit while it is on.
struct RibbonSmallButton: View {
    let symbol: String
    let title: String
    let size: CGFloat
    var turn: Angle = .zero
    var enabled = true
    var isOn = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SmallGlyph(symbol: symbol, size: size, turn: turn)
                .opacity(enabled ? 1 : OL.ribbonGlyphDimmed)
                .frame(width: OL.ribbonSmallRow, height: OL.ribbonSmallRow)
                .background(isOn ? Color.primary.opacity(0.16) : (hovering && enabled ? OLColor.hover : Color.clear),
                            in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(RibbonButtonStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// Pictures and Link at the end of the ribbon: glyph and caption in one row.
struct RibbonSmallItem: View {
    let title: String
    let symbol: String
    let size: CGFloat
    var turn: Angle = .zero
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SmallRowFace(title: title, symbol: symbol, size: size, turn: turn, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// Signature: the same row, opening a menu.
struct RibbonSmallMenu<Content: View>: View {
    let title: String
    let symbol: String
    let size: CGFloat
    @ViewBuilder var menu: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu { menu() } label: {
            SmallRowFace(title: title, symbol: symbol, size: size, hovering: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// Outlook sets these captions in the tiles' own 10.5 points, smaller than the Home ribbon's rows.
private struct SmallRowFace: View {
    let title: String
    let symbol: String
    let size: CGFloat
    var turn: Angle = .zero
    let hovering: Bool

    var body: some View {
        HStack(spacing: 6) {
            SmallGlyph(symbol: symbol, size: size, turn: turn)
            Text(title).font(.system(size: OL.ribbonLabelFont)).foregroundStyle(OLColor.ribbonLabel).lineLimit(1)
        }
        .padding(.horizontal, 4)
        .frame(height: OL.ribbonSmallRow)
        .background(hovering ? OLColor.hover : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }
}

/// A twenty-two point format control in Outlook's grey.
struct FmtButton: View {
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
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(OLColor.icon)
                .frame(width: 22, height: 22)
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
