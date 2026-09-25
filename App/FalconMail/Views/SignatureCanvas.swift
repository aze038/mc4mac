import AppKit
import FalconCore

/// A signature is shown at its own size, as it is sent: never wrapped or squeezed to the width of
/// the window that shows it. Its page is as wide as the widest thing the signature holds, a line,
/// a picture or a table the HTML gave a width, or the window if that is wider; whatever does not
/// fit scrolls, across as well as down. A table as wide as a share of the page takes that share of
/// the page.
@MainActor
final class SignatureCanvas: NSObject {
    private weak var scroll: NSScrollView?
    private var fitting = false

    /// Sets up `scroll`, whose document view is the signature's text view, and keeps it fitted
    /// while its text changes and its window is resized.
    init(_ scroll: NSScrollView) {
        self.scroll = scroll
        super.init()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        guard let view = scroll.documentView as? NSTextView, let container = view.textContainer else { return }
        // TextKit 1, as the composer's: TextKit 2 draws no tables.
        _ = view.layoutManager
        container.widthTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = []
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.frameDidChangeNotification,
                                               object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSText.didChangeNotification,
                                               object: view)
        fit()
    }

    @objc private func changed(_ notification: Notification) { fit() }

    /// Lays the signature out again at its own width, or the window's if that is wider.
    func fit() {
        guard !fitting, let scroll, let view = scroll.documentView as? NSTextView, let container = view.textContainer,
              let storage = view.textStorage else { return }
        fitting = true
        defer { fitting = false }
        let inset = view.textContainerInset
        let visible = scroll.contentSize
        let own = SignatureWidth.natural(of: storage, padding: container.lineFragmentPadding)
        let width = max(visible.width - inset.width * 2, own)
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        view.minSize = NSSize(width: width + inset.width * 2, height: visible.height)
        if view.frame.width != width + inset.width * 2 {
            view.setFrameSize(NSSize(width: width + inset.width * 2, height: max(view.frame.height, visible.height)))
        }
        view.sizeToFit()
    }
}
