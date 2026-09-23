import SwiftUI
import AppKit

struct ComposeFieldRow<Content: View, Trailing: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    /// Outlook's header row: the label right-aligned to fifty-six points, the field from sixty-eight,
    /// nineteen points tall on the window's ground with a one point border, twenty-five points a row.
    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: OL.composeLabelFont))
                .foregroundStyle(OLColor.text)
                .lineLimit(1)
                .frame(width: OL.composeLabelRight, alignment: .trailing)
            content()
                .font(.system(size: OL.composeLabelFont))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, OL.composeTextInset)
                .frame(height: OL.composeField)
                .background(OLColor.reading, in: RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(OLColor.fieldBorder, lineWidth: 1))
                .padding(.leading, OL.composeFieldX - OL.composeLabelRight)
            trailing()
        }
        .frame(height: OL.composeRowPitch, alignment: .top)
    }
}

extension OL {
    /// How far a header field's text sits inside its box.
    static let composeTextInset: CGFloat = 6
}

extension ComposeFieldRow where Trailing == EmptyView {
    init(label: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(label: label, content: content, trailing: { EmptyView() })
    }
}

struct AddressBookButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "book")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(OLColor.icon)
                .frame(width: OL.composeBookGlyph, height: OL.composeField)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Address book")
    }
}

struct InlineAction: View {
    let title: String
    let symbol: String
    var prominent = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14, weight: .light))
                Text(title).font(.system(size: 13))
            }
            .foregroundStyle(prominent && enabled ? Color.accentColor : Color.primary.opacity(enabled ? 0.85 : 0.35))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(hovering && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// The single-row toolbar the modern Outlook compose pane shows under the header fields.
struct InlineFormatBar: View {
    var formatter: TextFormatter

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar
            ScrollView(.horizontal, showsIndicators: false) { bar }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var bar: some View {
        HStack(spacing: 4) {
            Picker("", selection: Binding(get: { formatter.fontName }, set: { formatter.setFontName($0) })) {
                ForEach(TextFormatter.families, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 124).controlSize(.small)

            Picker("", selection: Binding(get: { formatter.fontSize }, set: { formatter.setFontSize($0) })) {
                ForEach(TextFormatter.sizes, id: \.self) { Text("\(Int($0))").tag($0) }
            }
            .labelsHidden().frame(width: 58).controlSize(.small)

            ColorPicker("", selection: Binding(get: { formatter.textColour }, set: { formatter.setTextColour($0) }), supportsOpacity: false)
                .labelsHidden().frame(width: 34).help("Text colour")

            Divider().frame(height: 16)
            FmtButton("bold", "Bold") { formatter.toggleBold() }
            FmtButton("italic", "Italic") { formatter.toggleItalic() }
            FmtButton("underline", "Underline") { formatter.toggleUnderline() }
            FmtButton("strikethrough", "Strikethrough") { formatter.toggleStrikethrough() }
            ColorPicker("", selection: Binding(get: { formatter.highlight }, set: { formatter.setHighlight($0) }), supportsOpacity: false)
                .labelsHidden().frame(width: 34).help("Highlight")
            FmtButton("textformat.superscript", "Superscript") { formatter.setBaseline(6) }
            FmtButton("textformat.subscript", "Subscript") { formatter.setBaseline(-4) }

            Divider().frame(height: 16)
            FmtButton("list.bullet", "Bulleted list") { formatter.applyList(.disc) }
            FmtButton("list.number", "Numbered list") { formatter.applyList(.decimal) }
            Menu {
                Button("Align Left") { formatter.align(.left) }
                Button("Centre") { formatter.align(.center) }
                Button("Align Right") { formatter.align(.right) }
                Button("Justify") { formatter.align(.justified) }
            } label: {
                Image(systemName: "text.alignleft").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).fixedSize().help("Alignment")
            FmtButton("decrease.indent", "Decrease indent") { formatter.changeIndent(by: -24) }
            FmtButton("increase.indent", "Increase indent") { formatter.changeIndent(by: 24) }

            Divider().frame(height: 16)
            FmtButton("photo", "Insert picture") { formatter.insertPicture() }
            FmtButton("link", "Insert link") { formatter.insertLink() }
            Menu {
                Button("Insert 3 × 3") { formatter.insertTable(rows: 3, columns: 3) }
                Button("Insert 4 × 4") { formatter.insertTable(rows: 4, columns: 4) }
                Button("Insert 2 × 5") { formatter.insertTable(rows: 2, columns: 5) }
            } label: {
                Image(systemName: "tablecells").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).fixedSize().help("Insert table")

            Divider().frame(height: 16)
            FmtButton("textformat.abc.dottedunderline", "Check spelling") { formatter.checkSpelling() }
            FmtButton("eraser", "Clear formatting") { formatter.clearFormatting() }
            Menu {
                Button("Paste and Match FalconMail") { formatter.pasteMatchingStyle() }
                Button("Paste Keeping Source Formatting") { formatter.pasteKeepingSource() }
                Button("Paste as Plain Text") { formatter.pastePlain() }
            } label: {
                Image(systemName: "doc.on.clipboard").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).fixedSize().help("Paste options")
            FmtButton("arrow.uturn.backward", "Undo") { formatter.editor?.undoManager?.undo() }
            FmtButton("arrow.uturn.forward", "Redo") { formatter.editor?.undoManager?.redo() }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
