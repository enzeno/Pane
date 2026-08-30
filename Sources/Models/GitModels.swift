import Foundation

enum GitChangeArea: String, Sendable, Codable {
    case staged
    case unstaged
}

enum GitChangeKind: String, Sendable, Codable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case untracked
    case conflicted

    var symbolName: String {
        switch self {
        case .added, .untracked: "plus.circle.fill"
        case .modified: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        case .renamed, .copied: "arrow.right.circle.fill"
        case .conflicted: "exclamationmark.triangle.fill"
        }
    }
}

struct GitFileChange: Identifiable, Hashable, Sendable {
    let path: String
    let originalPath: String?
    let kind: GitChangeKind
    let area: GitChangeArea

    var id: String { "\(area.rawValue):\(path)" }
    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
    var parentPath: String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent == "." ? "" : parent
    }

    func moving(to area: GitChangeArea) -> GitFileChange {
        let movedKind: GitChangeKind = area == .unstaged && kind == .added ? .untracked : kind
        return GitFileChange(path: path, originalPath: originalPath, kind: movedKind, area: area)
    }
}

struct GitStatusSnapshot: Sendable, Equatable {
    var branch: String = "HEAD"
    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0
    var staged: [GitFileChange] = []
    var unstaged: [GitFileChange] = []

    static let empty = GitStatusSnapshot()
}

struct GraphCommit: Identifiable, Hashable, Sendable {
    let hash: String
    let parents: [String]
    let author: String
    let date: Date
    let refs: [String]
    let subject: String
    var lane: Int = 0

    var id: String { hash }
    var shortHash: String { String(hash.prefix(8)) }
}

struct DiffDocument: Identifiable, Hashable, Sendable {
    let id = UUID()
    let title: String
    let path: String?
    let text: String
    let area: GitChangeArea?
    let isBinary: Bool
}

struct CommitDocument: Identifiable, Hashable, Sendable {
    let id = UUID()
    let commit: GraphCommit
    let text: String
}

enum DocumentEncoding: String, Sendable, Codable {
    case utf8
    case utf8BOM
    case utf16LittleEndian
    case utf16BigEndian
}

enum LineEnding: String, Sendable, Codable {
    case lf
    case crlf
}

struct SyntaxSpan: Sendable, Hashable {
    let name: String
    let range: NSRange
}

struct SyntaxUpdate: Sendable {
    let affectedRange: NSRange
    let spans: [SyntaxSpan]
}
