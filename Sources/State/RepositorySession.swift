import AppKit
import Foundation
import Observation

extension Notification.Name {
    static let paneQuickOpen = Notification.Name("Pane.quickOpen")
    static let paneSave = Notification.Name("Pane.save")
    static let paneOpenRepository = Notification.Name("Pane.openRepository")
}

@MainActor
@Observable
final class RepositorySession {
    var rootURL: URL?
    var status = GitStatusSnapshot.empty
    var branches: [String] = []
    var commits: [GraphCommit] = []
    var tabs: [EditorTab] = []
    var selectedTabID: UUID?
    var commitMessage = ""
    var quickOpenPresented = false
    var quickOpenQuery = ""
    var quickOpenResults: [FileSearchResult] = []
    var quickOpenSelection = 0
    var isRefreshing = false
    var activeOperation: String?
    var errorMessage: String?
    var graphLimit = 500

    private var repository: GitRepository?
    private var fileIndex = FileIndex()
    private var watcher: RepositoryWatcher?
    private var refreshTask: Task<Void, Never>?
    let syntaxHighlighter = SyntaxHighlighter()

    var selectedTab: EditorTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    var dirtyDocumentCount: Int {
        tabs.reduce(into: 0) { count, tab in
            if tab.isDirty { count += 1 }
        }
    }

    var recentRepositories: [URL] {
        let values = UserDefaults.standard.stringArray(forKey: "Pane.recentRepositories") ?? []
        return values.map(URL.init(fileURLWithPath:))
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Open a Git Repository"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openRepository(url) }
    }

    func openRepository(_ selectedURL: URL) async {
        do {
            let candidate = GitRepository(rootURL: selectedURL)
            let validated = try await candidate.validatedRoot()
            let repo = GitRepository(rootURL: validated)
            rootURL = validated
            repository = repo
            tabs.removeAll()
            selectedTabID = nil
            graphLimit = 500
            rememberRepository(validated)
            watcher = RepositoryWatcher(url: validated) { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshAll() async {
        guard let repository else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let nextStatus = repository.status()
            async let nextBranches = repository.branches()
            async let nextCommits = repository.commits(limit: graphLimit)
            async let nextFiles = repository.trackedAndUntrackedFiles()
            let (loadedStatus, loadedBranches, loadedCommits, loadedFiles) = try await (
                nextStatus, nextBranches, nextCommits, nextFiles
            )
            status = loadedStatus
            branches = loadedBranches
            commits = loadedCommits
            await fileIndex.replace(paths: loadedFiles)
            if quickOpenPresented { await updateQuickOpen(query: quickOpenQuery) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            await self?.refreshAll()
            await self?.checkExternalFileChanges()
        }
    }

    func presentQuickOpen() {
        guard rootURL != nil else { chooseRepository(); return }
        quickOpenQuery = ""
        quickOpenSelection = 0
        quickOpenPresented = true
        Task { await updateQuickOpen(query: "") }
    }

    func updateQuickOpen(query: String) async {
        quickOpenQuery = query
        quickOpenResults = await fileIndex.search(query)
        quickOpenSelection = min(quickOpenSelection, max(0, quickOpenResults.count - 1))
    }

    func openSelectedQuickOpenResult() async {
        guard quickOpenResults.indices.contains(quickOpenSelection) else { return }
        let result = quickOpenResults[quickOpenSelection]
        let parsed = QuickOpenQuery.parse(quickOpenQuery)
        await openFile(path: result.path, line: parsed.line)
        quickOpenPresented = false
    }

    func openFile(path: String, line: Int? = nil) async {
        guard let rootURL else { return }
        await openFile(url: rootURL.appendingPathComponent(path), line: line, indexedPath: path)
    }

    func openFile(url: URL, line: Int? = nil, indexedPath: String? = nil) async {
        if let existing = tabs.first(where: {
            if case .file(let document) = $0.content { return document.url.standardizedFileURL == url.standardizedFileURL }
            return false
        }) {
            selectedTabID = existing.id
            if case .file(let document) = existing.content { document.targetLine = line }
            return
        }
        do {
            let decoded = try await Task.detached(priority: .userInitiated) { try DocumentIO.load(url: url) }.value
            let document = EditorDocument(
                url: url,
                text: decoded.text,
                encoding: decoded.encoding,
                lineEnding: decoded.lineEnding,
                isReadOnly: decoded.isReadOnly,
                isBinary: decoded.isBinary
            )
            document.targetLine = line
            let tab = EditorTab(content: .file(document))
            tabs.append(tab)
            selectedTabID = tab.id
            if let indexedPath { await fileIndex.recordOpen(path: indexedPath) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openDiff(_ change: GitFileChange) async {
        guard let repository else { return }
        do {
            let diff = try await repository.diff(for: change)
            let tab = EditorTab(content: .diff(diff))
            tabs.append(tab)
            selectedTabID = tab.id
        } catch { errorMessage = error.localizedDescription }
    }

    func openCommit(_ commit: GraphCommit) async {
        guard let repository else { return }
        do {
            let detail = try await repository.commitDetail(commit)
            let tab = EditorTab(content: .commit(detail))
            tabs.append(tab)
            selectedTabID = tab.id
        } catch { errorMessage = error.localizedDescription }
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].isDirty {
            let alert = NSAlert()
            alert.messageText = "Save changes before closing?"
            alert.informativeText = tabs[index].title
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return }
            if response == .alertFirstButtonReturn {
                if case .file(let document) = tabs[index].content { save(document) }
                if tabs[index].isDirty { return }
            }
        }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    func saveSelected() {
        guard let selectedTab, case .file(let document) = selectedTab.content else { return }
        save(document)
    }

    func save(_ document: EditorDocument) {
        guard !document.isReadOnly else { return }
        do {
            try DocumentIO.save(document)
            document.originalText = document.text
            document.externalChangeDetected = false
            scheduleRefresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func handleDrop(_ urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                Task { await openRepository(url) }
            } else {
                Task { await openFile(url: url) }
            }
        }
    }

    func stage(_ change: GitFileChange) async { await runOperation("Staging") { try await $0.stage(path: change.path) } }
    func unstage(_ change: GitFileChange) async { await runOperation("Unstaging") { try await $0.unstage(path: change.path) } }
    func stageAll() async { await runOperation("Staging all") { try await $0.stageAll() } }
    func unstageAll() async { await runOperation("Unstaging all") { try await $0.unstageAll() } }

    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !status.staged.isEmpty else { return }
        await runOperation("Committing") { try await $0.commit(message: message) }
        if errorMessage == nil { commitMessage = "" }
    }

    func fetch() async { await runOperation("Fetching") { try await $0.fetch() } }
    func pull() async { await runOperation("Pulling") { try await $0.pull() } }
    func push() async {
        let snapshot = status
        await runOperation("Pushing") { try await $0.push(status: snapshot) }
    }
    func switchBranch(_ branch: String) async {
        guard branch != status.branch else { return }
        await runOperation("Switching branch") { try await $0.switchBranch(branch) }
    }

    func loadMoreCommits() async {
        graphLimit += 500
        await refreshAll()
    }

    private func runOperation(_ name: String, operation: @escaping @Sendable (GitRepository) async throws -> Void) async {
        guard let repository else { return }
        activeOperation = name
        errorMessage = nil
        do {
            try await operation(repository)
            await refreshAll()
        } catch { errorMessage = error.localizedDescription }
        activeOperation = nil
    }

    private func rememberRepository(_ url: URL) {
        var values = UserDefaults.standard.stringArray(forKey: "Pane.recentRepositories") ?? []
        values.removeAll { $0 == url.path }
        values.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(values.prefix(12)), forKey: "Pane.recentRepositories")
    }

    private func checkExternalFileChanges() async {
        for tab in tabs {
            guard case .file(let document) = tab.content,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: document.url.path),
                  let modified = attributes[.modificationDate] as? Date,
                  modified.timeIntervalSinceNow > -1 else { continue }
            if document.isDirty {
                document.externalChangeDetected = true
            } else if let decoded = try? DocumentIO.load(url: document.url), decoded.text != document.text {
                document.text = decoded.text
                document.originalText = decoded.text
                document.externalChangeDetected = false
            }
        }
    }
}
