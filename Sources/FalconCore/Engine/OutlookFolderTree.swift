import Foundation
import CryptoKit

/// One line of an account's folder tree in the sidebar: a folder, or a group that holds folders
/// and no mail of its own, such as Gmail's [Gmail].
public struct SidebarFolderNode: Hashable, Sendable, Identifiable {
    public var folder: FolderInfo
    /// How far below the account it sits: 0 for the account's own folders.
    public var depth: Int
    public var hasChildren: Bool
    /// A group made for the tree, which is never selected and never acted on.
    public var isGroup: Bool

    public var id: UUID { folder.id }

    public init(folder: FolderInfo, depth: Int, hasChildren: Bool, isGroup: Bool = false) {
        self.folder = folder
        self.depth = depth
        self.hasChildren = hasChildren
        self.isGroup = isGroup
    }
}

/// The folders of a Google account on the Gmail API as the owner's Legacy Outlook lists them.
///
/// Inbox comes first. Then the [Gmail] group, which the engine does not list as a folder, so it is
/// made here: Drafts, Archive, Sent, Deleted Items and Junk Email in that order, then Important,
/// Starred and anything else of Gmail's own by name. Then the labels, by name, nested at `/`, with
/// a group made for a parent that is not a label of its own, as `Clients` for `Clients/Acme`.
public enum OutlookFolderTree {
    /// The name Gmail's own folders are grouped under when none of them says otherwise.
    public static let defaultGroupName = "[Gmail]"

    public static func gmail(_ folders: [FolderInfo], accountID: UUID) -> [SidebarFolderNode] {
        let inbox = folders.filter { $0.role == .inbox }
        let own = folders.filter { isGmailOwn($0) }
        // A container kept from the account's IMAP folders, such as [Gmail] itself, is made again
        // here as a group, never shown twice.
        let labels = folders.filter { $0.role == .other && $0.isSelectable }
        var nodes: [SidebarFolderNode] = inbox.map { SidebarFolderNode(folder: $0, depth: 0, hasChildren: false) }

        if !own.isEmpty {
            let name = groupName(of: own)
            var group = FolderInfo(id: groupID(accountID: accountID, path: name), accountID: accountID, path: name, name: name,
                                   delimiter: "/", role: .other, attributes: ["\\Noselect"], isSelectable: false)
            group.totalCount = 0
            nodes.append(SidebarFolderNode(folder: group, depth: 0, hasChildren: true, isGroup: true))
            let ordered = own.sorted { a, b in
                switch (fixedPlace(a.role), fixedPlace(b.role)) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            nodes += ordered.map { SidebarFolderNode(folder: $0, depth: 1, hasChildren: false) }
        }

        nodes += labelTree(labels, accountID: accountID)
        return nodes
    }

    /// The lines under open folders only: a closed folder, or group, hides everything below it.
    public static func visible(_ nodes: [SidebarFolderNode], collapsed: Set<UUID>) -> [SidebarFolderNode] {
        var out: [SidebarFolderNode] = []
        var hiddenBelow: Int?
        for node in nodes {
            if let depth = hiddenBelow {
                if node.depth > depth { continue }
                hiddenBelow = nil
            }
            out.append(node)
            if node.hasChildren, collapsed.contains(node.id) { hiddenBelow = node.depth }
        }
        return out
    }

    /// Whether the folder is one of Gmail's own, which sit in the [Gmail] group.
    static func isGmailOwn(_ folder: FolderInfo) -> Bool {
        switch folder.role {
        case .drafts, .all, .archive, .sent, .trash, .junk, .important, .flagged: return true
        case .inbox, .other: return false
        }
    }

    /// Drafts, Archive, Sent, Deleted Items and Junk Email lead the group in this order.
    static func fixedPlace(_ role: FolderRole) -> Int? {
        switch role {
        case .drafts: return 0
        case .all: return 1
        case .sent: return 2
        case .trash: return 3
        case .junk: return 4
        default: return nil
        }
    }

    /// The group's name as the account used it, such as [Gmail] or [Google Mail], read from the
    /// path of its first folder.
    static func groupName(of own: [FolderInfo]) -> String {
        for folder in own {
            let delimiter = folder.delimiter.isEmpty ? "/" : folder.delimiter
            let parts = folder.path.components(separatedBy: delimiter)
            if parts.count > 1, let first = parts.first, !first.isEmpty { return first }
        }
        return defaultGroupName
    }

    /// The same id for the same group every time, so the sidebar keeps its place and its state.
    static func groupID(accountID: UUID, path: String) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data("sidebar-group:\(accountID.uuidString):\(path)".utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The labels by name, each parent before its children, one level further in for each `/`.
    static func labelTree(_ labels: [FolderInfo], accountID: UUID) -> [SidebarFolderNode] {
        final class Node {
            var name: String
            var path: String
            var folder: FolderInfo?
            var children: [String: Node] = [:]
            init(name: String, path: String) {
                self.name = name
                self.path = path
            }
        }
        let root = Node(name: "", path: "")
        for label in labels {
            let delimiter = label.delimiter.isEmpty ? "/" : label.delimiter
            let parts = label.path.components(separatedBy: delimiter).filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            var node = root
            var path = ""
            for part in parts {
                path = path.isEmpty ? part : path + delimiter + part
                if let next = node.children[part] {
                    node = next
                } else {
                    let made = Node(name: part, path: path)
                    node.children[part] = made
                    node = made
                }
            }
            node.folder = label
        }
        var out: [SidebarFolderNode] = []
        func walk(_ node: Node, depth: Int) {
            let sorted = node.children.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for child in sorted {
                if let folder = child.folder {
                    out.append(SidebarFolderNode(folder: folder, depth: depth, hasChildren: !child.children.isEmpty))
                } else {
                    let group = FolderInfo(id: groupID(accountID: accountID, path: child.path), accountID: accountID, path: child.path,
                                           name: child.name, delimiter: "/", role: .other, attributes: ["\\Noselect"],
                                           isSelectable: false)
                    out.append(SidebarFolderNode(folder: group, depth: depth, hasChildren: true, isGroup: true))
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return out
    }
}
