import SwiftUI

struct GraphView: View {
    let session: RepositorySession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Source Control: Graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(session.commits.count) commits").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(session.commits) { commit in
                        GraphRow(commit: commit)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await session.openCommit(commit) } }
                    }
                    Button("Load 500 More") { Task { await session.loadMoreCommits() } }
                        .buttonStyle(.borderless)
                        .padding(12)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
    }
}

private struct GraphRow: View {
    let commit: GraphCommit

    var body: some View {
        HStack(spacing: 7) {
            GraphGlyph(lane: commit.lane)
                .frame(width: CGFloat(max(1, min(commit.lane + 1, 5))) * 12, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(commit.subject).lineLimit(1)
                    ForEach(commit.refs.prefix(2), id: \.self) { ref in
                        Text(ref)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.18), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text(commit.author)
                    Text(commit.shortHash).monospaced()
                    Text(commit.date, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }
}

private struct GraphGlyph: View {
    let lane: Int

    var body: some View {
        Canvas { context, size in
            let x = min(size.width - 6, CGFloat(lane) * 12 + 6)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(laneColor), lineWidth: 1.5)
            context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: size.height / 2 - 3.5, width: 7, height: 7)), with: .color(laneColor))
        }
    }

    private var laneColor: Color {
        [.blue, .purple, .green, .orange, .pink][lane % 5]
    }
}

