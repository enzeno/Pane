import Foundation

enum GitStatusParser {
    static func parse(_ data: Data) -> GitStatusSnapshot {
        let records = splitNUL(data)
        var snapshot = GitStatusSnapshot.empty
        var index = 0

        while index < records.count {
            let record = records[index]
            defer { index += 1 }

            if record.hasPrefix("# branch.head ") {
                snapshot.branch = String(record.dropFirst("# branch.head ".count))
                continue
            }
            if record.hasPrefix("# branch.upstream ") {
                snapshot.upstream = String(record.dropFirst("# branch.upstream ".count))
                continue
            }
            if record.hasPrefix("# branch.ab ") {
                let values = record.split(separator: " ")
                for value in values {
                    if value.first == "+" { snapshot.ahead = Int(value.dropFirst()) ?? 0 }
                    if value.first == "-" { snapshot.behind = Int(value.dropFirst()) ?? 0 }
                }
                continue
            }
            if record.hasPrefix("? ") {
                let path = String(record.dropFirst(2))
                snapshot.unstaged.append(.init(path: path, originalPath: nil, kind: .untracked, area: .unstaged))
                continue
            }
            if record.hasPrefix("1 ") {
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                appendChange(xy: String(fields[1]), path: String(fields[8]), originalPath: nil, to: &snapshot)
                continue
            }
            if record.hasPrefix("2 ") {
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10 else { continue }
                let original = index + 1 < records.count ? records[index + 1] : nil
                appendChange(xy: String(fields[1]), path: String(fields[9]), originalPath: original, to: &snapshot)
                index += 1
                continue
            }
            if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard let path = fields.last else { continue }
                let value = String(path)
                snapshot.unstaged.append(.init(path: value, originalPath: nil, kind: .conflicted, area: .unstaged))
            }
        }

        snapshot.staged.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        snapshot.unstaged.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return snapshot
    }

    private static func appendChange(
        xy: String,
        path: String,
        originalPath: String?,
        to snapshot: inout GitStatusSnapshot
    ) {
        let values = Array(xy)
        guard values.count >= 2 else { return }
        if values[0] != "." {
            snapshot.staged.append(.init(
                path: path,
                originalPath: originalPath,
                kind: kind(for: values[0]),
                area: .staged
            ))
        }
        if values[1] != "." {
            snapshot.unstaged.append(.init(
                path: path,
                originalPath: originalPath,
                kind: kind(for: values[1]),
                area: .unstaged
            ))
        }
    }

    private static func kind(for status: Character) -> GitChangeKind {
        switch status {
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "U": .conflicted
        default: .modified
        }
    }

    private static func splitNUL(_ data: Data) -> [String] {
        data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
    }
}

