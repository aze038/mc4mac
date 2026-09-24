import Foundation

public struct ImportedMessage: Sendable {
    public var raw: Data
    public var flags: MessageFlags
    public var date: Date?
}

public enum MboxReader {
    public static func messages(in data: Data) -> [ImportedMessage] {
        var out: [ImportedMessage] = []
        let fromLine = Data("From ".utf8)
        var starts: [Int] = []
        var pos = data.startIndex
        while pos < data.endIndex {
            let lineEnd = data[pos...].firstIndex(of: 0x0A) ?? data.endIndex
            if data[pos..<lineEnd].starts(with: fromLine) { starts.append(pos) }
            pos = lineEnd + 1
        }
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : data.endIndex
            let headerEnd = data[start..<end].firstIndex(of: 0x0A).map { $0 + 1 } ?? end
            var body = data.subdata(in: headerEnd..<end)
            body = unstuff(body)
            if body.isEmpty { continue }
            let parsed = MIMEParser.parseHeaders(body)
            let statusFlags = (parsed.first("Status") ?? "") + (parsed.first("X-Status") ?? "")
            var flags = MessageFlags()
            if statusFlags.contains("R") { flags.insert(.seen) }
            if statusFlags.contains("A") { flags.insert(.answered) }
            if statusFlags.contains("F") { flags.insert(.flagged) }
            out.append(ImportedMessage(raw: normalizeLineEndings(body), flags: flags, date: parsed.first("Date").flatMap(RFC5322Date.parse)))
        }
        return out
    }

    static func unstuff(_ data: Data) -> Data {
        guard data.range(of: Data(">From ".utf8)) != nil else { return data }
        var out = Data()
        var lineStart = true
        var i = data.startIndex
        while i < data.endIndex {
            if lineStart, data[i...].starts(with: Data(">From ".utf8)) {
                i += 1
                lineStart = false
                continue
            }
            out.append(data[i])
            lineStart = data[i] == 0x0A
            i += 1
        }
        return out
    }

    public static func normalizeLineEndings(_ data: Data) -> Data {
        guard data.range(of: Data([0x0D, 0x0A])) == nil else { return data }
        var out = Data()
        out.reserveCapacity(data.count + data.count / 40)
        for b in data {
            if b == 0x0A { out.append(0x0D) }
            out.append(b)
        }
        return out
    }
}

public enum EMLImport {
    public static func message(at url: URL) throws -> ImportedMessage {
        let raw = MboxReader.normalizeLineEndings(try Data(contentsOf: url))
        let parsed = MIMEParser.parseHeaders(raw)
        return ImportedMessage(raw: raw, flags: [.seen], date: parsed.first("Date").flatMap(RFC5322Date.parse))
    }
}

/// Imports .eml and .mbox files into a folder, as File → Import does.
public enum FileImport {
    /// What an import did: how many messages went in, and what went wrong with each file that
    /// failed, for the owner.
    public struct Outcome: Sendable {
        public var imported = 0
        public var failures: [Error] = []
    }

    /// Imports each file's messages into `folder`, one at a time; a file stops at its first
    /// failure and the next is tried. Each failure reaches diagnostics once: a file that could
    /// not be read is reported here, under Import, while a message the server refused is
    /// reported by the engine, which met it.
    public static func run(_ urls: [URL], into folder: FolderInfo, syncer: AccountSyncer) async -> Outcome {
        var outcome = Outcome()
        for url in urls {
            let kind = url.pathExtension.lowercased()
            do {
                let messages = kind == "mbox" ? MboxReader.messages(in: try Data(contentsOf: url)) : [try EMLImport.message(at: url)]
                for m in messages {
                    try await syncer.importMessage(m, into: folder)
                    outcome.imported += 1
                }
            } catch is CancellationError {
                return outcome
            } catch {
                if !(error is MailServiceError) {
                    Log.error("Import", "Reading a .\(kind) file to import failed: \(error.localizedDescription)", error: error,
                              names: [url.lastPathComponent, url.deletingPathExtension().lastPathComponent])
                }
                outcome.failures.append(error)
            }
        }
        return outcome
    }
}

public enum MailExport {
    public static func mbox(messages: [Data]) -> Data {
        var out = Data()
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        for m in messages {
            out.append(Data("From FalconMail \(stamp.string(from: Date()))\n".utf8))
            let body = Data(m.filter { $0 != 0x0D })
            let text = body.utf8Lossy.replacingOccurrences(of: "\nFrom ", with: "\n>From ")
            out.append(Data(text.utf8))
            if !text.hasSuffix("\n") { out.append(0x0A) }
            out.append(0x0A)
        }
        return out
    }
}
