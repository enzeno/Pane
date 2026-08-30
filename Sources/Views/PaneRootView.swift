import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct PaneRootView: View {
    @State private var session = RepositorySession()
    @State private var didRestoreRepository = false
    @State private var initialRepositoryRestoreInProgress = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var editorChromeVisible = false
    @State private var editorRevealTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            workspace

            if session.quickOpenPresented {
                QuickOpenView(session: session)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ToolbarSeparatorSuppressor(revision: toolbarChromeRevision))
        .background(AdaptiveWindowSize(compact: editorCollapsed))
        .toolbar {
            if session.rootURL != nil, !session.tabs.isEmpty, editorChromeVisible {
                ToolbarItem(placement: .principal) {
                    EditorTabStrip(session: session)
                        .frame(minWidth: 320, idealWidth: 720, maxWidth: 960)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .paneQuickOpen)) { _ in
            withAnimation(.easeOut(duration: 0.06)) { session.toggleQuickOpen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .paneSave)) { _ in session.saveSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .paneOpenRepository)) { _ in session.chooseRepository() }
        .onReceive(NotificationCenter.default.publisher(for: .paneSelectNextTab)) { _ in
            session.selectAdjacentTab(offset: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .paneSelectPreviousTab)) { _ in
            session.selectAdjacentTab(offset: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .paneCloseCurrentTab)) { _ in
            if let selectedTabID = session.selectedTabID { session.closeTab(selectedTabID) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.handleDrop(urls)
            return true
        }
        .onOpenURL { url in
            session.handleDrop([url])
        }
        .onChange(of: session.rootURL) { _, rootURL in
            if rootURL != nil {
                columnVisibility = .all
            }
        }
        .onChange(of: session.tabs.isEmpty) { _, tabsAreEmpty in
            updateEditorReveal(tabsAreEmpty: tabsAreEmpty)
        }
        .onDisappear {
            editorRevealTask?.cancel()
        }
        .task {
            guard !didRestoreRepository else { return }
            didRestoreRepository = true
            defer { initialRepositoryRestoreInProgress = false }
            let launchURLs = ProcessInfo.processInfo.arguments.dropFirst()
                .filter { $0.hasPrefix("/") }
                .map { URL(fileURLWithPath: $0) }
            if !launchURLs.isEmpty {
                await session.openLaunchFiles(launchURLs)
                return
            }
            if let recent = session.recentRepositories.first {
                await session.openRepository(recent)
            }
        }
        .alert("Pane", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "Unknown error")
        }
    }

    private var workspace: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
        } detail: {
            if initialRepositoryRestoreInProgress {
                Color.clear
                    .accessibilityHidden(true)
            } else if session.rootURL == nil {
                WelcomeView(session: session)
            } else if session.tabs.isEmpty || !editorChromeVisible {
                Color.clear
                    .accessibilityHidden(true)
            } else {
                EditorWorkspaceView(session: session)
                    .transition(.opacity)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        VSplitView {
            Group {
                if initialRepositoryRestoreInProgress {
                    Color.clear
                        .accessibilityHidden(true)
                } else if session.rootURL == nil {
                    StartupSidebarSection(title: "Source Control", systemImage: "arrow.triangle.branch")
                } else {
                    SourceControlView(session: session)
                }
            }
            .frame(minHeight: 280)
            Group {
                if initialRepositoryRestoreInProgress {
                    Color.clear
                        .accessibilityHidden(true)
                } else if session.rootURL == nil {
                    StartupSidebarSection(title: "Source Control: Graph", systemImage: "point.3.connected.trianglepath.dotted")
                } else {
                    GraphView(session: session)
                }
            }
            .frame(minHeight: 220)
        }
    }

    private var editorCollapsed: Bool {
        session.tabs.isEmpty
    }

    private var toolbarChromeRevision: Int {
        (session.rootURL == nil ? 0 : 1)
            + (session.tabs.isEmpty ? 0 : 2)
            + (editorChromeVisible ? 4 : 0)
    }

    private func updateEditorReveal(tabsAreEmpty: Bool) {
        editorRevealTask?.cancel()
        guard !tabsAreEmpty else {
            editorChromeVisible = false
            return
        }

        editorChromeVisible = false
        editorRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(190))
            guard !Task.isCancelled, !session.tabs.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.06)) {
                editorChromeVisible = true
            }
        }
    }
}

private struct AdaptiveWindowSize: NSViewRepresentable {
    let compact: Bool

    func makeNSView(context: Context) -> AdaptiveWindowSizingView {
        AdaptiveWindowSizingView(compact: compact)
    }

    func updateNSView(_ nsView: AdaptiveWindowSizingView, context: Context) {
        nsView.setCompact(compact)
    }
}

@MainActor
private final class AdaptiveWindowSizingView: NSView {
    private static let compactContentWidth: CGFloat = 377
    private static let compactMinimumWidth: CGFloat = 377
    private static let expandedMinimumWidth: CGFloat = 980
    private static let minimumHeight: CGFloat = 640
    private static let expandedWidthKey = "Pane.expandedWindowContentWidth"

    private var compact: Bool
    private var appliedCompactState: Bool?
    private var animationGeneration = 0

    init(compact: Bool) {
        self.compact = compact
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowSizeIfNeeded()
    }

    func setCompact(_ compact: Bool) {
        guard self.compact != compact || appliedCompactState == nil else { return }
        self.compact = compact
        applyWindowSizeIfNeeded()
    }

    private func applyWindowSizeIfNeeded() {
        guard let window, appliedCompactState != compact else { return }
        let previousState = appliedCompactState
        appliedCompactState = compact

        let currentContentWidth = window.contentLayoutRect.width
        if previousState == nil {
            if compact {
                window.contentMinSize = NSSize(width: Self.compactMinimumWidth, height: Self.minimumHeight)
                let targetFrame = frame(forContentWidth: Self.compactContentWidth, window: window)
                if abs(targetFrame.width - window.frame.width) > 1 {
                    window.setFrame(targetFrame, display: true)
                }
            } else {
                if currentContentWidth >= Self.expandedMinimumWidth {
                    UserDefaults.standard.set(currentContentWidth, forKey: Self.expandedWidthKey)
                }
                window.contentMinSize = NSSize(width: Self.expandedMinimumWidth, height: Self.minimumHeight)
            }
            return
        }

        if compact, currentContentWidth > Self.expandedMinimumWidth {
            UserDefaults.standard.set(currentContentWidth, forKey: Self.expandedWidthKey)
        }

        let targetContentWidth: CGFloat
        if compact {
            window.contentMinSize = NSSize(width: Self.compactMinimumWidth, height: Self.minimumHeight)
            targetContentWidth = Self.compactContentWidth
        } else {
            let storedWidth = UserDefaults.standard.double(forKey: Self.expandedWidthKey)
            targetContentWidth = max(storedWidth > 0 ? storedWidth : 1_440, Self.expandedMinimumWidth)
        }

        let targetFrame = frame(forContentWidth: targetContentWidth, window: window)
        guard abs(targetFrame.width - window.frame.width) > 1 else {
            window.contentMinSize = NSSize(
                width: compact ? Self.compactMinimumWidth : Self.expandedMinimumWidth,
                height: Self.minimumHeight
            )
            return
        }

        animationGeneration += 1
        let generation = animationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
        }
        guard !compact else { return }
        Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(for: .milliseconds(190))
            guard let self, let window,
                  self.animationGeneration == generation,
                  !self.compact else { return }
            window.contentMinSize = NSSize(width: Self.expandedMinimumWidth, height: Self.minimumHeight)
        }
    }

    private func frame(forContentWidth contentWidth: CGFloat, window: NSWindow) -> NSRect {
        let currentFrame = window.frame
        let currentContentFrame = window.contentRect(forFrameRect: currentFrame)
        let frameWidth = currentFrame.width + contentWidth - currentContentFrame.width
        var target = NSRect(x: currentFrame.minX, y: currentFrame.minY, width: frameWidth, height: currentFrame.height)

        if let visibleFrame = window.screen?.visibleFrame {
            target.size.width = min(target.width, visibleFrame.width)
            target.origin.x = min(target.minX, visibleFrame.maxX - target.width)
            target.origin.x = max(target.minX, visibleFrame.minX)
        }
        return target
    }
}

private struct StartupSidebarSection: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ContentUnavailableView("Open a Repository", systemImage: systemImage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ToolbarSeparatorSuppressor: NSViewRepresentable {
    let revision: Int

    func makeNSView(context: Context) -> NSView {
        let view = ToolbarSeparatorSuppressingView()
        view.setRevision(revision)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ToolbarSeparatorSuppressingView)?.setRevision(revision)
    }
}

private final class ToolbarSeparatorSuppressingView: NSView {
    private var revision: Int?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window?.toolbar != nil else { return }
        suppressSeparators()
        Task { @MainActor [weak self] in
            self?.suppressSeparators()
        }
    }

    func setRevision(_ revision: Int) {
        guard self.revision != revision else { return }
        self.revision = revision
        suppressSeparators()
        Task { @MainActor [weak self] in
            self?.suppressSeparators()
        }
    }

    func suppressSeparators() {
        guard let toolbar = window?.toolbar else { return }
        for index in toolbar.items.indices.reversed()
        where toolbar.items[index] is NSTrackingSeparatorToolbarItem {
            toolbar.removeItem(at: index)
        }
        if let frameView = window?.contentView?.superview {
            concealSidebarToggle(in: frameView)
        }
    }

    private func concealSidebarToggle(in view: NSView) {
        for subview in view.subviews {
            if let button = subview as? NSButton {
                let actionName = button.action.map(NSStringFromSelector) ?? ""
                let metadata = [
                    button.title,
                    button.toolTip ?? "",
                    button.accessibilityLabel() ?? "",
                    actionName,
                ]
                if metadata.contains(where: { $0.localizedCaseInsensitiveContains("sidebar") }) {
                    button.alphaValue = 0
                    button.isEnabled = false
                    button.setAccessibilityHidden(true)
                }
            }
            concealSidebarToggle(in: subview)
        }
    }
}

private struct WelcomeView: View {
    let session: RepositorySession

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 62, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 6) {
                Text("Pane").font(.system(size: 32, weight: .semibold))
                Text("Git and a fast editor. Nothing else.")
                    .foregroundStyle(.secondary)
            }
            Button("Open Repository…") { session.chooseRepository() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

            if !session.recentRepositories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(session.recentRepositories.prefix(6), id: \.path) { url in
                        Button {
                            Task { await session.openRepository(url) }
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(url.lastPathComponent)
                                Spacer()
                                Text(url.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 5)
                    }
                }
                .frame(width: 460)
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
