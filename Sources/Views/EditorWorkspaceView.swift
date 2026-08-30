import SwiftUI

struct EditorWorkspaceView: View {
    @Bindable var session: RepositorySession

    var body: some View {
        VStack(spacing: 0) {
            if !session.tabs.isEmpty { tabBar }
            Divider()
            if let tab = session.selectedTab {
                tabContent(tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Open a File", systemImage: "doc.text")
                } description: {
                    Text("Press Control-P or drag a file here.")
                } actions: {
                    Button("Quick Open") { session.presentQuickOpen() }
                        .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var tabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(session.tabs) { tab in
                    HStack(spacing: 7) {
                        Image(systemName: icon(for: tab))
                            .foregroundStyle(session.selectedTabID == tab.id ? Color.accentColor : Color(nsColor: .secondaryLabelColor))
                        Text(tab.title).lineLimit(1)
                        if tab.isDirty {
                            Circle().fill(.secondary).frame(width: 7, height: 7)
                        }
                        Button { session.closeTab(tab.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .opacity(session.selectedTabID == tab.id ? 1 : 0.55)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(minWidth: 110, maxWidth: 240, minHeight: 36, maxHeight: 36)
                    .background(session.selectedTabID == tab.id ? Color(nsColor: .textBackgroundColor) : .clear)
                    .overlay(alignment: .bottom) {
                        if session.selectedTabID == tab.id {
                            Rectangle().fill(.tint).frame(height: 1.5)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { session.selectedTabID = tab.id }
                    Divider()
                }
            }
        }
        .frame(height: 36)
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func tabContent(_ tab: EditorTab) -> some View {
        switch tab.content {
        case .file(let document):
            FileTabView(document: document, session: session)
        case .diff(let diff):
            DiffTabView(diff: diff, session: session)
        case .commit(let detail):
            CommitDetailView(detail: detail)
        }
    }

    private func icon(for tab: EditorTab) -> String {
        switch tab.content {
        case .file(let document): FileIcon.symbol(for: document.url)
        case .diff: "arrow.left.arrow.right"
        case .commit: "point.3.connected.trianglepath.dotted"
        }
    }
}

private struct FileTabView: View {
    @Bindable var document: EditorDocument
    let session: RepositorySession
    @AppStorage("Pane.editorFontSize") private var fontSize = 13.0

    var body: some View {
        VStack(spacing: 0) {
            if document.externalChangeDetected {
                banner(
                    icon: "exclamationmark.triangle.fill",
                    text: "This file changed on disk while you have unsaved edits.",
                    color: .orange
                )
            }
            if document.isReadOnly && !document.isBinary {
                HStack {
                    bannerContent(icon: "lock.fill", text: "Large file opened read-only to protect editor performance.", color: .secondary)
                    Spacer()
                    Button("Edit Anyway") { document.isReadOnly = false }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.secondary.opacity(0.08))
            }
            NativeTextEditor(
                document: document,
                fontSize: fontSize,
                highlighter: session.syntaxHighlighter,
                targetLine: document.targetLine
            )
        }
    }

    private func banner(icon: String, text: String, color: Color) -> some View {
        bannerContent(icon: icon, text: text, color: color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(color.opacity(0.10))
    }

    private func bannerContent(icon: String, text: String, color: Color) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(color)
    }
}

private struct DiffTabView: View {
    let diff: DiffDocument
    let session: RepositorySession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(diff.area == .staged ? "Staged Diff" : "Working Tree Diff", systemImage: "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let path = diff.path {
                    Button("Edit File") { Task { await session.openFile(path: path) } }
                        .buttonStyle(.glass)
                    if let change = matchingChange(path: path) {
                        Button(diff.area == .staged ? "Unstage" : "Stage") {
                            Task {
                                if diff.area == .staged { await session.unstage(change) }
                                else { await session.stage(change) }
                            }
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .padding(9)
            Divider()
            if diff.isBinary {
                ContentUnavailableView("Binary Diff", systemImage: "doc.badge.ellipsis", description: Text("Pane can stage this file but cannot preview its contents."))
            } else {
                DiffTextView(text: diff.text)
            }
        }
    }

    private func matchingChange(path: String) -> GitFileChange? {
        let source = diff.area == .staged ? session.status.staged : session.status.unstaged
        return source.first { $0.path == path }
    }
}

private struct CommitDetailView: View {
    let detail: CommitDocument

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.commit.subject).font(.headline)
                    Text("\(detail.commit.author) · \(detail.commit.shortHash) · \(detail.commit.date.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            Divider()
            DiffTextView(text: detail.text)
        }
    }
}

private struct DiffTextView: View {
    let text: String
    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line.isEmpty ? " " : String(line))
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(foreground(for: line))
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
                        .background(background(for: line))
                        .accessibilityLabel("Line \(index + 1): \(line)")
                }
            }
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func foreground(for line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") || line.hasPrefix("diff ") { return .cyan }
        return .primary
    }

    private func background(for line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green.opacity(0.10) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red.opacity(0.10) }
        if line.hasPrefix("@@") { return .blue.opacity(0.09) }
        return .clear
    }
}

enum FileIcon {
    static func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": "swift"
        case "py": "chevron.left.forwardslash.chevron.right"
        case "ts", "tsx", "js", "jsx": "curlybraces"
        case "json", "yaml", "yml", "toml": "list.bullet.rectangle"
        case "md", "markdown": "text.document"
        case "html", "css": "globe"
        case "sh", "zsh", "bash": "terminal"
        case "rs": "gearshape.2"
        default: "doc.text"
        }
    }
}
