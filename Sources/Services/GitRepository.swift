import Foundation

struct GitCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

struct GitCommandError: LocalizedError, Sendable {
    let arguments: [String]
    let exitCode: Int32
    let output: String

    var errorDescription: String? {
        let command = (["git"] + arguments).joined(separator: " ")
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "\(command) failed with exit code \(exitCode)." : detail
    }
}

protocol GitClient: Sendable {
    func status() async throws -> GitStatusSnapshot
    func branches() async throws -> [String]
    func commits(limit: Int) async throws -> [GraphCommit]
    func diff(for change: GitFileChange) async throws -> DiffDocument
    func commitDetail(_ commit: GraphCommit) async throws -> CommitDocument
    func trackedAndUntrackedFiles() async throws -> [String]
    func stage(path: String) async throws
    func unstage(path: String) async throws
    func stageAll() async throws
    func unstageAll() async throws
    func commit(message: String) async throws
    func fetch() async throws
    func pull() async throws
    func push(status: GitStatusSnapshot) async throws
    func switchBranch(_ branch: String) async throws
}

actor GitRepository: GitClient {
    let rootURL: URL
    let executableURL: URL

    init(rootURL: URL, executableURL: URL = GitRepository.resolveExecutable()) {
        self.rootURL = rootURL
        self.executableURL = executableURL
    }

    static func resolveExecutable() -> URL {
        let candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git"
        ]
        return URL(fileURLWithPath: candidates.first(where: FileManager.default.isExecutableFile(atPath:)) ?? "/usr/bin/git")
    }

    func validatedRoot() async throws -> URL {
        let result = try await run(["rev-parse", "--show-toplevel"])
        return URL(fileURLWithPath: result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL
    }

    func status() async throws -> GitStatusSnapshot {
        let result = try await run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"])
        return GitStatusParser.parse(result.stdout)
    }

    func branches() async throws -> [String] {
        let result = try await run(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
        return result.stdoutString.split(separator: "\n").map(String.init).sorted()
    }

    func commits(limit: Int) async throws -> [GraphCommit] {
        let separator = "\u{1f}"
        let result = try await run([
            "log", "--all", "--topo-order", "--date-order", "-n", String(limit),
            "--format=%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s"
        ])
        var commits = result.stdoutString.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> GraphCommit? in
            let fields = line.split(separator: Character(separator), maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6, let timestamp = TimeInterval(fields[3]) else { return nil }
            let refs = fields[4].split(separator: ",").map { ref in
                String(ref).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "HEAD -> ", with: "")
                    .replacingOccurrences(of: "origin/", with: "")
            }.filter { !$0.isEmpty }
            return GraphCommit(
                hash: String(fields[0]),
                parents: fields[1].split(separator: " ").map(String.init),
                author: String(fields[2]),
                date: Date(timeIntervalSince1970: timestamp),
                refs: refs,
                subject: String(fields[5])
            )
        }
        assignLanes(&commits)
        return commits
    }

    func diff(for change: GitFileChange) async throws -> DiffDocument {
        let result: GitCommandResult
        if change.area == .staged {
            result = try await run(["diff", "--cached", "--no-ext-diff", "--unified=3", "--", change.path])
        } else if change.kind == .untracked {
            result = try await run(
                ["diff", "--no-index", "--no-ext-diff", "--unified=3", "--", "/dev/null", rootURL.appendingPathComponent(change.path).path],
                allowedExitCodes: [0, 1]
            )
        } else {
            result = try await run(["diff", "--no-ext-diff", "--unified=3", "--", change.path])
        }
        let text = result.stdoutString
        let isBinary = text.localizedCaseInsensitiveContains("binary files")
        return DiffDocument(title: change.displayName, path: change.path, text: text, area: change.area, isBinary: isBinary)
    }

    func commitDetail(_ commit: GraphCommit) async throws -> CommitDocument {
        let result = try await run(["show", "--no-ext-diff", "--unified=3", "--format=fuller", commit.hash])
        return CommitDocument(commit: commit, text: result.stdoutString)
    }

    func trackedAndUntrackedFiles() async throws -> [String] {
        let result = try await run(["ls-files", "-co", "--exclude-standard", "-z"])
        return result.stdout.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
    }

    func stage(path: String) async throws { _ = try await run(["add", "--", path]) }

    func unstage(path: String) async throws {
        let hasHead = (try? await run(["rev-parse", "--verify", "HEAD"])) != nil
        if hasHead {
            _ = try await run(["restore", "--staged", "--", path])
        } else {
            _ = try await run(["rm", "--cached", "--", path])
        }
    }

    func stageAll() async throws { _ = try await run(["add", "-A"]) }

    func unstageAll() async throws {
        let hasHead = (try? await run(["rev-parse", "--verify", "HEAD"])) != nil
        if hasHead {
            _ = try await run(["restore", "--staged", ":/"])
        } else {
            _ = try await run(["rm", "--cached", "-r", ":/"])
        }
    }

    func commit(message: String) async throws { _ = try await run(["commit", "-F", "-"], stdin: Data(message.utf8)) }
    func fetch() async throws { _ = try await run(["fetch", "--all"]) }
    func pull() async throws { _ = try await run(["pull", "--ff-only"]) }

    func push(status: GitStatusSnapshot) async throws {
        if status.upstream == nil {
            _ = try await run(["push", "-u", "origin", status.branch])
        } else {
            _ = try await run(["push"])
        }
    }

    func switchBranch(_ branch: String) async throws { _ = try await run(["switch", branch]) }

    @discardableResult
    private func run(
        _ arguments: [String],
        stdin: Data? = nil,
        allowedExitCodes: Set<Int32> = [0]
    ) async throws -> GitCommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = rootURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if stdin != nil { process.standardInput = stdinPipe }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C.UTF-8"
        process.environment = environment

        try process.run()
        if let stdin {
            stdinPipe.fileHandleForWriting.write(stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }

        let stdoutTask = Task.detached(priority: .utility) {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached(priority: .utility) {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        let result = GitCommandResult(
            stdout: await stdoutTask.value,
            stderr: await stderrTask.value,
            exitCode: process.terminationStatus
        )
        guard allowedExitCodes.contains(result.exitCode) else {
            let combined = result.stderr.isEmpty ? result.stdoutString : result.stderrString
            throw GitCommandError(arguments: arguments, exitCode: result.exitCode, output: combined)
        }
        return result
    }

    private func assignLanes(_ commits: inout [GraphCommit]) {
        var lanes: [String] = []
        for index in commits.indices {
            let hash = commits[index].hash
            let lane: Int
            if let existing = lanes.firstIndex(of: hash) {
                lane = existing
            } else {
                lane = lanes.count
                lanes.append(hash)
            }
            commits[index].lane = lane
            let parents = commits[index].parents
            if let first = parents.first {
                lanes[lane] = first
                for parent in parents.dropFirst().reversed() where !lanes.contains(parent) {
                    lanes.insert(parent, at: min(lane + 1, lanes.count))
                }
            } else {
                lanes.remove(at: lane)
            }
            var seen = Set<String>()
            lanes = lanes.filter { seen.insert($0).inserted }
        }
    }
}
