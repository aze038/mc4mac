import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FalconCore

/// Laid over an attachment's chip in a message, so that the chip, not the window, is what the
/// mouse drags. Message and mailbox windows move by their background (see PopupWindowAccessor),
/// and a SwiftUI chip does not tell AppKit it is anything but background, so pressing on one and
/// dragging moved the whole window. This view keeps the press for itself and starts an AppKit
/// drag of the file, as Outlook's attachment well does: onto a compose window it attaches, onto
/// Finder or the Desktop it makes the file.
struct AttachmentDragHandle: NSViewRepresentable {
    struct MenuItem {
        var title: String
        var enabled = true
        var action: () -> Void
    }

    /// What the drag carries.
    enum Content {
        /// A file already on disk (written to the attachments' temporary folder when asked for).
        case file(() -> URL?)
        /// A file not yet downloaded, written when it is dropped: `fetch` hands over its bytes,
        /// or nil when they cannot be had.
        case promise(filename: String, mimeType: String, fetch: (@escaping (Data?) -> Void) -> Void)
    }

    var filename: String
    var content: Content
    var help: String? = nil
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var menu: [MenuItem] = []

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        update(view)
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) { update(view) }

    private func update(_ view: HandleView) {
        view.filename = filename
        view.content = content
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.menuItems = menu
        view.toolTip = help
    }

    final class HandleView: NSView, NSDraggingSource {
        var filename = ""
        var content: Content = .file({ nil })
        var onClick: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        var menuItems: [MenuItem] = []
        private var downEvent: NSEvent?
        /// The promise's provider holds its writer weakly, and the file may be asked for after
        /// the drag has ended, so the last one is kept until the next drag.
        private var promiseWriter: PromiseWriter?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // Control-click is the context menu, as a right-click is.
            if event.modifierFlags.contains(.control) {
                if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
                return
            }
            downEvent = event
            if event.clickCount >= 2 { onDoubleClick() } else { onClick() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent else { return }
            let start = down.locationInWindow, now = event.locationInWindow
            // AppKit's own threshold, so a click that wobbles is still a click.
            guard hypot(now.x - start.x, now.y - start.y) >= 3 else { return }
            downEvent = nil
            beginDrag(with: down)
        }

        override func mouseUp(with event: NSEvent) { downEvent = nil }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard !menuItems.isEmpty else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in menuItems {
                let item = NSMenuItem(title: entry.title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.isEnabled = entry.enabled
                item.representedObject = MenuAction(entry.action)
                menu.addItem(item)
            }
            return menu
        }

        @objc private func runMenuItem(_ item: NSMenuItem) { (item.representedObject as? MenuAction)?.run() }

        private func beginDrag(with event: NSEvent) {
            let writer: NSPasteboardWriting
            let type: UTType
            switch content {
            case .file(let file):
                guard let url = file() else { return }
                writer = url as NSURL
                type = UTType(filenameExtension: url.pathExtension) ?? .data
            case .promise(let name, let mimeType, let fetch):
                type = UTType(filenameExtension: (name as NSString).pathExtension) ?? UTType(mimeType: mimeType) ?? .data
                let promised = PromiseWriter(filename: name, fetch: fetch)
                promiseWriter = promised
                writer = NSFilePromiseProvider(fileType: type.identifier, delegate: promised)
            }
            let item = NSDraggingItem(pasteboardWriter: writer)
            let icon = NSWorkspace.shared.icon(for: type)
            let side: CGFloat = 32
            let at = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: at.x - side / 2, y: at.y - side / 2, width: side, height: side), contents: icon)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }

    private final class MenuAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    /// Writes a promised attachment where it is dropped, downloading it first.
    final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate {
        let filename: String
        let fetch: (@escaping (Data?) -> Void) -> Void

        init(filename: String, fetch: @escaping (@escaping (Data?) -> Void) -> Void) {
            let safe = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            self.filename = safe.isEmpty ? "attachment" : safe
            self.fetch = fetch
        }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { filename }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            fetch { data in
                guard let data else { completionHandler(CocoaError(.fileReadUnknown)); return }
                do {
                    try data.write(to: url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }
}

/// Takes the files dragged onto a compose window, however they come, and hands them over as
/// attachments; never as text. Laid over the header fields, which would otherwise take a file
/// drag themselves and type its path or a file:// link, and behind the whole window for the
/// parts that are not AppKit views (the body takes its own, see ComposeTextView). It lets every
/// click through, and takes only drags that carry files, so text dragged into a field still goes
/// where it is dropped.
struct ComposeFileDropTarget: NSViewRepresentable {
    @Binding var targeted: Bool
    var onAttachments: ([OutgoingAttachment]) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        update(view)
        return view
    }

    func updateNSView(_ view: DropView, context: Context) { update(view) }

    private func update(_ view: DropView) {
        let binding = _targeted
        view.onTargeted = { value in if binding.wrappedValue != value { binding.wrappedValue = value } }
        view.onAttachments = onAttachments
    }

    final class DropView: NSView {
        var onTargeted: (Bool) -> Void = { _ in }
        var onAttachments: ([OutgoingAttachment]) -> Void = { _ in }

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes(ComposeFileDrop.draggedTypes)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            registerForDraggedTypes(ComposeFileDrop.draggedTypes)
        }

        /// Clicks, scrolling and typing go to what lies beneath; drags find this view by the
        /// types it is registered for.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var mouseDownCanMoveWindow: Bool { false }

        private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
            guard ComposeFileDrop.takesAsAttachments(sender) else { return [] }
            onTargeted(true)
            return .copy
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted(false) }
        override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted(false) }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            ComposeFileDrop.takesAsAttachments(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onTargeted(false)
            return ComposeFileDrop.receive(sender.draggingPasteboard, deliver: onAttachments)
        }
    }
}

/// Reads the files off a drag or a pasteboard: files named outright are read at once, files
/// promised (from Mail, Outlook, a message not yet downloaded) are written into the attachments'
/// temporary folder first and handed over as each arrives.
enum ComposeFileDrop {
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        var types = DroppedFiles.types.map { NSPasteboard.PasteboardType(rawValue: $0) }
        for type in NSFilePromiseReceiver.readableDraggedTypes.map({ NSPasteboard.PasteboardType(rawValue: $0) }) where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        return DroppedFiles.carriesFiles(types) || NSFilePromiseReceiver.readableDraggedTypes.contains { types.contains($0) }
    }

    /// Whether a drag is files to attach: it carries files, and is not text or a picture
    /// dragged out of a text, such as a picture moved within the body, which the text keeps.
    static func takesAsAttachments(_ sender: NSDraggingInfo) -> Bool {
        !(sender.draggingSource is NSTextView) && carriesFiles(sender.draggingPasteboard)
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Whether the pasteboard held files; `deliver` is called on the main queue with their
    /// attachments, once for files named outright and once per promised file.
    @discardableResult
    static func receive(_ pasteboard: NSPasteboard, deliver: @escaping ([OutgoingAttachment]) -> Void) -> Bool {
        let urls = DroppedFiles.fileURLs(in: pasteboard.pasteboardItems ?? [])
        if !urls.isEmpty {
            let made = DroppedFiles.attachments(from: urls)
            DispatchQueue.main.async { deliver(made) }
            return true
        }
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        guard !receivers.isEmpty else { return false }
        let folder = AttachmentTempFiles.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { url, error in
                guard error == nil else { return }
                let made = DroppedFiles.attachments(from: [url])
                guard !made.isEmpty else { return }
                DispatchQueue.main.async { deliver(made) }
            }
        }
        return true
    }
}
