import Foundation
import CryptoKit

public enum MIMESlimmer {
    public struct Result: Sendable {
        public var data: Data
        public var removedParts: Int
        public var savedBytes: Int
    }

    struct Leaf {
        var removal: Range<Int>
        var headerRange: Range<Int>
        var bodyRange: Range<Int>
        var part: MIMEPart
        var container: Int
    }

    public static func mergeDuplicateAttachments(_ raw: Data) -> Result? {
        let original = MIMEParser.parse(raw)
        guard original.attachments.count > 1 else { return nil }
        var leaves: [Leaf] = []
        var children: [Int: Int] = [:]
        var nextContainer = 0
        walk(raw, content: 0..<raw.count, removal: nil, container: -1, leaves: &leaves, children: &children, next: &nextContainer, depth: 0)

        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for (i, leaf) in leaves.enumerated() {
            let p = leaf.part
            guard p.isAttachment || p.contentType.type == "image", !p.contentType.isMultipart, p.contentType.mimeType != "message/rfc822" else { continue }
            let data = p.decodedData
            guard data.count > 0 else { continue }
            let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(i)
        }

        var remove: [Int] = []
        var cidMap: [String: String] = [:]
        var remaining = children
        for key in order {
            let members = groups[key] ?? []
            guard members.count > 1 else { continue }
            let keeper = members.first { leaves[$0].part.contentID != nil } ?? members[0]
            let keptCID = leaves[keeper].part.contentID
            for m in members where m != keeper {
                let leaf = leaves[m]
                if let cid = leaf.part.contentID {
                    guard let keptCID else { continue }
                    if cid != keptCID { cidMap[cid] = keptCID }
                } else if leaf.part.filename != leaves[keeper].part.filename {
                    continue
                }
                guard (remaining[leaf.container] ?? 0) > 1 else { continue }
                remaining[leaf.container, default: 1] -= 1
                remove.append(m)
            }
        }
        guard !remove.isEmpty else { return nil }

        var edits: [(Range<Int>, Data)] = remove.map { (leaves[$0].removal, Data()) }
        var expectedHTML = original.textHTML
        if !cidMap.isEmpty {
            for (i, leaf) in leaves.enumerated() where leaf.part.contentType.mimeType == "text/html" && !remove.contains(i) {
                var html = leaf.part.decodedText
                var changed = false
                for (old, new) in cidMap where html.range(of: "cid:" + old, options: .caseInsensitive) != nil {
                    html = html.replacingOccurrences(of: "cid:" + old, with: "cid:" + new, options: .caseInsensitive)
                    changed = true
                }
                guard changed else { continue }
                let headers = rewrittenHeaders(raw.subdata(in: leaf.headerRange), contentType: "text/html; charset=utf-8", encoding: "base64")
                var replacement = headers
                replacement.append(Data("\r\n".utf8))
                replacement.append(MIMESlimmer.base64Lines(Data(html.replacingOccurrences(of: "\n", with: "\r\n").utf8)))
                edits.append((leaf.headerRange.lowerBound..<leaf.bodyRange.upperBound, replacement))
            }
            if var html = expectedHTML {
                for (old, new) in cidMap { html = html.replacingOccurrences(of: "cid:" + old, with: "cid:" + new, options: .caseInsensitive) }
                expectedHTML = html
            }
        }

        var out = raw
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            out.replaceSubrange(range, with: replacement)
        }

        let check = MIMEParser.parse(out)
        guard check.attachments.count == original.attachments.count - remove.count,
              check.textPlain == original.textPlain,
              check.textHTML == expectedHTML,
              Set(check.attachments.map { SHA256.hash(data: $0.data).description }) == Set(original.attachments.map { SHA256.hash(data: $0.data).description })
        else { return nil }
        return Result(data: out, removedParts: remove.count, savedBytes: raw.count - out.count)
    }

    static func walk(_ raw: Data, content: Range<Int>, removal: Range<Int>?, container: Int, leaves: inout [Leaf],
                     children: inout [Int: Int], next: inout Int, depth: Int) {
        let (headerRange, bodyRange) = splitHeaderBody(raw, in: content)
        let headers = MIMEHeaders.parse(raw.subdata(in: headerRange))
        let ct = ContentType.parse(headers.first("Content-Type"))
        if ct.isMultipart, let boundary = ct.boundary, depth < 20 {
            let id = next
            next += 1
            let delimiter = Data(("--" + boundary).utf8)
            var positions: [Int] = []
            var searchStart = bodyRange.lowerBound
            while searchStart < bodyRange.upperBound, let r = raw.range(of: delimiter, in: searchStart..<bodyRange.upperBound) {
                let atLineStart = r.lowerBound == bodyRange.lowerBound || raw[r.lowerBound - 1] == 0x0A
                if atLineStart { positions.append(r.lowerBound) }
                searchStart = r.upperBound
            }
            var count = 0
            for (i, pos) in positions.enumerated() {
                var after = pos + delimiter.count
                if after + 1 < bodyRange.upperBound, raw[after] == 0x2D, raw[after + 1] == 0x2D { break }
                while after < bodyRange.upperBound, raw[after] != 0x0A { after += 1 }
                if after < bodyRange.upperBound { after += 1 }
                let nextPos = i + 1 < positions.count ? positions[i + 1] : bodyRange.upperBound
                var end = nextPos
                if end > after, raw[end - 1] == 0x0A { end -= 1 }
                if end > after, raw[end - 1] == 0x0D { end -= 1 }
                guard end >= after else { continue }
                count += 1
                walk(raw, content: after..<end, removal: pos..<nextPos, container: id, leaves: &leaves, children: &children, next: &next, depth: depth + 1)
            }
            children[id] = count
            return
        }
        guard let removal else { return }
        let part = MIMEParser.parsePart(raw.subdata(in: content), depth: 0)
        leaves.append(Leaf(removal: removal, headerRange: headerRange, bodyRange: bodyRange, part: part, container: container))
    }

    static func splitHeaderBody(_ raw: Data, in range: Range<Int>) -> (Range<Int>, Range<Int>) {
        if let r = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]), in: range) { return (range.lowerBound..<r.lowerBound, r.upperBound..<range.upperBound) }
        if let r = raw.range(of: Data([0x0A, 0x0A]), in: range) { return (range.lowerBound..<r.lowerBound, r.upperBound..<range.upperBound) }
        return (range, range.upperBound..<range.upperBound)
    }

    static func base64Lines(_ data: Data) -> Data {
        Data((data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n").utf8)
    }

    static func rewrittenHeaders(_ headerBlock: Data, contentType: String, encoding: String) -> Data {
        let text = String(decoding: headerBlock, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var kept: [String] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.first == " " || s.first == "\t" {
                if !skipping { kept.append(s) }
                continue
            }
            let lower = s.lowercased()
            skipping = lower.hasPrefix("content-type:") || lower.hasPrefix("content-transfer-encoding:")
            if !skipping, !s.isEmpty { kept.append(s) }
        }
        kept.append("Content-Type: " + contentType)
        kept.append("Content-Transfer-Encoding: " + encoding)
        return Data((kept.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
