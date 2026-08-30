import AppKit
import SwiftUI

@main
struct PaneApp: App {
    init() {
#if !DEBUG
        CommandLineInstaller.installIfNeeded()
#endif
    }

    var body: some Scene {
        WindowGroup {
            PaneRootView()
                .frame(minWidth: 340, minHeight: 640)
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
                Divider()
                Button("Next Tab") {
                    NotificationCenter.default.post(name: .paneSelectNextTab, object: nil)
                }
                .keyboardShortcut(.tab, modifiers: [.control])
                Button("Previous Tab") {
                    NotificationCenter.default.post(name: .paneSelectPreviousTab, object: nil)
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button("Close Tab") {
                    NotificationCenter.default.post(name: .paneCloseCurrentTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.control])
            }
        }
    }
}

private enum CommandLineInstaller {
    private static let marker = "# Pane command-line launcher"

    static func installIfNeeded() {
        guard let destination = launcherDestination() else { return }
        let appPath = shellDoubleQuoted(Bundle.main.bundleURL.path)
        let script = """
        #!/bin/zsh
        \(marker)
        set -e
        pane_app_path="\(appPath)"
        if (( $# == 0 )); then
          exec /usr/bin/open -n "$pane_app_path"
        fi
        typeset -a pane_paths
        for pane_arg in "$@"; do
          if [[ "$pane_arg" == /* ]]; then
            pane_paths+=("$pane_arg")
          else
            pane_paths+=("$PWD/$pane_arg")
          fi
        done
        exec /usr/bin/open -n "$pane_app_path" --args "${pane_paths[@]}"
        """

        if let existing = try? String(contentsOf: destination, encoding: .utf8),
           !existing.contains(marker) {
            return
        }
        do {
            try script.write(to: destination, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        } catch {
            // The app remains usable if the command-line launcher cannot be installed.
        }
    }

    private static func launcherDestination() -> URL? {
        let fileManager = FileManager.default
        let homeBin = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        try? fileManager.createDirectory(at: homeBin, withIntermediateDirectories: true)
        let candidates = [URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true), homeBin]
        guard let directory = candidates.first(where: { fileManager.isWritableFile(atPath: $0.path) }) else { return nil }
        return directory.appendingPathComponent("pane")
    }

    private static func shellDoubleQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
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
