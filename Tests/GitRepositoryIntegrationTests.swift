import XCTest
@testable import Pane

final class GitRepositoryIntegrationTests: XCTestCase {
    func testLargeFileIndexOutputDrainsWithoutBlockingGit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneGitOutputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        for index in 0..<1_500 {
            let filename = String(format: "file-%04d-%@.txt", index, String(repeating: "x", count: 54))
            try Data().write(to: root.appendingPathComponent(filename))
        }

        let repository = GitRepository(rootURL: root)
        let files = try await repository.trackedAndUntrackedFiles()
        XCTAssertEqual(files.count, 1_500)
    }

    func testStageUnstageCommitAndBranchDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneGitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.name", "Pane Tests"], at: root)
        try runGit(["config", "user.email", "pane-tests@example.invalid"], at: root)
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("hello world.txt"))

        let repository = GitRepository(rootURL: root)
        var status = try await repository.status()
        XCTAssertEqual(status.unstaged.first?.kind, .untracked)

        try await repository.stage(path: "hello world.txt")
        status = try await repository.status()
        XCTAssertEqual(status.staged.first?.path, "hello world.txt")

        try await repository.unstage(path: "hello world.txt")
        status = try await repository.status()
        XCTAssertTrue(status.staged.isEmpty)

        try await repository.stageAll()
        try await repository.commit(message: "Initial commit")
        let commits = try await repository.commits(limit: 10)
        XCTAssertEqual(commits.first?.subject, "Initial commit")

        try runGit(["branch", "feature"], at: root)
        let branches = try await repository.branches()
        XCTAssertEqual(Set(branches), Set(["feature", "main"]))
        try await repository.switchBranch("feature")
        let switchedStatus = try await repository.status()
        XCTAssertEqual(switchedStatus.branch, "feature")
    }

    private func runGit(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = GitRepository.resolveExecutable()
        process.arguments = arguments
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(output)")
        }
    }
}
