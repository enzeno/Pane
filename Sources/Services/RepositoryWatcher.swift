import CoreServices
import Foundation

final class RepositoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let callback: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.enzo.Pane.repository-watcher", qos: .utility)

    init(url: URL, callback: @escaping @Sendable () -> Void) {
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
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue().callback()
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

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

