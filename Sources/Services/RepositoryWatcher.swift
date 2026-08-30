import CoreServices
import Foundation

enum RepositoryChangeKind: Int, Sendable, Comparable {
    case index = 0
    case history = 1
    case workingTree = 2

    static func < (lhs: RepositoryChangeKind, rhs: RepositoryChangeKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

final class RepositoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let rootPath: String
    private let callback: @Sendable (RepositoryChangeKind) -> Void
    private let queue = DispatchQueue(label: "com.enzo.Pane.repository-watcher", qos: .utility)

    init(url: URL, callback: @escaping @Sendable (RepositoryChangeKind) -> Void) {
        rootPath = url.standardizedFileURL.path
        self.callback = callback
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(
            nil,
            { _, info, count, pathsPointer, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(pathsPointer, to: NSArray.self) as? [String] ?? []
                watcher.callback(watcher.classify(paths: Array(paths.prefix(count))))
            },
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func classify(paths: [String]) -> RepositoryChangeKind {
        let gitPath = rootPath + "/.git"
        var result = RepositoryChangeKind.index
        for path in paths {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            if standardized == gitPath + "/index" || standardized == gitPath + "/index.lock" {
                continue
            }
            if standardized == gitPath || standardized.hasPrefix(gitPath + "/") {
                result = max(result, .history)
            } else {
                return .workingTree
            }
        }
        return result
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
