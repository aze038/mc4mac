import Foundation

/// Where a panel that drops from a control goes on screen, in AppKit's screen coordinates
/// (origin at the bottom left): as a menu would, whole on the screen however near its edge the
/// control stands.
public enum PopupPlacement {
    /// Under `control`, left edges aligned and rising `overlap` points into the control's foot;
    /// moved left as far as it must to end at the screen's right edge but never past its left
    /// edge, and above the control when there is no room below it.
    public static func frame(size: CGSize, below control: CGRect, overlap: CGFloat, on screen: CGRect) -> CGRect {
        var x = min(control.minX, screen.maxX - size.width)
        x = max(x, screen.minX)
        var y = control.minY + overlap - size.height
        if y < screen.minY { y = control.maxY }
        y = max(min(y, screen.maxY - size.height), screen.minY)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
