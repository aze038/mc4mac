import Foundation

/// Gmail's multipart uploads: a JSON part saying where the message goes, then the message itself
/// as `message/rfc822`, exactly as FalconMail built it. Sending, importing, inserting and saving
/// drafts all upload this way.
public enum GmailUpload {
    /// Google's largest upload for `messages.send` and drafts, from its discovery document: 35 MB
    /// encoded. Checked before anything is sent, so a message over it costs nothing.
    public static let maxMessageBytes = 36_700_160
    /// `messages.import` and `messages.insert` take up to 150 MB.
    public static let maxImportBytes = 157_286_400

    public static func maxBytes(for method: GmailMethod) -> Int {
        switch method {
        case .messagesImport, .messagesInsert: return maxImportBytes
        default: return maxMessageBytes
        }
    }

    /// The body and its content type. The boundary is chosen so it occurs nowhere in the message.
    static func body(metadata: Data, message raw: Data) -> (body: Data, contentType: String) {
        var boundary = "falconmail_upload_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        while raw.range(of: Data(boundary.utf8)) != nil {
            boundary = "falconmail_upload_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
        body.append(raw)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (body, "multipart/related; boundary=\(boundary)")
    }

    /// Reads an upload back into its JSON part and its message, as Gmail does. The tests' fake
    /// Gmail uses it, so what FalconMail sends is checked by the same rules that built it.
    public static func parse(_ body: Data, contentType: String) -> (metadata: Data, message: Data)? {
        guard let boundary = MultipartText.boundary(in: contentType) else { return nil }
        let parts = MultipartText.parts(of: body, boundary: boundary)
        guard parts.count >= 2 else { return nil }
        return (MultipartText.splitHead(parts[0]).body, MultipartText.splitHead(parts[1]).body)
    }
}
