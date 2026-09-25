import AppKit
import SQLite3
@testable import FalconCore

/// Made-up Legacy Outlook for Mac profiles, written byte for byte in the layout Outlook uses for
/// its .olk15Signature and .olk15SigAttachment files and with an Outlook.sqlite of the same
/// tables, so the import can be tried without anyone's Outlook. Every name, word and picture in
/// them is invented.
enum OutlookFixture {
    /// A picture a made-up signature shows.
    struct Picture {
        var contentID: String
        var data: Data
        var mimeType = "image/jpeg"
        var filename = "image001.jpg"
        var file = UUID()
    }

    struct SignatureSpec {
        var name: String
        var html: String
        var pictures: [Picture] = []
    }

    // MARK: - Records

    static func u32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
    }

    static func u16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
    }

    static func utf16(_ text: String) -> [UInt8] {
        text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    /// A record: the count, the table's length, the data's length, each property's tag and
    /// length, then the values.
    typealias Property = (id: UInt16, kind: UInt8, value: [UInt8])

    static func record(_ properties: [Property]) -> [UInt8] {
        var table: [UInt8] = []
        var values: [UInt8] = []
        for property in properties {
            table += u32(Int(property.kind) << 24 | Int(property.id))
            table += u32(property.value.count)
            values += property.value
        }
        return u32(properties.count) + u32(12 + table.count) + u32(values.count) + table + values
    }

    /// A picture's entry in a signature's list, with the same properties Outlook writes.
    static func pictureRecord(_ picture: Picture) -> [UInt8] {
        let mime: [UInt8] = Array(picture.mimeType.utf8)
        let bracketed: [UInt8] = Array("<\(picture.contentID)>".utf8)
        let name: [UInt8] = utf16(picture.filename)
        var inner: [Property] = []
        inner.append((0x1, 0x02, u16(5)))
        inner.append((0x2, 0x02, u16(0)))
        inner.append((0x3, 0x02, u16(2)))
        inner.append((0x4, 0x02, u16(2)))
        inner.append((0x1, 0x03, u32(0)))
        inner.append((0x2, 0x03, u32(0xE7)))
        inner.append((0x3, 0x03, u32(picture.data.count)))
        inner.append((0x4, 0x03, Array("MIPO".utf8)))
        inner.append((0x5, 0x03, Array("GEPJ".utf8)))
        inner.append((0x1, 0x1E, mime))
        inner.append((0x4, 0x1E, bracketed))
        inner.append((0x1, 0x1F, name))
        inner.append((0x2, 0x1F, name))
        let details = record(inner)
        let file: [UInt8] = withUnsafeBytes(of: picture.file.uuid) { Array($0) }
        var outer: [Property] = []
        outer.append((0x148, 0x03, Array("GEPJ".utf8)))
        outer.append((0x149, 0x03, Array("MIPO".utf8)))
        outer.append((0x15C, 0x0B, [0]))
        outer.append((0x133, 0x0D, details))
        outer.append((0x12C, 0x14, u32(0x15) + file))
        outer.append((0x13E, 0x1E, Array("public.jpeg".utf8)))
        outer.append((0x13F, 0x1E, mime))
        outer.append((0x140, 0x1E, Array(picture.contentID.utf8)))
        outer.append((0x151, 0x1E, Array(UUID().uuidString.utf8)))
        outer.append((0x134, 0x1F, name))
        return record(outer)
    }

    /// A .olk15Signature file.
    static func signatureFile(_ spec: SignatureSpec) -> Data {
        var list = u32(spec.pictures.count)
        for picture in spec.pictures {
            let entry = pictureRecord(picture)
            list += u16(entry.count) + entry
        }
        var tags: [UInt8] = []
        for tag: [UInt8] in [[0x37, 0x01, 0x00, 0x0D], [0x39, 0x01, 0x00, 0x1F], [0x3A, 0x01, 0x00, 0x1F]] {
            tags += tag + u32(2) + u32(0)
        }
        var properties: [Property] = []
        properties.append((0x0, 0x03, u32(1)))
        properties.append((0x137, 0x0D, list))
        properties.append((0x139, 0x1F, utf16(spec.name)))
        properties.append((0x13A, 0x1F, utf16(spec.html)))
        properties.append((0x14, 0x20, u32(2) + u32(0)))
        properties.append((0x15, 0x20, tags))
        properties.append((0x4, 0x4D, [0x53, 0x7A, 0x1E, 0x34, 0xA2, 0x2D, 0xC8, 0x41]))
        let body = record(properties)
        let header: [UInt8] = [0xDD0, 1, 1, 1, 0x15, 0x0B, 0x6FC9_5760, 1].flatMap(u32)
        let mark: [UInt8] = Array("CRiS".utf8) + u32(0x5226_14F7)
        return Data(header + mark + body)
    }

    /// A .olk15SigAttachment file: its header with its UUID, then the picture as a MIME part
    /// whose lines end in a bare carriage return, as Outlook writes it.
    static func attachmentFile(_ picture: Picture) -> Data {
        let file: [UInt8] = withUnsafeBytes(of: picture.file.uuid) { Array($0) }
        let start: [UInt8] = [0xDD0, 1, 2, 0x15].flatMap(u32)
        let mark: [UInt8] = Array("tAgS".utf8) + u32(0xC431_2FB4)
        let header: [UInt8] = start + file + mark
        let encoded = picture.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
        let part = "Content-type: \(picture.mimeType); name=\"\(picture.filename)\";\r x-mac-creator=\"4F50494D\";\r"
            + " x-mac-type=\"4A504547\"\rContent-ID: <\(picture.contentID)>\rContent-disposition: inline;\r\tfilename=\""
            + picture.filename + "\"\rContent-transfer-encoding: base64\r\r" + encoded + "\r"
        return Data(header + Array(part.utf8))
    }

    // MARK: - Profiles

    /// The Data folder of profile `name` under `home`, made.
    @discardableResult
    static func profile(in home: URL, named name: String = "Main Profile") throws -> URL {
        let data = home.appendingPathComponent(OutlookSignatureImport.profilesPath).appendingPathComponent(name)
            .appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        return data
    }

    /// Writes each signature and picture into the profile's folders as Outlook lays them out, and
    /// returns each signature's path as the database lists it.
    @discardableResult
    static func write(_ signatures: [SignatureSpec], into data: URL, writingPictures: Bool = true) throws -> [String] {
        var paths: [String] = []
        for (index, spec) in signatures.enumerated() {
            let folder = "Signatures/\(90 + index)"
            try FileManager.default.createDirectory(at: data.appendingPathComponent(folder), withIntermediateDirectories: true)
            let path = "\(folder)/\(UUID().uuidString).olk15Signature"
            try signatureFile(spec).write(to: data.appendingPathComponent(path))
            paths.append(path)
            guard writingPictures else { continue }
            for picture in spec.pictures {
                let pictures = data.appendingPathComponent("Signature Attachments/\(130 + index)")
                try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
                try attachmentFile(picture).write(to: pictures.appendingPathComponent("\(picture.file.uuidString).olk15SigAttachment"))
            }
        }
        return paths
    }

    /// An open Outlook.sqlite, closed when released.
    final class Database {
        let pointer: OpaquePointer

        init(_ file: URL, wal: Bool = false) throws {
            var pointer: OpaquePointer?
            guard sqlite3_open(file.path, &pointer) == SQLITE_OK, let pointer else { throw CocoaError(.fileWriteUnknown) }
            self.pointer = pointer
            if wal {
                try run("PRAGMA journal_mode=WAL")
                try run("PRAGMA wal_autocheckpoint=0")
            }
            try run("""
            CREATE TABLE IF NOT EXISTS Signatures (Record_RecordID INTEGER PRIMARY KEY ASC AUTOINCREMENT, PathToDataFile TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS AccountsMail (Record_RecordID INTEGER PRIMARY KEY ASC AUTOINCREMENT, PathToDataFile TEXT NOT NULL,
                Account_AssociatedAccountOfUID INTEGER DEFAULT 0, Account_ExchangeAccountUID INTEGER DEFAULT 0,
                Account_Name TEXT COLLATE NOCASE, Account_EmailAddress TEXT COLLATE NOCASE, Account_DeviceGuid BLOB,
                Account_ServerType INTEGER NOT NULL, Account_IsAccountOffline BOOLEAN DEFAULT 0, Account_IsMigrated BOOLEAN DEFAULT 0,
                Account_SecondaryAccountMigrationStatus INTEGER DEFAULT 0);
            """)
        }

        deinit { sqlite3_close(pointer) }

        func run(_ sql: String) throws {
            guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }

        func add(signature path: String, id: Int? = nil) throws {
            let encoded = path.replacingOccurrences(of: " ", with: "%20")
            try run("INSERT INTO Signatures (\(id == nil ? "" : "Record_RecordID, ")PathToDataFile) VALUES (\(id.map { "\($0), " } ?? "")'\(encoded)')")
        }

        func add(account email: String, name: String) throws {
            try run("""
            INSERT INTO AccountsMail (PathToDataFile, Account_Name, Account_EmailAddress, Account_ServerType)
            VALUES ('Mail%20Accounts/1/\(UUID().uuidString).olk15MailAccount', '\(name)', '\(email)', 1229799760)
            """)
        }
    }

    // MARK: - Made-up content

    /// How a made-up JPEG states its resolution.
    enum Resolution {
        /// In its JFIF header alone.
        case jfif
        /// Also in the TIFF tags of an Exif block, in Intel byte order as Word writes it, or in
        /// Motorola order as a camera may.
        case exif(littleEndian: Bool)
    }

    /// A JPEG `width` × `height` pixels in two colours at 72 dots an inch, by default as Word
    /// saves a signature's picture: a JFIF header, then an Exif block in Intel byte order that
    /// states the resolution again.
    static func jpeg(_ width: Int = 192, _ height: Int = 58, resolution: Resolution = .exif(littleEndian: true)) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: width / 3, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        var bytes = [UInt8](rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!)
        guard case .exif(let little) = resolution else { return Data(bytes) }
        // After the JFIF header, which is the first segment.
        let jfifEnd = 4 + (Int(bytes[4]) << 8 | Int(bytes[5]))
        bytes.insert(contentsOf: exifSegment(littleEndian: little, dpi: 72), at: jfifEnd)
        return Data(bytes)
    }

    /// An APP1 Exif segment whose first image states `dpi` both ways in inches.
    static func exifSegment(littleEndian little: Bool, dpi: Int) -> [UInt8] {
        func n16(_ value: Int) -> [UInt8] { little ? u16(value) : Array(u16(value).reversed()) }
        func n32(_ value: Int) -> [UInt8] { little ? u32(value) : Array(u32(value).reversed()) }
        var tiff: [UInt8] = little ? [0x49, 0x49] : [0x4D, 0x4D]
        tiff += n16(42)
        tiff += n32(8)
        // Three entries, then no next image, then the two rationals.
        let rationals = 8 + 2 + 3 * 12 + 4
        tiff += n16(3)
        for (tag, place) in [(0x011A, rationals), (0x011B, rationals + 8)] {
            tiff += n16(tag)
            tiff += n16(5)
            tiff += n32(1)
            tiff += n32(place)
        }
        tiff += n16(0x0128)
        tiff += n16(3)
        tiff += n32(1)
        tiff += n16(2)
        tiff += [0, 0]
        tiff += n32(0)
        for _ in 0..<2 {
            tiff += n32(dpi)
            tiff += n32(1)
        }
        var body: [UInt8] = Array("Exif".utf8)
        body += [0, 0]
        body += tiff
        let length = body.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + body
    }

    static let contentID = "image001.jpg@01DD0000.00000000"

    /// Word's HTML for a signature, as Outlook keeps it: the XML namespaces, a style sheet of
    /// MsoNormal paragraphs in points, conditional comments, and the picture drawn by VML for
    /// Word with an ordinary image beside it for everything else.
    static func wordHTML(pictureID: String? = contentID) -> String {
        let picture = pictureID.map { id in
            """
            <p class=MsoNormal><span style='font-size:10.0pt;color:black;mso-no-proof:yes'><!--[if gte vml 1]><v:shape \
            id="Picture_x0020_1" o:spid="_x0000_i1025" type="#_x0000_t75" style='width:72pt;height:21.75pt'><v:imagedata \
            src="cid:\(id)" o:title=""/></v:shape><![endif]--><![if !vml]><img width=96 height=29 \
            style='width:1.0in;height:.302in' src="cid:\(id)" v:shapes="Picture_x0020_1"><![endif]></span><span \
            style='font-size:10.0pt;color:black'><o:p></o:p></span></p>
            """
        } ?? ""
        return """
        <html xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" \
        xmlns:w="urn:schemas-microsoft-com:office:word" xmlns:m="http://schemas.microsoft.com/office/2004/12/omml" \
        xmlns="http://www.w3.org/TR/REC-html40"><head><meta http-equiv=Content-Type content="text/html; charset=utf-8">\
        <meta name=Generator content="Microsoft Word 15 (filtered medium)"><!--[if !mso]><style>v\\:* {behavior:url(#default#VML);}
        o\\:* {behavior:url(#default#VML);}
        .shape {behavior:url(#default#VML);}
        </style><![endif]--><style><!--
        /* Font Definitions */
        @font-face
        \t{font-family:"Cambria Math";
        \tpanose-1:2 4 5 3 5 4 6 3 2 4;}
        @font-face
        \t{font-family:Calibri;
        \tpanose-1:2 15 5 2 2 2 4 3 2 4;}
        /* Style Definitions */
        p.MsoNormal, li.MsoNormal, div.MsoNormal
        \t{margin:0cm;
        \tfont-size:12.0pt;
        \tfont-family:"Calibri",sans-serif;}
        a:link, span.MsoHyperlink
        \t{mso-style-priority:99;
        \tcolor:#0563C1;
        \ttext-decoration:underline;}
        @page WordSection1
        \t{size:612.0pt 792.0pt;
        \tmargin:72.0pt 72.0pt 72.0pt 72.0pt;}
        div.WordSection1
        \t{page:WordSection1;}
        --></style><!--[if gte mso 9]><xml>
        <o:shapedefaults v:ext="edit" spidmax="1026" />
        </xml><![endif]--><!--[if gte mso 9]><xml>
        <o:shapelayout v:ext="edit">
        <o:idmap v:ext="edit" data="1" />
        </o:shapelayout></xml><![endif]--></head><body lang=EN-GB link="#0563C1" vlink="#954F72" \
        style='word-wrap:break-word'><div class=WordSection1><p class=MsoNormal><b><span style='font-size:10.0pt;\
        font-family:"Helvetica Neue";color:#1F3864'>Alex Example<o:p></o:p></span></b></p><p class=MsoNormal><span \
        style='font-size:9.0pt;font-family:"Helvetica Neue";color:#444444'>Operations Lead | Example Freight Ltd<o:p></o:p>\
        </span></p><p class=MsoNormal><span style='font-size:9.0pt;font-family:Helvetica;color:black'>Tel: +44 20 7946 0000 \
        | <a href="https://example.com/"><span style='color:#0563C1'>example.com</span></a><o:p></o:p></span></p>\(picture)\
        <p class=MsoNormal><o:p>&nbsp;</o:p></p></div></body></html>
        """
    }
}
