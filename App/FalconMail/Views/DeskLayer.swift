import SwiftUI
import AppKit
import FalconCore

/// Legacy Outlook's own little window manager while its mailbox window fills the screen: an
/// opened message or a message being written is not a macOS window of its own but is drawn inside
/// the mailbox window, over the mailbox and above the status bar, with its own buttons, title and
/// ribbon. One stands in the middle at its own size, two stand side by side, and one minimised is
/// a tab in the status bar; clicking the tab brings it back beside the other. Each stays alive
/// while it is a tab, so a message being written keeps what was typed.
struct DeskLayer: View {
    @ObservedObject var tray = WindowTray.shared
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            let area = CGRect(origin: .zero, size: proxy.size)
            // Left to right in the order they were opened, as Outlook lays them out.
            let showing = tray.deskMounted.filter { tray.deskShowing.contains($0) }
            let frames = FullScreenLayout.frames(for: showing.map(FullScreenItems.openingSize), in: area)
            ZStack(alignment: .topLeading) {
                ForEach(tray.deskMounted, id: \.self) { key in
                    let index = showing.firstIndex(of: key)
                    let frame = index.map { frames[$0] } ?? CGRect(x: area.midX, y: area.midY, width: 1, height: 1)
                    DeskPanel(key: key)
                        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                        .offset(x: frame.minX, y: frame.minY)
                        .opacity(index == nil ? 0 : 1)
                        .allowsHitTesting(index != nil)
                        .zIndex(Double(tray.deskShowing.firstIndex(of: key) ?? -1))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(.easeOut(duration: 0.2), value: tray.deskShowing)
        }
    }
}

/// One message or message being written inside the mailbox window: its own traffic lights over
/// its own title row, as its window would have.
struct DeskPanel: View {
    @ObservedObject var tray = WindowTray.shared
    @Environment(AppModel.self) private var model
    let key: PopupKey

    private var inFront: Bool { tray.deskShowing.last == key }

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(OLColor.chromeLine, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                DeskTrafficLights(active: inFront,
                                  close: { close() },
                                  minimise: { tray.deskMinimise(key) })
                    .padding(.leading, 12)
                    .frame(height: OL.titleRow)
            }
            .shadow(color: .black.opacity(inFront ? 0.45 : 0.25), radius: inFront ? 22 : 12, y: 8)
            .simultaneousGesture(TapGesture().onEnded { tray.deskFront(key) })
    }

    @ViewBuilder private var content: some View {
        switch key {
        case .message(let id):
            MessageWindowView(messageID: id, onClose: { close() })
        case .compose(let id):
            ComposeView(draftID: id, inDesk: true, onClose: { close() })
        }
    }

    private func close() { tray.deskClose(key) }
}

/// Red closes, yellow sends to its tab in the status bar; green is off, as Outlook's is.
struct DeskTrafficLights: View {
    let active: Bool
    let close: () -> Void
    let minimise: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            light(Color(red: 1.0, green: 0.37, blue: 0.34), symbol: "xmark", action: close)
            light(Color(red: 1.0, green: 0.74, blue: 0.18), symbol: "minus", action: minimise)
            Circle().fill(Color.gray.opacity(0.35)).frame(width: 12, height: 12)
        }
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(active || hovering ? color : Color.gray.opacity(0.45))
                if hovering {
                    Image(systemName: symbol).font(.system(size: 7, weight: .bold)).foregroundStyle(.black.opacity(0.6))
                }
            }
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
    }
}
