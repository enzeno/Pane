import AppKit
import SwiftUI

@main
struct PaneApp: App {
    var body: some Scene {
        WindowGroup {
            PaneRootView()
                .frame(minWidth: 980, minHeight: 640)
                .background(AdaptiveAppIcon())
        }
        .defaultSize(width: 1_440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") {
                    NotificationCenter.default.post(name: .paneOpenRepository, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    NotificationCenter.default.post(name: .paneSave, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
            CommandMenu("Navigate") {
                Button("Quick Open") {
                    NotificationCenter.default.post(name: .paneQuickOpen, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.control])
                Button("Quick Open (Command-P)") {
                    NotificationCenter.default.post(name: .paneQuickOpen, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command])
            }
        }
    }
}

private struct AdaptiveAppIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear(perform: updateIcon)
            .onChange(of: colorScheme) { _, _ in updateIcon() }
    }

    private func updateIcon() {
        let name = colorScheme == .dark ? "PaneIconDark" : "PaneIconLight"
        if let icon = NSImage(named: NSImage.Name(name)) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}
