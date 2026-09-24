import AppKit

/// Colours as the HTML that is sent must hold them: as the sRGB a mail reader takes every
/// `#rrggbb` to be.
///
/// AppKit's HTML writer does not write a colour's sRGB value. It converts every colour to
/// calibrated (generic) RGB and writes those components, so sRGB's pure red goes out as #fb0007,
/// its yellow as #ffff0b and a mid grey of #808080 as #6d6d6d, and every colour a reader shows
/// is a little off the one that was chosen. A colour already in calibrated RGB is written as it
/// is, so each colour is taken to sRGB first and its components handed to the writer as
/// calibrated RGB, which it then puts down unchanged.
enum SentColour {
    /// `colour` as the writer must be given it to write down its sRGB value: a colour chosen in
    /// another space, such as Display P3 or a grey, as it looks in sRGB, and one that follows
    /// the appearance as it looks in light, on the white page a message is read on unless the
    /// reader says otherwise. A pattern, which has no one colour, is left as it is.
    static func forWriter(_ colour: NSColor) -> NSColor {
        guard let sRGB = inSRGB(colour) else { return colour }
        return NSColor(calibratedRed: byte(sRGB.redComponent), green: byte(sRGB.greenComponent),
                       blue: byte(sRGB.blueComponent), alpha: sRGB.alphaComponent)
    }

    /// `colour` in sRGB, resolved for the light appearance when it follows the appearance.
    static func inSRGB(_ colour: NSColor) -> NSColor? {
        guard colour.type == .catalog, let light = NSAppearance(named: .aqua) else { return colour.usingColorSpace(.sRGB) }
        var resolved: NSColor?
        light.performAsCurrentDrawingAppearance { resolved = colour.usingColorSpace(.sRGB) }
        return resolved
    }

    /// The value, within the colour's gamut, rounded to the nearest of the 256 steps a hex
    /// colour has, which the writer then has no rounding of its own to do.
    private static func byte(_ component: CGFloat) -> CGFloat {
        (min(max(component, 0), 1) * 255).rounded() / 255
    }
}
