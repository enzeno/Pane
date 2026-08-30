import SwiftUI

struct QuickOpenView: View {
    @Bindable var session: RepositorySession
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.30)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search files by name (append : to go to line)", text: $session.quickOpenQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($searchFocused)
                        .onSubmit { Task { await session.openSelectedQuickOpenResult() } }
                        .onChange(of: session.quickOpenQuery) { _, value in
                            Task { await session.updateQuickOpen(query: value) }
                        }
                    Text("esc").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(session.quickOpenResults.enumerated()), id: \.element.id) { index, result in
                                HStack(spacing: 9) {
                                    Image(systemName: FileIcon.symbol(for: URL(fileURLWithPath: result.path)))
                                        .foregroundStyle(.tint)
                                        .frame(width: 18)
                                    Text(result.name).fontWeight(.medium).lineLimit(1)
                                    Text(result.parent).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    if index == 0 && session.quickOpenQuery.isEmpty {
                                        Text("recently opened").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 38)
                                .background(index == session.quickOpenSelection ? Color.accentColor.opacity(0.18) : .clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    session.quickOpenSelection = index
                                    Task { await session.openSelectedQuickOpenResult() }
                                }
                                .id(index)
                            }
                        }
                    }
                    .onChange(of: session.quickOpenSelection) { _, value in
                        withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(value, anchor: .center) }
                    }
                }
            }
            .frame(width: 680, height: 500)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.28), radius: 34, y: 18)
            .onKeyPress(.downArrow) {
                session.quickOpenSelection = min(session.quickOpenSelection + 1, max(0, session.quickOpenResults.count - 1))
                return .handled
            }
            .onKeyPress(.upArrow) {
                session.quickOpenSelection = max(0, session.quickOpenSelection - 1)
                return .handled
            }
            .onKeyPress(.escape) {
                dismiss()
                return .handled
            }
        }
        .task { searchFocused = true }
    }

    private func dismiss() {
        withAnimation(.snappy(duration: 0.14)) { session.quickOpenPresented = false }
    }
}

