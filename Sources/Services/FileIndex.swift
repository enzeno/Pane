import Foundation

struct FileSearchResult: Identifiable, Hashable, Sendable {
    let path: String
    let score: Int
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var parent: String {
        let value = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return value == "." ? "" : value
    }
}

struct QuickOpenQuery: Equatable, Sendable {
    let term: String
    let line: Int?

    static func parse(_ raw: String) -> QuickOpenQuery {
        guard let colon = raw.lastIndex(of: ":"), colon < raw.index(before: raw.endIndex) else {
            return .init(term: raw, line: nil)
        }
        let suffix = raw[raw.index(after: colon)...]
        guard let line = Int(suffix), line > 0 else { return .init(term: raw, line: nil) }
        return .init(term: String(raw[..<colon]), line: line)
    }
}

actor FileIndex {
    private var paths: [String] = []
    private var recents: [String] = []

    func replace(paths: [String]) {
        self.paths = Array(Set(paths)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        recents.removeAll { !self.paths.contains($0) }
    }

    func recordOpen(path: String) {
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > 40 { recents.removeLast(recents.count - 40) }
    }

    func search(_ rawQuery: String, limit: Int = 14) -> [FileSearchResult] {
        let parsed = QuickOpenQuery.parse(rawQuery)
        let query = parsed.term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            let recentResults = recents.prefix(limit).enumerated().map {
                FileSearchResult(path: $0.element, score: 10_000 - $0.offset)
            }
            if recentResults.count == limit { return recentResults }
            let used = Set(recentResults.map(\.path))
            return recentResults + paths.lazy.filter { !used.contains($0) }.prefix(limit - recentResults.count).map {
                FileSearchResult(path: $0, score: 0)
            }
        }

        let recentRanks = Dictionary(uniqueKeysWithValues: recents.enumerated().map { ($0.element, max(0, 300 - $0.offset * 5)) })
        return paths.compactMap { path -> FileSearchResult? in
            guard let baseScore = Self.fuzzyScore(query: query, candidate: path) else { return nil }
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            var score = baseScore + (recentRanks[path] ?? 0)
            if name.hasPrefix(query) { score += 800 }
            if name == query { score += 1_500 }
            return .init(path: path, score: score)
        }
        .sorted { lhs, rhs in lhs.score == rhs.score ? lhs.path < rhs.path : lhs.score > rhs.score }
        .prefix(limit)
        .map { $0 }
    }

    static func fuzzyScore(query: String, candidate: String) -> Int? {
        let source = Array(candidate.lowercased())
        let needle = Array(query)
        guard !needle.isEmpty else { return 0 }
        var sourceIndex = 0
        var score = 0
        var run = 0
        for character in needle {
            var found: Int?
            while sourceIndex < source.count {
                if source[sourceIndex] == character { found = sourceIndex; break }
                sourceIndex += 1
                run = 0
            }
            guard let match = found else { return nil }
            let boundary = match == 0 || "/_- .".contains(source[match - 1])
            run += 1
            score += 20 + run * 8 + (boundary ? 45 : 0)
            sourceIndex = match + 1
        }
        score -= max(0, source.count - needle.count)
        return score
    }
}

