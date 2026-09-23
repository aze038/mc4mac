#if DEBUG
import SwiftUI
import AppKit

/// `-FalconMailSnapshot <directory>` draws the compose window's title band and ribbon, the
/// Table picker and the main window's Home ribbon, which shares the compose ribbon's tiles, in
/// both appearances into PNGs at twice their size in that directory, then quits. Nothing is
/// ever put on screen or activated, so the ribbons can be measured against Outlook's while the
/// Mac is in use. Run it with CFFIXED_USER_HOME pointing at an empty folder, so the model reads
/// no mail.
enum ComposeSnapshot {
    @MainActor static func runIfRequested() {
        guard let directory = UserDefaults.standard.string(forKey: "FalconMailSnapshot") else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        // A body that exists but has not been clicked, as in a fresh message.
        let formatter = TextFormatter()
        formatter.attach(ComposeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200)))
        let model = AppModel()
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            render(ribbon(formatter), size: NSSize(width: OL.composeWindowWidth, height: 160), appearance: appearance,
                   to: "\(directory)/ribbon-\(name).png")
            // The menu material's own grey, as it shows over a compose window.
            let ground = name == "dark" ? Color(red: 85 / 255, green: 84 / 255, blue: 90 / 255)
                                        : Color(red: 223 / 255, green: 222 / 255, blue: 228 / 255)
            render(picker.background(ground), size: NSSize(width: 220, height: 240), appearance: appearance,
                   to: "\(directory)/picker-\(name).png")
            render(CommandBar().environment(model).frame(maxHeight: .infinity, alignment: .top),
                   size: NSSize(width: 1728, height: 140), appearance: appearance,
                   to: "\(directory)/home-\(name).png")
        }
        exit(0)
    }

    @MainActor private static func ribbon(_ formatter: TextFormatter) -> some View {
        VStack(spacing: 0) {
            OLColor.chrome.frame(height: OL.titleRow)
            ComposeRibbon(tab: .constant(.message), formatter: formatter, showsBcc: .constant(false),
                          importance: .constant("normal"), canSend: false, onSend: {}, onAttachFile: {},
                          onAttachFromDrive: {}, signatures: [], onInsertSignature: { _ in }, onEditSignatures: {},
                          onInsertTableDialog: {}, onCycleBackground: {})
            Rectangle().fill(OLColor.chromeLine).frame(height: 1)
            OLColor.sidebar
        }
    }

    @MainActor private static var picker: some View {
        let selection = TableGridSelection()
        selection.hovered = TableSize(columns: 3, rows: 4)
        return TableGridPicker(selection: selection, insert: { _ in }, insertCustom: {})
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @MainActor private static func render(_ view: some View, size: NSSize, appearance: NSAppearance.Name, to path: String) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
