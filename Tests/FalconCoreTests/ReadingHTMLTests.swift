import XCTest
import AppKit
import WebKit
@testable import FalconCore

/// How the reader prepares a message's HTML for its web view: Outlook's chains shown in their
/// own fonts at Outlook's widths, words broken as Outlook breaks them, and, in dark appearance,
/// recoloured so that Outlook's black text stays readable, unless the sun switch shows the
/// message as it was written.
final class ReadingHTMLTests: XCTestCase {
    private let outlook = """
        <html><head><style>p.MsoNormal{margin:0cm;font-size:11.0pt;font-family:"Calibri",sans-serif;}</style></head>
        <body lang="EN-GB"><div class="WordSection1"><p class="MsoNormal">Dear Rowan,</p>
        <p class="MsoNormal"><span style="font-family:&quot;Aptos&quot;,sans-serif">Pallets are ready.</span></p></div>
        <script>alert(1)</script></body></html>
        """

    // MARK: - Office's fonts

    func testOfficeFontsTheMacLacksAreStoodInForAtOutlooksWidth() {
        let page = ReadingHTML.page(body: outlook, parts: [], allowRemote: false, dark: false, ownColours: false, installedFamilies: [])
        XCTAssertTrue(page.contains("@font-face{font-family:\"Calibri\";src:local(\"Seravek\");font-weight:normal;font-style:normal;size-adjust:96.0%;}"),
                      page)
        XCTAssertTrue(page.contains("@font-face{font-family:\"Calibri\";src:local(\"Seravek-BoldItalic\");font-weight:bold;font-style:italic;size-adjust:96.0%;}"),
                      page)
        XCTAssertTrue(page.contains("@font-face{font-family:\"Aptos\";src:local(\"Helvetica\");font-weight:normal;font-style:normal;size-adjust:95.0%;}"),
                      page)
        XCTAssertFalse(page.contains("\"Cambria\""), "only the fonts the message names")
        XCTAssertFalse(page.contains("Calibri Light"), page)
        // A Mac with Office's fonts installed shows them as themselves.
        let installed = ReadingHTML.page(body: outlook, parts: [], allowRemote: false, dark: false, ownColours: false,
                                         installedFamilies: ["Calibri", "Aptos"])
        XCTAssertFalse(installed.contains("@font-face"), installed)
        // A plain message names no fonts of its own.
        let plain = ReadingHTML.page(body: "<pre>Calibri, Aptos;</pre>", plain: true, parts: [], allowRemote: false, dark: false,
                                     ownColours: false, installedFamilies: [])
        XCTAssertFalse(plain.contains("@font-face"), plain)
    }

    /// Every face a stand-in names comes with macOS.
    func testEveryStandInFaceIsOnThisMac() {
        for standIn in ReadingHTML.standIns {
            for face in [standIn.faces.regular, standIn.faces.bold, standIn.faces.italic, standIn.faces.boldItalic] {
                XCTAssertNotNil(NSFont(name: face, size: 12), "\(standIn.family): \(face)")
            }
        }
    }

    /// Scaled, each stand-in sets a line of English as wide as Office's own font does, measured
    /// on the fonts Outlook for Mac ships, where Outlook is installed.
    func testEachStandInTakesTheWidthOfTheOfficeFont() throws {
        let fonts = "/Applications/Microsoft Outlook.app/Contents/Resources/DFonts/"
        guard FileManager.default.fileExists(atPath: fonts) else { throw XCTSkip("Outlook is not installed to measure against") }
        let line = "The quick brown fox jumps over the lazy dog. Please confirm the loading date for the second truck, 27 EUR pallets."
        func width(_ font: CTFont) -> CGFloat {
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font as NSFont])),
                                       nil, nil, nil)
        }
        for (file, family) in [("Calibri.ttf", "Calibri"), ("Aptos.ttf", "Aptos"), ("Cambria.ttc", "Cambria"), ("Consola.ttf", "Consolas"),
                               ("Century Gothic.ttf", "Century Gothic"), ("Corbel.ttf", "Corbel"), ("Constan.ttf", "Constantia")] {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: fonts + file) as CFURL) as? [CTFontDescriptor],
                  let office = descriptors.first.map({ CTFontCreateWithFontDescriptor($0, 100, nil) }) else { continue }
            let standIn = try XCTUnwrap(ReadingHTML.standIns.first { $0.family == family })
            let stood = try XCTUnwrap(NSFont(name: standIn.faces.regular, size: 100 * standIn.scale))
            XCTAssertEqual(width(stood as CTFont) / width(office), 1, accuracy: 0.02, family)
        }
    }

    // MARK: - the page

    func testWordsBreakOnlyWhereALineHasNoRoomAndNothingRuns() {
        let page = ReadingHTML.page(body: outlook, parts: [], allowRemote: false, dark: false, ownColours: false, installedFamilies: [])
        XCTAssertTrue(page.contains("overflow-wrap:break-word"), page)
        XCTAssertFalse(page.contains("anywhere"), "a table keeps its words whole, as in Outlook")
        XCTAssertFalse(page.contains("<script"), page)
        XCTAssertTrue(page.contains("default-src 'none'; img-src data:;"), page)
        XCTAssertLessThan(page.range(of: "<meta charset")!.lowerBound, page.range(of: "p.MsoNormal")!.lowerBound,
                          "the reader's rules come first, so the message's own win")
    }

    func testTheSunSwitchShowsTheMessageAsWritten() {
        let dark = ReadingHTML.page(body: outlook, parts: [], allowRemote: false, dark: true, ownColours: false, installedFamilies: [])
        XCTAssertTrue(dark.contains("html{filter:invert(0.885) hue-rotate(180deg);}"), dark)
        let written = ReadingHTML.page(body: outlook, parts: [], allowRemote: false, dark: true, ownColours: true, installedFamilies: [])
        XCTAssertFalse(written.contains("invert"), written)
        XCTAssertFalse(ReadingHTML.page(body: outlook, parts: [], allowRemote: false, dark: false, ownColours: false).contains("invert"))
    }

    /// Outlook's HTML sets its text in black and draws its heading's line in windowtext. In
    /// dark appearance the reader shows both light on a dark ground, as Outlook's dark mode
    /// does; with the sun switch, black on white as written.
    @MainActor
    func testDarkAppearanceKeepsAnOutlookMessageReadable() throws {
        let message = """
            <html><head><style>p.MsoNormal{margin:0cm;font-size:48pt;font-family:"Calibri",sans-serif;color:black}</style></head>
            <body><div style="border:none;border-top:solid windowtext 12.0pt;padding:3.0pt 0cm 0cm 0cm">
            <p class="MsoNormal"><span style="color:black">MMMMMMMM</span></p></div></body></html>
            """
        for (ownColours, ground, ink) in [(false, 0.2, 0.7), (true, 1.0, 0.0)] {
            let page = ReadingHTML.page(body: message, parts: [], allowRemote: false, dark: true, ownColours: ownColours)
            let bitmap = try render(page, size: NSSize(width: 500, height: 160))
            func luminance(_ x: Int, _ y: Int) -> CGFloat {
                let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .magenta
                return 0.2126 * colour.redComponent + 0.7152 * colour.greenComponent + 0.0722 * colour.blueComponent
            }
            let scale = bitmap.pixelsWide / 500
            let corner = luminance(490 * scale, 150 * scale)
            // The line sits on the padding's top edge; the text below it.
            let line = (0..<40).map { luminance(100 * scale, (10 + $0) * scale) }
            let text = (0..<60).flatMap { y in (0..<40).map { x in luminance((40 + x * 3) * scale, (40 + y) * scale) } }
            if ownColours {
                XCTAssertEqual(corner, ground, accuracy: 0.05, "white ground as written")
                // WebKit draws windowtext a shade off black.
                XCTAssertLessThan(line.min() ?? 1, 0.3, "a dark line as written")
                XCTAssertLessThan(text.min() ?? 1, 0.15, "black text as written")
            } else {
                XCTAssertLessThan(corner, ground, "a dark ground")
                XCTAssertGreaterThan(line.max() ?? 0, ink, "the line reads")
                XCTAssertGreaterThan(text.max() ?? 0, ink, "the text reads")
            }
        }
    }

    /// `html` drawn by WebKit offscreen at `size`, as the reader's web view draws it.
    @MainActor
    private func render(_ html: String, size: NSSize) throws -> NSBitmapImageRep {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        let loaded = Loaded()
        view.navigationDelegate = loaded
        view.loadHTMLString(html, baseURL: nil)
        let deadline = Date(timeIntervalSinceNow: 30)
        while !loaded.done, Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        guard loaded.done else { throw XCTSkip("WebKit did not load a page in time here") }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        var image: NSImage?
        var finished = false
        view.takeSnapshot(with: nil) { snapshot, _ in
            image = snapshot
            finished = true
        }
        while !finished, Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        let tiff = try XCTUnwrap(image?.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }
}
