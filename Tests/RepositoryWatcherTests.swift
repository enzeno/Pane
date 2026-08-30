import XCTest
@testable import Pane

final class RepositoryWatcherTests: XCTestCase {
    func testClassifiesIndexChangesWithoutRequestingFullRefresh() {
        let watcher = RepositoryWatcher(url: URL(fileURLWithPath: "/tmp/example")) { _ in }

        XCTAssertEqual(watcher.classify(paths: ["/tmp/example/.git/index"]), .index)
        XCTAssertEqual(watcher.classify(paths: ["/tmp/example/.git/index.lock"]), .index)
    }

    func testClassifiesHistoryAndWorkingTreeChanges() {
        let watcher = RepositoryWatcher(url: URL(fileURLWithPath: "/tmp/example")) { _ in }

        XCTAssertEqual(watcher.classify(paths: ["/tmp/example/.git/refs/heads/main"]), .history)
        XCTAssertEqual(watcher.classify(paths: ["/tmp/example/Sources/App.swift"]), .workingTree)
        XCTAssertEqual(
            watcher.classify(paths: ["/tmp/example/.git/index", "/tmp/example/README.md"]),
            .workingTree
        )
    }
}
