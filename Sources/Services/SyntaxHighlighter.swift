import Foundation
@preconcurrency import CodeEditLanguages
@preconcurrency import SwiftTreeSitter

actor SyntaxHighlighter {
    private struct State {
        let parser: Parser
        var tree: MutableTree
        var text: String
        var languageID: TreeSitterLanguage
    }

    private var states: [URL: State] = [:]

    func highlight(text: String, url: URL) throws -> SyntaxUpdate? {
        guard text.utf8.count <= DocumentIO.highlightingLimit else { return nil }
        let codeLanguage = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: String(text.prefix(256)))
        guard let language = codeLanguage.language,
              let query = TreeSitterModel.shared.query(for: codeLanguage.id) else {
            states[url] = nil
            return .init(affectedRange: NSRange(location: 0, length: (text as NSString).length), spans: [])
        }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let parser: Parser
        let newTree: MutableTree
        let affected: NSRange

        if let state = states[url], state.languageID == codeLanguage.id {
            parser = state.parser
            let edit = Self.makeEdit(old: state.text, new: text)
            state.tree.edit(edit.inputEdit)
            guard let parsed = parser.parse(tree: state.tree, string: text) else { return nil }
            let changed = state.tree.changedRanges(from: parsed).map(\.bytes.range)
            newTree = parsed
            affected = Self.expandedRange(changed.reduce(edit.changedRange, Self.union), in: text)
        } else {
            parser = Parser()
            try parser.setLanguage(language)
            guard let parsed = parser.parse(text) else { return nil }
            newTree = parsed
            affected = fullRange
        }

        let cursor = query.execute(in: newTree)
        cursor.setRange(affected)
        let spans = cursor
            .resolve(with: .init(string: text))
            .highlights()
            .filter { NSIntersectionRange($0.range, affected).length > 0 }
            .map { SyntaxSpan(name: $0.name, range: $0.range) }
        states[url] = State(parser: parser, tree: newTree, text: text, languageID: codeLanguage.id)
        return SyntaxUpdate(affectedRange: affected, spans: spans)
    }

    func discard(url: URL) { states[url] = nil }

    private static func makeEdit(old: String, new: String) -> (inputEdit: InputEdit, changedRange: NSRange) {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        var prefix = 0
        while prefix < oldUnits.count, prefix < newUnits.count, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldUnits.count - prefix,
              suffix < newUnits.count - prefix,
              oldUnits[oldUnits.count - suffix - 1] == newUnits[newUnits.count - suffix - 1] {
            suffix += 1
        }
        let oldEnd = oldUnits.count - suffix
        let newEnd = newUnits.count - suffix
        let startPoint = point(in: oldUnits, offset: prefix)
        let oldEndPoint = point(in: oldUnits, offset: oldEnd)
        let newEndPoint = point(in: newUnits, offset: newEnd)
        return (
            InputEdit(
                startByte: prefix * 2,
                oldEndByte: oldEnd * 2,
                newEndByte: newEnd * 2,
                startPoint: startPoint,
                oldEndPoint: oldEndPoint,
                newEndPoint: newEndPoint
            ),
            NSRange(location: prefix, length: max(1, newEnd - prefix))
        )
    }

    private static func point(in units: [UTF16.CodeUnit], offset: Int) -> Point {
        var row = 0
        var lineStart = 0
        if offset > 0 {
            for index in 0..<min(offset, units.count) where units[index] == 10 {
                row += 1
                lineStart = index + 1
            }
        }
        return Point(row: row, column: (offset - lineStart) * 2)
    }

    private static func union(_ lhs: NSRange, _ rhs: NSRange) -> NSRange { NSUnionRange(lhs, rhs) }

    private static func expandedRange(_ range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        let lines = ns.lineRange(for: safe)
        return NSIntersectionRange(lines, NSRange(location: 0, length: ns.length))
    }
}
