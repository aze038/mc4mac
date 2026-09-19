import Foundation

public actor GmailImporter {
    public static let requiredScopes = [GoogleScopes.gmailInsert, GoogleScopes.gmailLabels]
    private let api: GoogleAPI
    private let tokens: TokenStore
    private let accountID: UUID
    private var labelsByName: [String: String] = [:]
    private var labelsLoaded = false
    private var lastStart = Date.distantPast
    private let targetPerMinute: Double
    private var currentPerMinute: Double
    private var lastRateLimit = Date.distantPast
    private static let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
    private static let upload = URL(string: "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/import")!

    public init(tokens: TokenStore, accountID: UUID, importsPerMinute: Int = 220) {
        self.tokens = tokens
        self.accountID = accountID
        api = GoogleAPI(tokens: tokens, accountID: accountID)
        targetPerMinute = Double(max(1, importsPerMinute))
        currentPerMinute = targetPerMinute
    }

    public var pacePerMinute: Int { Int(currentPerMinute) }

    public func noteRateLimited() {
        lastRateLimit = Date()
        currentPerMinute = max(30, currentPerMinute * 0.6)
    }

    private func noteSuccess() {
        guard currentPerMinute < targetPerMinute, Date().timeIntervalSince(lastRateLimit) > 30 else { return }
        currentPerMinute = min(targetPerMinute, currentPerMinute + targetPerMinute / 600)
    }

    public func grantedScopes() async throws -> Set<String> {
        let token = try await tokens.validAccessToken(for: accountID)
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/tokeninfo")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("access_token=\(token)".utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let scope = info?["scope"] as? String ?? ""
        return Set(scope.split(separator: " ").map(String.init))
    }

    public func hasRequiredScopes() async throws -> Bool {
        let granted = try await grantedScopes()
        return GmailImporter.requiredScopes.allSatisfy { granted.contains($0) }
    }

    struct LabelList: Decodable { var labels: [Label]? }
    struct Label: Decodable { var id: String; var name: String }
    struct Imported: Decodable { var id: String }

    private func loadLabels() async throws {
        let list = try await api.json(LabelList.self, "GET", GmailImporter.base.appendingPathComponent("labels"))
        labelsByName = Dictionary((list.labels ?? []).map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        labelsLoaded = true
    }

    public func labelID(named name: String, create: Bool) async throws -> String? {
        if !labelsLoaded { try await loadLabels() }
        if let id = labelsByName[name] { return id }
        guard create else { return nil }
        struct NewLabel: Encodable { var name: String; var labelListVisibility = "labelShow"; var messageListVisibility = "show" }
        do {
            let label = try await api.json(Label.self, "POST", GmailImporter.base.appendingPathComponent("labels"), body: NewLabel(name: name))
            labelsByName[name] = label.id
            return label.id
        } catch FalconError.http(let status, _) where status == 409 {
            try await loadLabels()
            return labelsByName[name]
        }
    }

    public func importMessage(_ raw: Data, labelIDs: [String]) async throws -> String {
        await pace()
        let metadata = try JSONSerialization.data(withJSONObject: ["labelIds": labelIDs])
        let query = "?uploadType=%@&internalDateSource=dateHeader&neverMarkSpam=true&processForCalendar=false"
        if raw.count <= 24 * 1024 * 1024 {
            let boundary = "falconmail-" + UUID().uuidString
            let body = GmailImporter.multipart(metadata: metadata, raw: raw, boundary: boundary)
            let url = URL(string: GmailImporter.upload.absoluteString + String(format: query, "multipart"))!
            let (data, _) = try await api.request("POST", url, body: body, contentType: "multipart/related; boundary=\(boundary)")
            noteSuccess()
            return try JSONDecoder().decode(Imported.self, from: data).id
        }
        let start = URL(string: GmailImporter.upload.absoluteString + String(format: query, "resumable"))!
        let (_, response) = try await api.request("POST", start, body: metadata, contentType: "application/json",
                                                  headers: ["X-Upload-Content-Type": "message/rfc822", "X-Upload-Content-Length": String(raw.count)])
        guard let location = response.value(forHTTPHeaderField: "Location"), let session = URL(string: location) else {
            throw FalconError.protocolError("Gmail did not open a resumable upload session")
        }
        let (data, _) = try await api.request("PUT", session, body: raw, contentType: "message/rfc822")
        noteSuccess()
        return try JSONDecoder().decode(Imported.self, from: data).id
    }

    static func multipart(metadata: Data, raw: Data, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
        body.append(raw)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private func pace() async {
        let now = Date()
        let next = max(now, lastStart.addingTimeInterval(60.0 / currentPerMinute))
        lastStart = next
        let wait = next.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    public static func isRateLimited(_ error: Error) -> Bool {
        guard case FalconError.http(let status, let text) = error else { return false }
        if status == 429 || (500...504).contains(status) { return true }
        return status == 403 && text.lowercased().contains("ratelimit")
    }
}
