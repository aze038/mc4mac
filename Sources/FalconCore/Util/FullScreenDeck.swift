import Foundation

/// Where Legacy Outlook puts its message and compose windows while its mailbox window fills the
/// screen: inside that window's space, over the mailbox and above the status bar, which holds a
/// tab for each one minimised. One window showing keeps its own size and stands in the middle;
/// two share the width side by side, each keeping its own height. Measured from Outlook captured
/// at 1728 × 1117 points, in AppKit's coordinates (origin at the bottom left).
public enum FullScreenLayout {
    /// Between two windows side by side, and between them and the screen's sides.
    public static let margin: CGFloat = 36
    /// The least margin two windows are given on a narrow screen before only one fits.
    public static let tightMargin: CGFloat = 12
    /// The least room kept above and below a window taller than the space.
    public static let verticalInset: CGFloat = 18
    /// The narrowest a window can be made: a compose window's least width.
    public static let narrowestWindow: CGFloat = 600
    /// The most windows showing at once. Another brought on screen sends the one in front least
    /// recently to its tab.
    public static let mostShowing = 2

    /// How many windows fit side by side in a space `width` points wide.
    public static func capacity(forWidth width: CGFloat) -> Int {
        width >= 2 * narrowestWindow + 3 * tightMargin ? mostShowing : 1
    }

    /// The frames, left to right, of windows whose own sizes are `sizes`, in `area`: the space
    /// over the mailbox window above its status bar. Each keeps its own height when it fits and
    /// stands in the middle of the space's height; one keeps its own width too, and more share
    /// the width in equal columns. Whole points, so that nothing is drawn blurred.
    public static func frames(for sizes: [CGSize], in area: CGRect) -> [CGRect] {
        guard !sizes.isEmpty else { return [] }
        let tallest = max(0, area.height - 2 * verticalInset)
        func frame(x: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
            let h = min(height, tallest).rounded(.down)
            return CGRect(x: x.rounded(), y: (area.midY - h / 2).rounded(), width: width.rounded(.down), height: h)
        }
        let n = CGFloat(sizes.count)
        if sizes.count == 1 {
            let width = max(0, min(sizes[0].width, area.width - 2 * margin))
            return [frame(x: area.midX - width / 2, width: width, height: sizes[0].height)]
        }
        var gap = margin
        if (area.width - (n + 1) * gap) / n < narrowestWindow {
            gap = max(tightMargin, (area.width - n * narrowestWindow) / (n + 1))
        }
        let width = max(0, (area.width - (n + 1) * gap) / n)
        return sizes.enumerated().map { i, size in
            frame(x: area.minX + gap + CGFloat(i) * (width + gap), width: width, height: size.height)
        }
    }

    // MARK: Tabs

    /// The status bar's room kept either side of its tabs, for the item count on the left and
    /// the state of the folders on the right.
    public static let tabSideRoom: CGFloat = 268
    /// The widest one tab is.
    public static let widestTab: CGFloat = 812
    public static let tabGap: CGFloat = 5

    /// How wide each of `count` tabs is in a band `band` points wide: as wide as it may be, and
    /// narrower when more share the band.
    public static func tabWidth(count: Int, band: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let n = CGFloat(count)
        return max(0, min(widestTab, (band - (n - 1) * tabGap) / n)).rounded(.down)
    }
}

/// Which message and compose windows show while the mailbox window fills the screen, and in which
/// order they stand, left to right. Those minimised are not here: they wait in the tray, which
/// the status bar shows as tabs.
public struct FullScreenDeck: Equatable, Sendable {
    /// The windows showing, left to right.
    public private(set) var showing: [PopupKey] = []
    /// The same windows, the one in front least recently first.
    private var recency: [PopupKey] = []

    public init() {}

    /// `key`'s window comes on screen, opened or brought back from its tab, to the right of those
    /// showing. Returns those that no longer fit, the ones in front least recently, which go to
    /// their tabs; the others keep their order. One already showing only comes to the front.
    @discardableResult
    public mutating func show(_ key: PopupKey, capacity: Int) -> [PopupKey] {
        guard !showing.contains(key) else {
            cameForward(key)
            return []
        }
        showing.append(key)
        recency.append(key)
        return fit(capacity: capacity)
    }

    /// `key`'s window became the one in front.
    public mutating func cameForward(_ key: PopupKey) {
        guard let i = recency.firstIndex(of: key) else { return }
        recency.append(recency.remove(at: i))
    }

    /// `key`'s window went to its tab or closed.
    public mutating func hide(_ key: PopupKey) {
        showing.removeAll { $0 == key }
        recency.removeAll { $0 == key }
    }

    /// A window Command-` goes round: the mailbox window, or one over it.
    public enum Stop: Equatable, Sendable {
        case mailbox
        case window(PopupKey)
    }

    /// The window Command-` brings to the front after `current`: the mailbox window, then those
    /// showing left to right, and round again; backwards with Shift. Nil when nothing but the
    /// mailbox window shows, so that it is left to macOS.
    public func next(after current: Stop, backwards: Bool) -> Stop? {
        guard !showing.isEmpty else { return nil }
        let ring = [Stop.mailbox] + showing.map(Stop.window)
        let i = ring.firstIndex(of: current) ?? 0
        return ring[(i + (backwards ? ring.count - 1 : 1)) % ring.count]
    }

    /// Sends to their tabs, least recently in front first, the windows beyond `capacity`, as when
    /// the screen narrows. The one in front stays whatever the capacity.
    @discardableResult
    public mutating func fit(capacity: Int) -> [PopupKey] {
        var sent: [PopupKey] = []
        while showing.count > max(1, capacity), let oldest = recency.first {
            hide(oldest)
            sent.append(oldest)
        }
        return sent
    }
}
