# Pane

A fast, native macOS Git editor built with SwiftUI and AppKit.

Pane keeps the workflow intentionally small: source control and a commit graph on the left, native editable files and read-only diffs on the right, plus a glass Quick Open palette on Control-P or Command-P.

## Requirements

- macOS 26 or newer on Apple Silicon
- Xcode 26.6
- XcodeGen
- Git available at `/opt/homebrew/bin/git`, `/usr/local/bin/git`, or `/usr/bin/git`

## Build

```sh
xcodegen generate
xcodebuild -project Pane.xcodeproj -scheme Pane -configuration Release build
```

Open any Git repository with Command-O, drag a repository folder onto Pane, select a recent repository, or launch the executable with an absolute repository path.

Pane is non-sandboxed and uses your existing Git configuration, credential helpers, hooks, SSH agent, and signing settings. It never force-pushes, automatically stashes, rebases, or merges.
