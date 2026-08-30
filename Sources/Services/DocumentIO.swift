import Foundation

enum DocumentIOError: LocalizedError {
    case unsupportedEncoding

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: "Pane could not decode this file as UTF-8 or UTF-16."
        }
    }
}

struct DecodedDocument: Sendable {
    let text: String
    let encoding: DocumentEncoding
    let lineEnding: LineEnding
    let isReadOnly: Bool
    let isBinary: Bool
}

enum DocumentIO {
    static let highlightingLimit = 2 * 1_024 * 1_024
    static let editableLimit = 10 * 1_024 * 1_024

    static func load(url: URL) throws -> DecodedDocument {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let isUTF16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        if !isUTF16 && data.prefix(8_192).contains(0) {
            return .init(text: "Binary file — preview is unavailable.", encoding: .utf8, lineEnding: .lf, isReadOnly: true, isBinary: true)
        }

        let decoded: (String, DocumentEncoding)
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let value = String(data: data.dropFirst(3), encoding: .utf8) {
            decoded = (value, .utf8BOM)
        } else if data.starts(with: [0xFF, 0xFE]), let value = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            decoded = (value, .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]), let value = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            decoded = (value, .utf16BigEndian)
        } else if let value = String(data: data, encoding: .utf8) {
            decoded = (value, .utf8)
        } else {
            throw DocumentIOError.unsupportedEncoding
        }

        let ending: LineEnding = decoded.0.contains("\r\n") ? .crlf : .lf
        let normalized = decoded.0.replacingOccurrences(of: "\r\n", with: "\n")
        return .init(
            text: normalized,
            encoding: decoded.1,
            lineEnding: ending,
            isReadOnly: data.count > editableLimit,
            isBinary: false
        )
    }

    @MainActor
    static func save(_ document: EditorDocument) throws {
        let output = document.lineEnding == .crlf
            ? document.text.replacingOccurrences(of: "\n", with: "\r\n")
            : document.text
        var data: Data
        switch document.encoding {
        case .utf8:
            data = Data(output.utf8)
        case .utf8BOM:
            data = Data([0xEF, 0xBB, 0xBF])
            data.append(Data(output.utf8))
        case .utf16LittleEndian:
            data = Data([0xFF, 0xFE])
            data.append(output.data(using: .utf16LittleEndian) ?? Data())
        case .utf16BigEndian:
            data = Data([0xFE, 0xFF])
            data.append(output.data(using: .utf16BigEndian) ?? Data())
        }
        try data.write(to: document.url, options: .atomic)
    }
}
