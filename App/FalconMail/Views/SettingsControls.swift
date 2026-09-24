import SwiftUI
import AppKit

/// Legacy Outlook's settings windows, measured.
///
/// Outlook is built against an older macOS, so it still draws the checkboxes, radio buttons,
/// pop-ups, buttons and boxes AppKit drew before macOS 26; FalconMail, built against the
/// current one, would get the new ones. These are the old ones drawn to Outlook's pixels. The
/// dark colours were read off captures of Outlook's windows at 2x, over a wallpaper that tints
/// them slightly blue as macOS does; the light ones are the same surfaces in the system's light
/// colours.
enum Classic {
    static func colour(light: Int, dark: Int) -> Color { OLColor.dynamic(light: light, dark: dark) }

    static func nsColour(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    // The window: title bar, its line, and the ground the panes stand on.
    static let titleBar = colour(light: 0xE8E8E8, dark: 0x373841)
    static let titleBarInactive = colour(light: 0xF6F6F6, dark: 0x282A36)
    static let titleText = colour(light: 0x262626, dark: 0xEBEBEC)
    static let titleTextInactive = colour(light: 0xB4B4B4, dark: 0x6A6C78)
    static let toolbarLine = colour(light: 0xC4C4C4, dark: 0x000000)
    static let toolbarLineShade = colour(light: 0xDADADA, dark: 0x1E1F28)
    static let showAllText = colour(light: 0x5A5A5A, dark: 0xB7B8C1)
    static let showAllTextInactive = colour(light: 0xB4B4B4, dark: 0x686A76)
    static let showAllBorder = colour(light: 0xC8C8C8, dark: 0x44454E)
    static let showAllBorderInactive = colour(light: 0xDCDCDC, dark: 0x353743)
    static let pane = colour(light: 0xECECEC, dark: 0x282A36)
    static let label = colour(light: 0x262626, dark: 0xDFDFE1)

    // The icon grid's three bands, alternately darker and lighter, each closed by a lighter line.
    static let bandDark = colour(light: 0xECECEC, dark: 0x303335)
    static let bandLight = colour(light: 0xE4E4E4, dark: 0x37393B)
    static let bandDarkLine = colour(light: 0xD4D4D4, dark: 0x444649)
    static let bandLightLine = colour(light: 0xCDCDCD, dark: 0x4B4C4F)

    // A group box.
    static let boxFill = colour(light: 0xE3E3E3, dark: 0x2B2D39)
    static let boxBorder = colour(light: 0xCACACA, dark: 0x444651)

    // Checkboxes and radio buttons: the accent when on, from the top of the box to the bottom.
    static let onTop = nsColour(light: 0x2A8BFF, dark: 0x3267DD)
    static let onBottom = nsColour(light: 0x0A6FF0, dark: 0x2D5DC7)
    static let offTop = nsColour(light: 0xFFFFFF, dark: 0x4B4D57)
    static let offBottom = nsColour(light: 0xFFFFFF, dark: 0x676871)
    static let offRim = nsColour(light: 0xB9B9B9, dark: 0x6D6E76)
    static let mark = nsColour(light: 0xFFFFFF, dark: 0xDEE7F7)
    static let controlShadow = nsColour(light: 0xC8C8C8, dark: 0x22242E)

    // Pop-ups and push buttons.
    static let buttonFill = nsColour(light: 0xFFFFFF, dark: 0x5E5F68)
    static let buttonHighlight = nsColour(light: 0xFFFFFF, dark: 0x7E7F86)
    static let smallPopUpFill = nsColour(light: 0xFFFFFF, dark: 0x60626B)
    static let smallPopUpHighlight = nsColour(light: 0xFFFFFF, dark: 0x808188)
    /// A small pop-up's cap sits in a darker ring, heavier under it, and has a lighter top edge.
    static let smallCapRingTop = nsColour(light: 0xC8C8C8, dark: 0x51535B)
    static let smallCapRingBottom = nsColour(light: 0xB4B4B4, dark: 0x47484F)
    static let smallCapShade = nsColour(light: 0xCFCFCF, dark: 0x55575F)
    static let smallCapTop = nsColour(light: 0x5AA2FF, dark: 0x6A95E8)
    static let buttonText = nsColour(light: 0x262626, dark: 0xE3E3E4)
}

// MARK: - placing things where Outlook has them

extension View {
    /// Puts the view's top-left corner at `x`, `y` of the enclosing `Placements`.
    func at(x: CGFloat, y: CGFloat) -> some View {
        alignmentGuide(.leading) { _ in -x }.alignmentGuide(.top) { _ in -y }
    }

    /// Puts the view's first text baseline at `baseline` and its left edge at `x`: positions read
    /// off a capture are baselines, not boxes.
    func at(x: CGFloat, baseline: CGFloat) -> some View {
        alignmentGuide(.leading) { _ in -x }.alignmentGuide(.top) { $0[.firstTextBaseline] - baseline }
    }

    /// Centres the view's text on `x` with its baseline at `baseline`.
    func at(centreX x: CGFloat, baseline: CGFloat) -> some View {
        alignmentGuide(.leading) { $0.width / 2 - x }.alignmentGuide(.top) { $0[.firstTextBaseline] - baseline }
    }

    /// Right-aligns the view's text on `x` with its baseline at `baseline`.
    func at(rightX x: CGFloat, baseline: CGFloat) -> some View {
        alignmentGuide(.leading) { $0.width - x }.alignmentGuide(.top) { $0[.firstTextBaseline] - baseline }
    }
}

/// Lets a window be dragged by a title bar drawn in its content, as by one of its own; what is
/// drawn over it, such as Show All, still takes its own clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// A fixed-size page whose children are placed with `at`, as a nib lays its views out.
struct Placements<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: width, height: height)
            content()
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// Text as the panes set it: the system font, in the label colour.
struct ClassicText: View {
    let text: String
    var size: CGFloat = 13
    var weight: Font.Weight = .regular

    init(_ text: String, size: CGFloat = 13, weight: Font.Weight = .regular) {
        self.text = text
        self.size = size
        self.weight = weight
    }

    var body: some View {
        Text(text).font(.system(size: size, weight: weight)).foregroundStyle(Classic.label).fixedSize()
    }
}

/// A group box: a slightly lighter ground inside a hairline, its corners rounded five points.
struct ClassicBox: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Classic.boxFill)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Classic.boxBorder, lineWidth: 0.5))
            .frame(width: width, height: height)
    }
}

// MARK: - checkbox and radio button

/// The fourteen point box or circle, lit in the accent when on and faded to half when it
/// cannot be used.
private struct MarkFace: View {
    let on: Bool
    let round: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 0.5, y: 0.5, width: 14, height: 14)
            let shape = round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 3.5)
            // A half point rim all round and a shadow under it, as AppKit drew its controls.
            let rim = rect.insetBy(dx: -0.5, dy: -0.5)
            context.fill(round ? Path(ellipseIn: rim) : Path(roundedRect: rim, cornerRadius: 4),
                         with: .color(Color(nsColor: Classic.controlShadow).opacity(0.35)))
            var shadow = context
            shadow.translateBy(x: 0, y: 0.75)
            shadow.fill(shape, with: .color(Color(nsColor: Classic.controlShadow).opacity(0.8)))
            let top = on ? Classic.onTop : Classic.offTop
            let bottom = on ? Classic.onBottom : Classic.offBottom
            context.fill(shape, with: .linearGradient(Gradient(colors: [Color(nsColor: top), Color(nsColor: bottom)]),
                                                     startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            if !on { context.stroke(shape.strokedPath(StrokeStyle(lineWidth: 0.5)), with: .color(Color(nsColor: Classic.offRim).opacity(0.5))) }
            guard on else { return }
            if round {
                context.fill(Path(ellipseIn: CGRect(x: 4.5, y: 4.5, width: 6, height: 6)), with: .color(Color(nsColor: Classic.mark)))
            } else {
                var tick = Path()
                tick.move(to: CGPoint(x: 4.1, y: 7.9))
                tick.addLine(to: CGPoint(x: 6.5, y: 10.8))
                tick.addLine(to: CGPoint(x: 11.3, y: 4.2))
                context.stroke(tick, with: .color(Color(nsColor: Classic.mark)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 15, height: 16)
        .padding(.leading, -0.5)
        .padding(.top, -0.5)
        .padding(.trailing, -0.5)
        .padding(.bottom, -1.5)
        .opacity(enabled ? 1 : 0.5)
        .alignmentGuide(.firstTextBaseline) { _ in 12 }
    }
}

/// A checkbox with its label six points to its right, its baseline twelve points below the
/// box's top, as every checkbox in Outlook's panes stands.
struct ClassicCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                MarkFace(on: isOn, round: false)
                ClassicText(title).opacity(enabled ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(title, isOn: $isOn) }
    }
}

/// One radio button of a group, laid out as the checkbox is.
struct ClassicRadio: View {
    let title: String
    let selected: Bool
    let choose: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                MarkFace(on: selected, round: true)
                ClassicText(title).opacity(enabled ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - push button

/// A rounded push button twenty points tall, its title centred in thirteen points.
struct ClassicButton: View {
    let title: String
    let width: CGFloat
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            ZStack {
                ClassicBezel(highlight: Classic.buttonHighlight, fill: Classic.buttonFill, radius: 5)
                Text(title).font(.system(size: 13)).foregroundStyle(Color(nsColor: Classic.buttonText))
                    .opacity(enabled ? 1 : 0.5)
                    .offset(y: -0.5)
            }
            .frame(width: width, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// A pop-up's or button's face: a flat fill, a lighter line along its top, a dark hairline
/// under it.
struct ClassicBezel: View {
    let highlight: NSColor
    let fill: NSColor
    let radius: CGFloat

    var body: some View {
        Canvas { context, size in
            let body = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius)
            var under = context
            under.translateBy(x: 0, y: 0.5)
            under.fill(body, with: .color(Color(nsColor: Classic.controlShadow)))
            context.fill(body, with: .color(Color(nsColor: highlight)))
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0.5, width: size.width, height: size.height - 0.5), cornerRadius: radius),
                         with: .color(Color(nsColor: fill)))
        }
    }
}

// MARK: - pop-up

/// An AppKit pop-up button, so its menu opens over it with the choice under the pointer, drawn
/// as Outlook's: the choice in thirteen points (eleven in a small one) and a blue cap holding
/// the arrows that loses its colour when the window is not in front.
struct ClassicPopUp<Tag: Hashable>: NSViewRepresentable {
    let title: String
    let items: [(String, Tag)]
    @Binding var selection: Tag
    var small = false
    @Environment(\.controlActiveState) private var activeState

    static var regularHeight: CGFloat { 20.5 }
    static var smallHeight: CGFloat { 16.5 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = ClassicPopUpButton(frame: .zero, pullsDown: false)
        let cell = ClassicPopUpCell(textCell: "", pullsDown: false)
        cell.small = small
        button.cell = cell
        button.target = context.coordinator
        button.action = #selector(Coordinator.chosen(_:))
        button.setAccessibilityLabel(title)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.isEnabled = context.environment.isEnabled
        (button.cell as? ClassicPopUpCell)?.active = activeState != .inactive
        let coordinator = context.coordinator
        coordinator.tags = items.map(\.1)
        coordinator.choose = { selection = $0 }
        let titles = items.map(\.0)
        if button.itemTitles != titles {
            button.removeAllItems()
            // Added one by one, so two entries of the same name both stay in the menu.
            for title in titles {
                button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        if let index = items.firstIndex(where: { $0.1 == selection }), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
        button.needsDisplay = true
    }

    final class Coordinator: NSObject {
        var tags: [Tag] = []
        var choose: (Tag) -> Void = { _ in }

        @objc func chosen(_ button: NSPopUpButton) {
            let index = button.indexOfSelectedItem
            guard tags.indices.contains(index) else { return }
            choose(tags[index])
        }
    }
}

/// Takes exactly the frame it is given: AppKit's own pop-up keeps its own height and a margin
/// round its bezel, which would put the drawn one off the measured position.
final class ClassicPopUpButton: NSPopUpButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

/// Draws the whole pop-up itself; AppKit's own drawing is the new one.
final class ClassicPopUpCell: NSPopUpButtonCell {
    var small = false
    var active = true

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let flipped = controlView.isFlipped
        let bodyHeight: CGFloat = small ? 16 : 20
        let radius: CGFloat = small ? 4 : 5
        let top = flipped ? cellFrame.minY : cellFrame.maxY - bodyHeight
        let body = NSRect(x: cellFrame.minX, y: top, width: cellFrame.width, height: bodyHeight)
        let under = body.offsetBy(dx: 0, dy: flipped ? 0.5 : -0.5)
        Classic.controlShadow.setFill()
        NSBezierPath(roundedRect: under, xRadius: radius, yRadius: radius).fill()
        (small ? Classic.smallPopUpHighlight : Classic.buttonHighlight).setFill()
        NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).fill()
        let lower = NSRect(x: body.minX, y: flipped ? body.minY + 0.5 : body.minY, width: body.width, height: body.height - 0.5)
        (small ? Classic.smallPopUpFill : Classic.buttonFill).setFill()
        NSBezierPath(roundedRect: lower, xRadius: radius, yRadius: radius).fill()
        drawCap(in: body, flipped: flipped)
        drawChoice(in: body, flipped: flipped)
    }

    private func drawCap(in body: NSRect, flipped: Bool) {
        let width: CGFloat = small ? 12 : 16
        let height: CGFloat = small ? 12 : 16
        let cap = NSRect(x: body.maxX - 2 - width, y: body.midY - height / 2, width: width, height: height)
        let direction: CGFloat = flipped ? 1 : -1
        let radius: CGFloat = small ? 3 : 4
        if active, isEnabled {
            let shape = NSBezierPath(roundedRect: cap, xRadius: radius, yRadius: radius)
            if small {
                let ring = cap.insetBy(dx: -0.5, dy: -0.5)
                Classic.smallCapShade.setFill()
                NSBezierPath(roundedRect: ring.offsetBy(dx: 0, dy: direction * 0.5), xRadius: radius + 0.5, yRadius: radius + 0.5).fill()
                NSGradient(starting: Classic.smallCapRingTop, ending: Classic.smallCapRingBottom)?
                    .draw(in: NSBezierPath(roundedRect: ring, xRadius: radius + 0.5, yRadius: radius + 0.5), angle: flipped ? 90 : -90)
            }
            let gradient = NSGradient(starting: Classic.onTop, ending: Classic.onBottom)
            gradient?.draw(in: shape, angle: flipped ? 90 : -90)
            if small {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                Classic.smallCapTop.setFill()
                NSRect(x: cap.minX, y: flipped ? cap.minY : cap.maxY - 0.5, width: cap.width, height: 0.5).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            Classic.mark.setStroke()
        } else {
            Classic.buttonText.withAlphaComponent(isEnabled ? 1 : 0.5).setStroke()
        }
        let reach: CGFloat = small ? 1.5 : 3
        let near: CGFloat = small ? 1.3 : 1.8
        let far: CGFloat = small ? 3.25 : 5
        let arrows = NSBezierPath()
        for sign in [-1.0, 1.0] as [CGFloat] {
            arrows.move(to: NSPoint(x: cap.midX - reach, y: cap.midY + sign * direction * near))
            arrows.line(to: NSPoint(x: cap.midX, y: cap.midY + sign * direction * far))
            arrows.line(to: NSPoint(x: cap.midX + reach, y: cap.midY + sign * direction * near))
        }
        arrows.lineWidth = small ? 1.2 : 1.5
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round
        arrows.stroke()
    }

    private func drawChoice(in body: NSRect, flipped: Bool) {
        let font = NSFont.systemFont(ofSize: small ? 11 : 13)
        let colour = Classic.buttonText.withAlphaComponent(isEnabled ? 1 : 0.5)
        let text = NSAttributedString(string: titleOfSelectedItem ?? "", attributes: [.font: font, .foregroundColor: colour])
        // Baselines twelve points into a small pop-up and fourteen into a regular one.
        let baseline: CGFloat = small ? 12 : 14
        let inset: CGFloat = small ? 6 : 8
        let limit = body.width - inset - (small ? 18 : 22)
        let y = flipped ? body.minY + baseline - font.ascender : body.maxY - baseline + font.descender
        text.draw(with: NSRect(x: body.minX + inset, y: y, width: max(0, limit), height: font.ascender - font.descender),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - the sound rows' play button

/// A square button with a chevron, twenty-three points by eighteen, that plays a sound.
struct ClassicPlayButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .color(Classic.colour(light: 0xC6C6C6, dark: 0x60626B)))
                context.fill(Path(rect.insetBy(dx: 1, dy: 1)),
                             with: .linearGradient(Gradient(colors: [Classic.colour(light: 0xFCFCFC, dark: 0x4B4C57),
                                                                     Classic.colour(light: 0xF0F0F0, dark: 0x454751)]),
                                                   startPoint: CGPoint(x: 0, y: 1), endPoint: CGPoint(x: 0, y: size.height - 1)))
                var chevron = Path()
                chevron.move(to: CGPoint(x: 9.5, y: 4.5))
                chevron.addLine(to: CGPoint(x: 14, y: 9))
                chevron.addLine(to: CGPoint(x: 9.5, y: 13.5))
                context.stroke(chevron, with: .color(Classic.colour(light: 0x3C3C3C, dark: 0xE2E2E4)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 23, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
