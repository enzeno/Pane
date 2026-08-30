import XCTest
@testable import Pane

final class FileIndexTests: XCTestCase {
    func testLineParsingUsesFinalNumericSuffix() {
        XCTAssertEqual(QuickOpenQuery.parse("Sources/View.swift:42"), .init(term: "Sources/View.swift", line: 42))
        XCTAssertEqual(QuickOpenQuery.parse("README.md:wat"), .init(term: "README.md:wat", line: nil))
    }

    func testBasenamePrefixRanksAheadOfPathOnlyMatch() async {
        let index = FileIndex()
        await index.replace(paths: [
            "Sources/Editor/PaneWindow.swift",
            "pane-assets/Window.swift",
            "Tests/OtherTests.swift"
        ])
        let matches = await index.search("pane")
        XCTAssertEqual(matches.first?.path, "Sources/Editor/PaneWindow.swift")
    }

    func testRecentFilesAppearFirstForEmptyQuery() async {
        let index = FileIndex()
        await index.replace(paths: ["a.swift", "b.swift"])
        await index.recordOpen(path: "b.swift")
        let matches = await index.search("")
        XCTAssertEqual(matches.first?.path, "b.swift")
    }
}
