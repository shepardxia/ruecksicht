import Foundation

/// Watches a widget directory and reports what changed.
///
/// Events are coalesced on a short delay: an editor writing a file produces
/// several FSEvents, and rebundling a widget once per keystroke-flurry is the
/// difference between a responsive save and a stuttering one.
public final class DirectoryWatcher {
    public enum Change: Equatable {
        case widgets
        case masterStyle
    }

    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: (Set<Change>) -> Void
    private let queue = DispatchQueue(label: "ub.watch")
    private var pending: Set<Change> = []
    private var coalescing: DispatchWorkItem?

    public init(path: String, onChange: @escaping (Set<Change>) -> Void) {
        self.path = path
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handle(Array(list.prefix(count)))
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            // UseCFTypes is what makes eventPaths a CFArray of strings; without
            // it FSEvents hands back a C char**, and reading that as an array
            // of objects segfaults.
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(_ changed: [String]) {
        for file in changed {
            if file.hasSuffix("/main.css") {
                pending.insert(.masterStyle)
            } else if WidgetDirectory.sourceExtensions.contains((file as NSString).pathExtension) {
                pending.insert(.widgets)
            }
        }
        guard !pending.isEmpty else { return }

        coalescing?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = self.pending
            self.pending = []
            self.onChange(batch)
        }
        coalescing = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
