import Foundation

public struct RuleCondition: Codable, Hashable, Sendable, Identifiable {
    public enum Field: String, Codable, CaseIterable, Sendable { case from, to, cc, subject, anyRecipient, body, hasAttachment }
    public enum Operator: String, Codable, CaseIterable, Sendable { case contains, notContains, equals, startsWith, endsWith, matchesRegex, isTrue }

    public var id: UUID
    public var field: Field
    public var op: Operator
    public var value: String

    public init(field: Field, op: Operator, value: String) {
        self.id = UUID()
        self.field = field
        self.op = op
        self.value = value
    }
}

public struct RuleAction: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case moveToFolder, copyToFolder, markRead, flag, delete, archive, stopProcessing }

    public var id: UUID
    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String = "") {
        self.id = UUID()
        self.kind = kind
        self.value = value
    }
}

public struct RuleDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var accountID: UUID?
    public var matchAll: Bool
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]
    public var isEnabled: Bool

    public init(name: String, accountID: UUID? = nil, matchAll: Bool = true, conditions: [RuleCondition] = [], actions: [RuleAction] = [], isEnabled: Bool = true) {
        self.id = UUID()
        self.name = name
        self.accountID = accountID
        self.matchAll = matchAll
        self.conditions = conditions
        self.actions = actions
        self.isEnabled = isEnabled
    }
}

public struct RuleSubject: Sendable {
    public var from: String
    public var to: [String]
    public var cc: [String]
    public var subject: String
    public var body: String
    public var hasAttachment: Bool

    public init(summary: MessageSummary, body: String = "") {
        self.from = summary.from.rfc5322
        self.to = summary.to.map { $0.rfc5322 }
        self.cc = summary.cc.map { $0.rfc5322 }
        self.subject = summary.subject
        self.body = body
        self.hasAttachment = summary.hasAttachments
    }
}

public enum RuleEngine {
    public static func matches(_ rule: RuleDefinition, _ subject: RuleSubject) -> Bool {
        guard rule.isEnabled, !rule.conditions.isEmpty else { return false }
        let results = rule.conditions.map { evaluate($0, subject) }
        return rule.matchAll ? results.allSatisfy { $0 } : results.contains(true)
    }

    public static func evaluate(_ c: RuleCondition, _ s: RuleSubject) -> Bool {
        let haystacks: [String]
        switch c.field {
        case .from: haystacks = [s.from]
        case .to: haystacks = s.to
        case .cc: haystacks = s.cc
        case .anyRecipient: haystacks = s.to + s.cc
        case .subject: haystacks = [s.subject]
        case .body: haystacks = [s.body]
        case .hasAttachment: return s.hasAttachment
        }
        let needle = c.value.lowercased()
        switch c.op {
        case .isTrue: return !haystacks.joined().isEmpty
        case .contains: return haystacks.contains { $0.lowercased().contains(needle) }
        case .notContains: return !haystacks.contains { $0.lowercased().contains(needle) }
        case .equals: return haystacks.contains { $0.lowercased() == needle }
        case .startsWith: return haystacks.contains { $0.lowercased().hasPrefix(needle) }
        case .endsWith: return haystacks.contains { $0.lowercased().hasSuffix(needle) }
        case .matchesRegex: return haystacks.contains { $0.range(of: c.value, options: [.regularExpression, .caseInsensitive]) != nil }
        }
    }

    public static func actions(for rules: [RuleDefinition], accountID: UUID, subject: RuleSubject) -> [RuleAction] {
        var out: [RuleAction] = []
        for rule in rules where rule.accountID == nil || rule.accountID == accountID {
            guard matches(rule, subject) else { continue }
            for a in rule.actions {
                if a.kind == .stopProcessing { return out }
                out.append(a)
            }
        }
        return out
    }
}

public actor RuleStore {
    private let url: URL
    private var rules: [RuleDefinition] = []
    private let writable: Bool

    public init(layout: FileLayout) {
        self.url = layout.rulesFile
        let stored = AtomicFile.loadJSON([RuleDefinition].self, from: url, what: "the rules")
        self.rules = stored.value ?? []
        self.writable = stored.canSave
    }

    public func all() -> [RuleDefinition] { rules }

    public func save(_ list: [RuleDefinition]) throws {
        guard writable else { throw FalconError.storage("The rules file could not be read, so it is left as it is.") }
        rules = list
        try AtomicFile.writeJSON(rules, to: url)
    }
}
