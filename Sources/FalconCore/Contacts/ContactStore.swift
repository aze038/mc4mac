import Foundation

public actor ContactStore {
    private let directory: URL
    private var contacts: [UUID: [ContactInfo]] = [:]
    /// Accounts whose file is there but could not be read, and so is never written over.
    private var unwritable: Set<UUID> = []

    public init(layout: FileLayout) {
        directory = layout.contactsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent) else { continue }
                let stored = AtomicFile.loadJSON([ContactInfo].self, from: f, what: "the saved contacts")
                if let list = stored.value { contacts[id] = list }
                if !stored.canSave { unwritable.insert(id) }
            }
        }
    }

    public func all() -> [ContactInfo] { contacts.values.flatMap { $0 } }

    public func replace(accountID: UUID, source: String, with list: [ContactInfo]) throws {
        var current = (contacts[accountID] ?? []).filter { $0.source != source }
        current.append(contentsOf: list)
        contacts[accountID] = current
        try save(current, for: accountID)
    }

    public func recordUse(accountID: UUID, addresses: [EmailAddress]) throws {
        var current = contacts[accountID] ?? []
        for a in addresses where !a.address.isEmpty {
            if let i = current.firstIndex(where: { $0.email.caseInsensitiveCompare(a.address) == .orderedSame }) {
                current[i].useCount += 1
                current[i].lastUsed = Date()
                if current[i].name.isEmpty { current[i].name = a.name }
            } else {
                current.append(ContactInfo(id: "recent:" + a.address.lowercased(), accountID: accountID, name: a.name, email: a.address,
                                           source: ContactInfo.recentSource, useCount: 1, lastUsed: Date()))
            }
        }
        contacts[accountID] = current
        try save(current, for: accountID)
    }

    private func save(_ list: [ContactInfo], for accountID: UUID) throws {
        guard !unwritable.contains(accountID) else { return }
        try AtomicFile.writeJSON(list, to: directory.appendingPathComponent("\(accountID.uuidString).json"))
    }

    /// Takes `address` out of every account's recent addresses, as the suggestion list's remove
    /// button does in Outlook. A contact list's entry for it stays: that is the list's to keep.
    public func forgetRecent(_ address: String) throws {
        for (accountID, list) in contacts {
            let kept = list.filter { !($0.isRecentAddress && $0.email.caseInsensitiveCompare(address) == .orderedSame) }
            guard kept.count != list.count else { continue }
            contacts[accountID] = kept
            try AtomicFile.writeJSON(kept, to: directory.appendingPathComponent("\(accountID.uuidString).json"))
        }
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
        struct Email: Decodable {
            var value: String?
            var type: String?
            /// The type as People shows it, "Work" for work, or a custom type as written.
            var formattedType: String?
        }
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
                    let label = (e.formattedType ?? e.type)?.trimmingCharacters(in: .whitespaces)
                    out.append(ContactInfo(id: person.resourceName + ":" + value.lowercased(), accountID: accountID, name: name, email: value,
                                           source: source, label: label?.isEmpty == false ? label : nil))
                }
            }
            token = p.nextPageToken
        } while token != nil
        return out
    }
}
