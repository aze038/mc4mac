import SwiftUI
import AppKit
import FalconCore

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
    var signatures: [Signature]
    var onInsertSignature: (Signature) -> Void
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
                RibbonSmallButton(title: "Copy", enabled: formatter.editorHasFocus && formatter.hasSelection,
                                  glyph: CopyGlyph()) { formatter.copy() }
                RibbonSmallButton(symbol: "paintbrush", title: "Format Painter", size: 13, turn: .degrees(180),
                                  enabled: formatter.canPaintFormat,
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
            RibbonDropdownTile(title: "Table", isOpen: tableOpen, glyph: TableGlyph()) { openTablePicker() }
                .background(ScreenAnchor { tableTile = $0 })
            RibbonSeparator()
            RibbonSmallColumn {
                RibbonSmallItem(title: "Pictures", symbol: "photo", size: 13.5) { formatter.insertPicture() }
                RibbonSmallMenu(title: "Signature", symbol: "signature", size: 12) {
                    SignatureMenuItems(signatures: signatures, insert: onInsertSignature, edit: onEditSignatures)
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

    /// Two rows of twenty-two point controls, the upper at y 71, the lower at y 103 of the
    /// window, spaced as Outlook spaces them: the upper row's separators fall at x 375, 416, 507
    /// and 574, the lower row's at 322 and 413, and the block ends where the line before Switch
    /// Background stands at 617. The glyphs are Outlook's ribbon grey, not the text's white.
    private var formatBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                FmtSeparator().padding(.leading, 1)
                FmtColourButton("highlighter", "Highlight", colour: formatter.highlight, palette: TextFormatter.highlightPalette) { formatter.setHighlight($0) }
                    .padding(.leading, 1)
                FmtColourButton("textformat", "Text colour", colour: formatter.textColour, palette: TextFormatter.textPalette) { formatter.setTextColour($0) }
                    .padding(.leading, 4)
                FmtSeparator().padding(.leading, 1)
                HStack(spacing: 4) {
                    FmtButton("text.alignleft", "Align left") { formatter.align(.left) }
                    FmtButton("text.aligncenter", "Centre") { formatter.align(.center) }
                    FmtButton("text.alignright", "Align right") { formatter.align(.right) }
                    FmtButton("text.justify", "Justify") { formatter.align(.justified) }
                }
                .padding(.leading, 1)
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

struct SmallGlyph: View {
    let symbol: String
    let size: CGFloat
    var turn: Angle = .zero
    var ink = OLColor.ribbonIcon

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .light))
            .rotationEffect(turn)
            .foregroundStyle(ink)
            .frame(width: OL.ribbonSmallIcon, height: OL.ribbonSmallIcon)
    }
}

/// Cut, Copy and Format Painter beside Paste: a glyph alone in its row, grey, dimmed to a
/// third when there is nothing for it to act on, lit while it is on.
struct RibbonSmallButton<Glyph: View>: View {
    let title: String
    var enabled = true
    var isOn = false
    let glyph: Glyph
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            glyph
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

extension RibbonSmallButton where Glyph == SmallGlyph {
    init(symbol: String, title: String, size: CGFloat, turn: Angle = .zero, enabled: Bool = true, isOn: Bool = false,
         action: @escaping () -> Void) {
        self.init(title: title, enabled: enabled, isOn: isOn, glyph: SmallGlyph(symbol: symbol, size: size, turn: turn), action: action)
    }
}

/// Outlook's Copy, which no symbol draws the right way round: the original behind at the top
/// left, the copy in front at the bottom right with its corner turned down and two fainter
/// lines of text, in one point lines on the small icons' sixteen point square.
struct CopyGlyph: View {
    var ink = OLColor.ribbonIcon

    var body: some View {
        ZStack {
            Path { path in
                path.addLines([CGPoint(x: 5, y: 13.5), CGPoint(x: 0.5, y: 13.5), CGPoint(x: 0.5, y: 0.5),
                               CGPoint(x: 6.5, y: 0.5), CGPoint(x: 8, y: 2)])
                path.addLines([CGPoint(x: 6.5, y: 3.5), CGPoint(x: 12.5, y: 3.5), CGPoint(x: 15.5, y: 6.5),
                               CGPoint(x: 15.5, y: 15.5), CGPoint(x: 6.5, y: 15.5)])
                path.closeSubpath()
                path.addLines([CGPoint(x: 11.5, y: 3.5), CGPoint(x: 11.5, y: 7.5), CGPoint(x: 15.5, y: 7.5)])
            }
            .stroke(lineWidth: 1)
            Path { path in
                path.addLines([CGPoint(x: 9, y: 10.5), CGPoint(x: 13, y: 10.5)])
                path.addLines([CGPoint(x: 9, y: 12.5), CGPoint(x: 13, y: 12.5)])
            }
            .stroke(lineWidth: 1)
            .opacity(0.64)
        }
        .foregroundStyle(ink)
        .frame(width: OL.ribbonSmallIcon, height: OL.ribbonSmallIcon)
    }
}

/// Outlook's Table: a grid three cells across and four rows down, the top row shaded as a
/// header, drawn across the tile's whole twenty-eight point box; its frame and header line in
/// the ribbon's grey, the lines between the cells fainter.
struct TableGlyph: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .opacity(0.3)
                .frame(width: 26, height: 3)
                .offset(x: 1, y: 1)
            Path { path in
                for x in [9.5, 18.5] { path.addLines([CGPoint(x: x, y: 5), CGPoint(x: x, y: 27)]) }
                for y in [12.5, 19.5] { path.addLines([CGPoint(x: 1, y: y), CGPoint(x: 27, y: y)]) }
            }
            .stroke(lineWidth: 1)
            .opacity(0.64)
            Path { path in
                path.addRect(CGRect(x: 0.5, y: 0.5, width: 27, height: 27))
                path.addLines([CGPoint(x: 1, y: 4.5), CGPoint(x: 27, y: 4.5)])
            }
            .stroke(lineWidth: 1)
        }
        .foregroundStyle(OLColor.ribbonIcon)
        .frame(width: OL.ribbonIconBox, height: OL.ribbonIconBox, alignment: .topLeading)
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

/// A twenty-two point format control, its glyph in Outlook's ribbon grey unless it stands in
/// another bar.
struct FmtButton: View {
    let symbol: String
    let title: String
    let ink: Color
    var accent: Color?
    var size: CGFloat = 13
    var box: CGFloat = 22
    let action: () -> Void
    @State private var hovering = false

    /// With an `accent`, the symbol's first layer takes it, as the blue bullets and arrows of
    /// Outlook's list and indent buttons.
    init(_ symbol: String, _ title: String, ink: Color = OLColor.ribbonIcon, accent: Color? = nil, size: CGFloat = 13,
         box: CGFloat = 22, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.ink = ink
        self.accent = accent
        self.size = size
        self.box = box
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .symbolRenderingMode(accent == nil ? .monochrome : .palette)
                .foregroundStyle(accent ?? ink, ink)
                .frame(width: box, height: box)
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
    var ink = OLColor.ribbonIcon
    var accent: Color?
    var chevronInk = OLColor.ribbonLabel
    var size: CGFloat = 13
    var box: CGFloat = 22
    let action: () -> Void
    @ViewBuilder var menu: () -> Content

    init(_ symbol: String, _ title: String, ink: Color = OLColor.ribbonIcon, accent: Color? = nil,
         chevronInk: Color = OLColor.ribbonLabel, size: CGFloat = 13, box: CGFloat = 22, action: @escaping () -> Void,
         @ViewBuilder menu: @escaping () -> Content) {
        self.symbol = symbol
        self.title = title
        self.ink = ink
        self.accent = accent
        self.chevronInk = chevronInk
        self.size = size
        self.box = box
        self.action = action
        self.menu = menu
    }

    var body: some View {
        HStack(spacing: 2) {
            FmtButton(symbol, title, ink: ink, accent: accent, size: size, box: box, action: action)
            Menu { menu() } label: {
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(chevronInk)
                    .frame(width: 10, height: box).contentShape(Rectangle())
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
    var ink = OLColor.ribbonIcon
    var chevronInk = OLColor.ribbonLabel
    var size: CGFloat = 12
    var box: CGFloat = 22
    var glyphHeight: CGFloat = 15
    let apply: (Color) -> Void

    init(_ symbol: String, _ title: String, colour: Color, palette: [(String, Color)], ink: Color = OLColor.ribbonIcon,
         chevronInk: Color = OLColor.ribbonLabel, size: CGFloat = 12, box: CGFloat = 22, glyphHeight: CGFloat = 15,
         apply: @escaping (Color) -> Void) {
        self.symbol = symbol
        self.title = title
        self.colour = colour
        self.palette = palette
        self.ink = ink
        self.chevronInk = chevronInk
        self.size = size
        self.box = box
        self.glyphHeight = glyphHeight
        self.apply = apply
    }

    var body: some View {
        HStack(spacing: 2) {
            Button { apply(colour) } label: {
                VStack(spacing: 1) {
                    Image(systemName: symbol).font(.system(size: size, weight: .regular)).foregroundStyle(ink).frame(height: glyphHeight)
                    RoundedRectangle(cornerRadius: 1).fill(colour).frame(width: 16, height: 3)
                }
                .frame(width: box, height: box)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
            Menu {
                ForEach(palette, id: \.0) { entry in
                    Button(entry.0) { apply(entry.1) }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(chevronInk)
                    .frame(width: 10, height: box).contentShape(Rectangle())
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
    var height: CGFloat = 22
    var textSize: CGFloat = 13
    var inset: CGFloat = 7
    var fill = OLColor.ribbonField
    var edge: Color?
    @ViewBuilder var menu: () -> Content

    var body: some View {
        Menu { menu() } label: {
            HStack(spacing: 4) {
                Text(text).font(.system(size: textSize)).foregroundStyle(OLColor.text).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(OLColor.ribbonLabel)
            }
            .padding(.horizontal, inset)
            .frame(width: width, height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: 3))
            .overlay {
                if let edge { RoundedRectangle(cornerRadius: 4).strokeBorder(edge, lineWidth: 1) }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The line between format groups: eighteen points of the twenty-two point row, as Outlook's.
struct FmtSeparator: View {
    var body: some View {
        Rectangle().fill(OLColor.ribbonSeparator).frame(width: 1, height: 18).padding(.horizontal, 8)
    }
}
