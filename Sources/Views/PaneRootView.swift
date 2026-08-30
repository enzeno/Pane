import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PaneRootView: View {
    @State private var session = RepositorySession()
    @State private var didRestoreRepository = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        ZStack {
            if session.rootURL == nil {
                WelcomeView(session: session)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    VSplitView {
                        SourceControlView(session: session)
                            .frame(minHeight: 280)
                        GraphView(session: session)
                            .frame(minHeight: 220)
                    }
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
                } detail: {
                    EditorWorkspaceView(session: session)
                }
                .navigationSplitViewStyle(.balanced)
            }

            if session.quickOpenPresented {
                QuickOpenView(session: session)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ToolbarSeparatorSuppressor())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    session.chooseRepository()
                } label: {
                    Label(session.rootURL?.lastPathComponent ?? "Open Repository", systemImage: "folder")
                }
            }
            if session.rootURL != nil, !session.tabs.isEmpty {
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
        .task {
            guard !didRestoreRepository else { return }
            didRestoreRepository = true
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
}

private struct ToolbarSeparatorSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ToolbarSeparatorSuppressingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ToolbarSeparatorSuppressingView)?.suppressSeparators()
    }
}

private final class ToolbarSeparatorSuppressingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window?.toolbar != nil else { return }
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
