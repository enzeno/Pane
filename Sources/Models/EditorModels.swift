import Foundation
import Observation

@MainActor
@Observable
final class EditorDocument: Identifiable {
    let id = UUID()
    let url: URL
    var text: String
    var originalText: String
    var encoding: DocumentEncoding
    var lineEnding: LineEnding
    var isReadOnly: Bool
    var isBinary: Bool
    var externalChangeDetected = false
    var targetLine: Int?
    var highlightGeneration = 0

    init(
        url: URL,
        text: String,
        encoding: DocumentEncoding,
        lineEnding: LineEnding,
        isReadOnly: Bool,
        isBinary: Bool
    ) {
        self.url = url
        self.text = text
        self.originalText = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.isReadOnly = isReadOnly
        self.isBinary = isBinary
    }

    var isDirty: Bool { text != originalText }
    var title: String { url.lastPathComponent }
    var isEditable: Bool { !isReadOnly && !isBinary }
    var highlightingEnabled: Bool { !isBinary && text.utf8.count <= DocumentIO.highlightingLimit }

    func replaceText(_ value: String) {
        guard text != value else { return }
        text = value
        highlightGeneration &+= 1
    }
}

enum EditorTabContent {
    case file(EditorDocument)
    case diff(DiffDocument)
    case commit(CommitDocument)
}

@MainActor
struct EditorTab: Identifiable {
    let id: UUID
    var content: EditorTabContent

    init(content: EditorTabContent) {
        self.id = UUID()
        self.content = content
    }

    var title: String {
        switch content {
        case .file(let document): document.title
        case .diff(let diff): diff.title
        case .commit(let detail): detail.commit.subject
        }
    }

    var isDirty: Bool {
        if case .file(let document) = content { return document.isDirty }
        return false
    }
}
