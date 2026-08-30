import Foundation
import SwiftUI

struct SourceControlView: View {
    @Bindable var session: RepositorySession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            commitArea
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    changeSection(title: "Staged Changes", changes: session.status.staged, staged: true)
                    changeSection(title: "Changes", changes: session.status.unstaged, staged: false)
                    if session.status.staged.isEmpty && session.status.unstaged.isEmpty {
                        ContentUnavailableView("Working Tree Clean", systemImage: "checkmark.circle")
                            .padding(.top, 36)
                    }
                }
            }
        }
        .background(.clear)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Source Control").font(.headline)
            Spacer()
            Picker("Branch", selection: Binding(
                get: { session.status.branch },
                set: { branch in Task { await session.switchBranch(branch) } }
            )) {
                ForEach(session.branches, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
            Button { Task { await session.fetch() } } label: { Image(systemName: "arrow.down.circle") }
                .help("Fetch")
            Button { Task { await session.pull() } } label: { Image(systemName: "arrow.down.to.line") }
                .help("Pull (fast-forward only)")
            Button { Task { await session.push() } } label: { Image(systemName: "arrow.up.to.line") }
                .help(session.status.upstream == nil ? "Publish Branch" : "Push")
            Button { Task { await session.refreshAll() } } label: {
                Image(systemName: "arrow.clockwise").rotationEffect(session.isRefreshing ? .degrees(180) : .zero)
            }
            .help("Refresh")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var commitArea: some View {
        VStack(spacing: 8) {
            TextField("Message (⌘↩ to commit on \"\(session.status.branch)\")", text: $session.commitMessage)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await session.commit() } }
            Button {
                Task { await session.commit() }
            } label: {
                Label("Commit \(session.status.staged.count) \(session.status.staged.count == 1 ? "file" : "files")", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(session.status.staged.isEmpty || session.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            HStack {
                Label("\(session.status.ahead) ahead", systemImage: "arrow.up")
                Label("\(session.status.behind) behind", systemImage: "arrow.down")
                Spacer()
                if session.dirtyDocumentCount > 0 {
                    Label("\(session.dirtyDocumentCount) unsaved — not included", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    @ViewBuilder
    private func changeSection(title: String, changes: [GitFileChange], staged: Bool) -> some View {
        if !changes.isEmpty {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(changes.count)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(staged ? "Unstage All" : "Stage All") {
                    Task { staged ? await session.unstageAll() : await session.stageAll() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            ForEach(changes) { change in
                ChangeRow(change: change, staged: staged, session: session)
            }
        }
    }
}

private struct ChangeRow: View {
    let change: GitFileChange
    let staged: Bool
    let session: RepositorySession

    var body: some View {
        HStack(spacing: 8) {
            FileTypeIcon(path: change.path, gitKind: change.kind)
            VStack(alignment: .leading, spacing: 0) {
                Text(change.displayName).lineLimit(1)
                if !change.parentPath.isEmpty {
                    Text(change.parentPath).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            Button {
                Task { staged ? await session.unstage(change) : await session.stage(change) }
            } label: {
                Image(systemName: staged ? "minus" : "plus")
            }
            .buttonStyle(.borderless)
            .help(staged ? "Unstage" : "Stage")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { Task { await session.openDiff(change) } }
        .background(Color.primary.opacity(0.001))
    }
}

private struct FileTypeIcon: View {
    private let descriptor: FileTypeIconDescriptor
    private let gitKind: GitChangeKind

    init(path: String, gitKind: GitChangeKind) {
        descriptor = FileTypeIconDescriptor(path: path)
        self.gitKind = gitKind
    }

    var body: some View {
        ZStack {
            if let systemName = descriptor.systemName {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .medium))
            } else {
                Text(descriptor.monogram)
                    .font(.system(size: descriptor.monogram.count > 2 ? 7.5 : 9, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(descriptor.color)
        .frame(width: 20, height: 18)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: gitKind.symbolName)
                .font(.system(size: 5.5, weight: .black))
                .foregroundStyle(badgeForeground)
                .frame(width: 9, height: 9)
                .background(gitColor, in: Circle())
                .overlay(Circle().stroke(.background.opacity(0.9), lineWidth: 0.75))
                .offset(x: 2, y: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(descriptor.accessibilityName), \(gitKind.accessibilityName)")
    }

    private var gitColor: Color {
        switch gitKind {
        case .added, .untracked: .green
        case .deleted: .red
        case .conflicted: .orange
        case .renamed, .copied: .blue
        case .modified: .yellow
        }
    }

    private var badgeForeground: Color {
        gitKind == .modified ? .black.opacity(0.72) : .white
    }
}

private struct FileTypeIconDescriptor {
    let systemName: String?
    let monogram: String
    let color: Color
    let accessibilityName: String

    init(path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let fileExtension = URL(fileURLWithPath: name).pathExtension.lowercased()

        switch name {
        case "package.json", "package-lock.json", "npm-shrinkwrap.json":
            self = .symbol("shippingbox.fill", color: .green, name: "Node package file")
        case "package.swift":
            self = .symbol("swift", color: .orange, name: "Swift package file")
        case "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts":
            self = .symbol("gearshape.2.fill", color: .teal, name: "Gradle file")
        case "dockerfile", "compose.yml", "compose.yaml", "docker-compose.yml", "docker-compose.yaml":
            self = .symbol("shippingbox.fill", color: .blue, name: "Docker file")
        case "makefile", "gnumakefile":
            self = .symbol("hammer.fill", color: .gray, name: "Makefile")
        case ".gitignore", ".gitattributes", ".gitmodules", ".easignore", ".dockerignore":
            self = .symbol("doc", color: .secondary, name: "Configuration file")
        default:
            switch fileExtension {
            case "md", "markdown", "mdx":
                self = .text("M↓", color: .blue, name: "Markdown file")
            case "json", "jsonc", "geojson":
                self = .text("{}", color: .orange, name: "JSON file")
            case "js", "mjs", "cjs":
                self = .text("JS", color: .orange, name: "JavaScript file")
            case "jsx":
                self = .text("JSX", color: .cyan, name: "JSX file")
            case "ts", "mts", "cts":
                self = .text("TS", color: .blue, name: "TypeScript file")
            case "tsx":
                self = .text("TSX", color: .cyan, name: "TSX file")
            case "py", "pyi", "pyw":
                self = .text("Py", color: .teal, name: "Python file")
            case "swift":
                self = .symbol("swift", color: .orange, name: "Swift file")
            case "rs":
                self = .text("Rs", color: .orange, name: "Rust file")
            case "sh", "bash", "zsh", "fish":
                self = .symbol("terminal.fill", color: .green, name: "Shell script")
            case "yml", "yaml":
                self = .text("Y", color: .pink, name: "YAML file")
            case "toml":
                self = .text("T", color: .gray, name: "TOML file")
            case "html", "htm":
                self = .text("<>", color: .orange, name: "HTML file")
            case "css", "scss", "sass", "less":
                self = .text("#", color: .blue, name: "Style sheet")
            case "plist", "xml":
                self = .symbol("chevron.left.forwardslash.chevron.right", color: .orange, name: "Property list or XML file")
            case "csv", "tsv":
                self = .symbol("tablecells.fill", color: .green, name: "Tabular data file")
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg":
                self = .symbol("photo.fill", color: .purple, name: "Image file")
            case "pdf":
                self = .symbol("doc.richtext.fill", color: .red, name: "PDF file")
            case "lock":
                self = .symbol("lock.fill", color: .purple, name: "Lock file")
            case "txt", "log":
                self = .symbol("doc.text", color: .secondary, name: "Text file")
            default:
                self = .symbol("doc", color: .secondary, name: "File")
            }
        }
    }

    private static func symbol(_ systemName: String, color: Color, name: String) -> Self {
        Self(systemName: systemName, monogram: "", color: color, accessibilityName: name)
    }

    private static func text(_ monogram: String, color: Color, name: String) -> Self {
        Self(systemName: nil, monogram: monogram, color: color, accessibilityName: name)
    }

    private init(systemName: String?, monogram: String, color: Color, accessibilityName: String) {
        self.systemName = systemName
        self.monogram = monogram
        self.color = color
        self.accessibilityName = accessibilityName
    }
}

private extension GitChangeKind {
    var accessibilityName: String {
        switch self {
        case .added: "added"
        case .untracked: "untracked"
        case .deleted: "deleted"
        case .conflicted: "conflicted"
        case .renamed: "renamed"
        case .copied: "copied"
        case .modified: "modified"
        }
    }
}
