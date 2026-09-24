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
    ///
    /// A colour already in calibrated RGB keeps its values. Word, Excel and Outlook put RTF on
    /// the pasteboard with a plain colour table, whose values are the sRGB colours chosen there,
    /// and AppKit reads that table as calibrated RGB, as the draft's and a signature's RTF then
    /// keep it: pasted text, table shading and lines and a signature designed in Word go out in
    /// Office's own colours only if those values are written as they are. Nothing in the app
    /// makes a calibrated colour itself, so only one picked in the colour panel's Generic RGB
    /// goes out by its values rather than as it looks.
    static func forWriter(_ colour: NSColor) -> NSColor {
        let fromOffice = colour.type == .componentBased && colour.colorSpace == .genericRGB
        guard let values = fromOffice ? colour : inSRGB(colour) else { return colour }
        return NSColor(calibratedRed: byte(values.redComponent), green: byte(values.greenComponent),
                       blue: byte(values.blueComponent), alpha: values.alphaComponent)
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
