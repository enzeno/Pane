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
            Image(systemName: change.kind.symbolName)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
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
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { Task { await session.openDiff(change) } }
        .background(Color.primary.opacity(0.001))
    }

    private var color: Color {
        switch change.kind {
        case .added, .untracked: .green
        case .deleted: .red
        case .conflicted: .orange
        case .renamed, .copied: .blue
        case .modified: .yellow
        }
    }
}

