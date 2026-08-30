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
    var errorMessage: String?
    var graphLimit = 500

    private var repository: GitRepository?
    private var fileIndex = FileIndex()
    private var watcher: RepositoryWatcher?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefreshKind: RepositoryChangeKind?
    private var indexMutationGeneration = 0
    private var inFlightIndexMutationCount = 0
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
            watcher = RepositoryWatcher(url: validated) { [weak self] kind in
                Task { @MainActor in self?.scheduleRefresh(for: kind) }
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

    func refreshStatus() async {
        guard let repository else { return }
        let generation = indexMutationGeneration
        do {
            let loadedStatus = try await repository.status()
            guard generation == indexMutationGeneration, inFlightIndexMutationCount == 0 else {
                scheduleRefresh(for: .index)
                return
            }
            status = loadedStatus
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshWorkingTree() async {
        guard let repository else { return }
        do {
            async let nextStatus = repository.status()
            async let nextFiles = repository.trackedAndUntrackedFiles()
            let (loadedStatus, loadedFiles) = try await (nextStatus, nextFiles)
            status = loadedStatus
            await fileIndex.replace(paths: loadedFiles)
            if quickOpenPresented { await updateQuickOpen(query: quickOpenQuery) }
            await checkExternalFileChanges()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scheduleRefresh(for kind: RepositoryChangeKind = .workingTree) {
        if let pendingRefreshKind {
            self.pendingRefreshKind = max(pendingRefreshKind, kind)
        } else {
            pendingRefreshKind = kind
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            guard let self, let pendingRefreshKind = self.pendingRefreshKind else { return }
            if pendingRefreshKind == .index, self.inFlightIndexMutationCount > 0 {
                return
            }
            self.pendingRefreshKind = nil
            switch pendingRefreshKind {
            case .index:
                await self.refreshStatus()
            case .history:
                await self.refreshAll()
            case .workingTree:
                await self.refreshWorkingTree()
            }
        }
    }

    func presentQuickOpen() {
        guard rootURL != nil else { chooseRepository(); return }
        quickOpenQuery = ""
        quickOpenSelection = 0
        quickOpenPresented = true
        Task { await updateQuickOpen(query: "") }
    }

    func toggleQuickOpen() {
        if quickOpenPresented {
            quickOpenPresented = false
        } else {
            presentQuickOpen()
        }
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
            scheduleRefresh(for: .workingTree)
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

    func stage(_ change: GitFileChange) async {
        optimisticallyStage(change)
        await runIndexOperation { try await $0.stage(path: change.path) }
    }

    func unstage(_ change: GitFileChange) async {
        optimisticallyUnstage(change)
        await runIndexOperation { try await $0.unstage(path: change.path) }
    }

    func stageAll() async {
        for change in status.unstaged { optimisticallyStage(change) }
        await runIndexOperation { try await $0.stageAll() }
    }

    func unstageAll() async {
        for change in status.staged { optimisticallyUnstage(change) }
        await runIndexOperation { try await $0.unstageAll() }
    }

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

    private func runOperation(_: String, operation: @escaping @Sendable (GitRepository) async throws -> Void) async {
        guard let repository else { return }
        errorMessage = nil
        do {
            try await operation(repository)
            await refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }

    private func runIndexOperation(
        _ operation: @escaping @Sendable (GitRepository) async throws -> Void
    ) async {
        guard let repository else { return }
        indexMutationGeneration += 1
        inFlightIndexMutationCount += 1
        errorMessage = nil
        do {
            try await operation(repository)
            inFlightIndexMutationCount -= 1
            if inFlightIndexMutationCount == 0 {
                scheduleRefresh(for: .index)
            }
        } catch {
            inFlightIndexMutationCount -= 1
            errorMessage = error.localizedDescription
            if inFlightIndexMutationCount == 0 {
                await refreshStatus()
            }
        }
    }

    private func optimisticallyStage(_ change: GitFileChange) {
        status.unstaged.removeAll { $0.path == change.path }
        status.staged.removeAll { $0.path == change.path }
        status.staged.append(change.moving(to: .staged))
        status.staged.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func optimisticallyUnstage(_ change: GitFileChange) {
        status.staged.removeAll { $0.path == change.path }
        guard !status.unstaged.contains(where: { $0.path == change.path }) else { return }
        status.unstaged.append(change.moving(to: .unstaged))
        status.unstaged.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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
