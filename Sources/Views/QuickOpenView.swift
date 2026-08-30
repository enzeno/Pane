import AppKit
import SwiftUI

struct QuickOpenView: View {
    @Bindable var session: RepositorySession
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
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
                                        Text(result.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
                                        Text(result.parent).foregroundStyle(.secondary).lineLimit(1)
                                        Spacer(minLength: 0)
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
                .frame(
                    width: min(680, max(300, geometry.size.width - 24)),
                    height: min(500, max(260, geometry.size.height - 48))
                )
                .background(
                    Color(nsColor: .windowBackgroundColor).opacity(0.72),
                    in: .rect(cornerRadius: 18)
                )
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .clipShape(.rect(cornerRadius: 18))
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
        }
        .onExitCommand(perform: dismiss)
        .background {
            QuickOpenKeyMonitor(onDismiss: dismiss)
                .frame(width: 0, height: 0)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.06)) { session.quickOpenPresented = false }
    }
}

private struct QuickOpenKeyMonitor: NSViewRepresentable {
    let onDismiss: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: @unchecked Sendable {
        private let onDismiss: @MainActor () -> Void
        private var monitor: Any?

        init(onDismiss: @escaping @MainActor () -> Void) {
            self.onDismiss = onDismiss
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let togglesQuickOpen = event.charactersIgnoringModifiers?.lowercased() == "p"
                    && (modifiers.contains(.control) || modifiers.contains(.command))
                guard event.keyCode == 53 || togglesQuickOpen else { return event }
                Task { @MainActor in self?.onDismiss() }
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stop()
        }
    }
}
