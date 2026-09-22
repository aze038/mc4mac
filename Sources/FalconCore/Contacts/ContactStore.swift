import Foundation

public actor ContactStore {
    private let directory: URL
    private var contacts: [UUID: [ContactInfo]] = [:]

    public init(layout: FileLayout) {
        directory = layout.contactsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                if let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent),
                   let list = AtomicFile.readJSON([ContactInfo].self, from: f) {
                    contacts[id] = list
                }
            }
        }
    }

    public func all() -> [ContactInfo] { contacts.values.flatMap { $0 } }

    public func replace(accountID: UUID, source: String, with list: [ContactInfo]) throws {
        var current = (contacts[accountID] ?? []).filter { $0.source != source }
        current.append(contentsOf: list)
        contacts[accountID] = current
        try AtomicFile.writeJSON(current, to: directory.appendingPathComponent("\(accountID.uuidString).json"))
    }

    public func recordUse(accountID: UUID, addresses: [EmailAddress]) throws {
        var current = contacts[accountID] ?? []
        for a in addresses where !a.address.isEmpty {
            if let i = current.firstIndex(where: { $0.email.caseInsensitiveCompare(a.address) == .orderedSame }) {
                current[i].useCount += 1
                current[i].lastUsed = Date()
                if current[i].name.isEmpty { current[i].name = a.name }
            } else {
                current.append(ContactInfo(id: "recent:" + a.address.lowercased(), accountID: accountID, name: a.name, email: a.address, source: "recent", useCount: 1, lastUsed: Date()))
            }
        }
        contacts[accountID] = current
        try AtomicFile.writeJSON(current, to: directory.appendingPathComponent("\(accountID.uuidString).json"))
    }

    public func suggest(_ prefix: String, limit: Int = 8) -> [ContactInfo] {
        Array(RecipientText.suggestions(from: all(), for: prefix).prefix(limit))
    }
}

public struct GooglePeopleClient: Sendable {
    let api: GoogleAPI
    let accountID: UUID

    public init(tokens: TokenStore, accountID: UUID) {
        api = GoogleAPI(tokens: tokens, accountID: accountID)
        self.accountID = accountID
    }

    struct Person: Decodable {
        struct Name: Decodable { var displayName: String? }
        struct Email: Decodable { var value: String? }
        var resourceName: String
        var names: [Name]?
        var emailAddresses: [Email]?
    }

    struct Page: Decodable {
        var connections: [Person]?
        var otherContacts: [Person]?
        var nextPageToken: String?
    }

    public func fetchAll() async throws -> [ContactInfo] {
        var out: [ContactInfo] = []
        out.append(contentsOf: try await page(URL(string: "https://people.googleapis.com/v1/people/me/connections")!,
                                              extra: ["personFields": "names,emailAddresses"], source: "google"))
        if let others = try? await page(URL(string: "https://people.googleapis.com/v1/otherContacts")!,
                                        extra: ["readMask": "names,emailAddresses"], source: "google-other") {
            out.append(contentsOf: others)
        }
        return out
    }

    private func page(_ url: URL, extra: [String: String], source: String) async throws -> [ContactInfo] {
        var out: [ContactInfo] = []
        var token: String?
        repeat {
            var q = extra
            q["pageSize"] = "1000"
            if let token { q["pageToken"] = token }
            let p: Page = try await api.json(Page.self, "GET", url, query: q)
            for person in (p.connections ?? []) + (p.otherContacts ?? []) {
                let name = person.names?.first?.displayName ?? ""
                for e in person.emailAddresses ?? [] {
                    guard let value = e.value, !value.isEmpty else { continue }
                    out.append(ContactInfo(id: person.resourceName + ":" + value.lowercased(), accountID: accountID, name: name, email: value, source: source))
                }
            }
            token = p.nextPageToken
        } while token != nil
        return out
    }
}
