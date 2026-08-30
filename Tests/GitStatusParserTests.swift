import XCTest
@testable import Pane

final class GitStatusParserTests: XCTestCase {
    func testParsesBranchCountsAndChanges() {
        let records = [
            "# branch.oid 0123456789",
            "# branch.head feature/pane",
            "# branch.upstream origin/feature/pane",
            "# branch.ab +3 -2",
            "1 M. N... 100644 100644 100644 abc def Sources/App.swift",
            "1 .D N... 100644 100644 000000 abc def Notes with spaces.md",
            "? 新しい file.txt"
        ]
        let snapshot = GitStatusParser.parse(nulData(records))

        XCTAssertEqual(snapshot.branch, "feature/pane")
        XCTAssertEqual(snapshot.upstream, "origin/feature/pane")
        XCTAssertEqual(snapshot.ahead, 3)
        XCTAssertEqual(snapshot.behind, 2)
        XCTAssertEqual(snapshot.staged.map(\.path), ["Sources/App.swift"])
        XCTAssertEqual(Set(snapshot.unstaged.map(\.path)), Set(["Notes with spaces.md", "新しい file.txt"]))
    }

    func testParsesRenameAndFilenameContainingNewline() {
        let records = [
            "# branch.head (detached)",
            "2 R. N... 100644 100644 100644 abc def R100 new\nname.swift",
            "old name.swift"
        ]
        let snapshot = GitStatusParser.parse(nulData(records))

        XCTAssertEqual(snapshot.branch, "(detached)")
        XCTAssertEqual(snapshot.staged.first?.path, "new\nname.swift")
        XCTAssertEqual(snapshot.staged.first?.originalPath, "old name.swift")
        XCTAssertEqual(snapshot.staged.first?.kind, .renamed)
    }

    func testUnbornRepository() {
        let snapshot = GitStatusParser.parse(nulData([
            "# branch.oid (initial)",
            "# branch.head main"
        ]))
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertTrue(snapshot.staged.isEmpty)
    }

    private func nulData(_ records: [String]) -> Data {
        Data((records.joined(separator: "\0") + "\0").utf8)
    }
}
