import AmamacModels
import CoreServices
import Foundation

/// Watches collection folders with FSEvents and reports changed directories after a quiet period.
public final class FolderWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (_ directories: [String]) -> Void

    private let queue = DispatchQueue(label: "amamac.folderwatcher")
    private var stream: FSEventStreamRef?
    private var pending = Set<String>()
    private var debounce: DispatchWorkItem?
    private var ignored: [String: Date] = [:]
    private let latency: TimeInterval
    private let handler: Handler

    public init(latency: TimeInterval = 3, handler: @escaping Handler) {
        self.latency = latency
        self.handler = handler
    }

    deinit { stopSync() }

    public func watch(paths: [String]) {
        queue.async { [self] in
            stopSync()
            guard !paths.isEmpty else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                watcher.received(Array(list.prefix(count)))
            }
            let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
    }

    /// Suppresses events for `path` (e.g. our own tag writes) for a few seconds.
    public func ignore(path: String, for seconds: TimeInterval = 5) {
        queue.async { self.ignored[path] = Date().addingTimeInterval(seconds) }
    }

    public func stop() { queue.async { self.stopSync() } }

    private func stopSync() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func received(_ paths: [String]) {
        let now = Date()
        ignored = ignored.filter { $0.value > now }
        for path in paths {
            if ignored[path] != nil { continue }
            let ext = (path as NSString).pathExtension.lowercased()
            let isRelevant = ext.isEmpty || AudioFileTypes.extensions.contains(ext) || PlaylistFileFormat(rawValue: ext) != nil
            guard isRelevant, !(path as NSString).lastPathComponent.hasPrefix(".") else { continue }
            pending.insert(ext.isEmpty ? path : (path as NSString).deletingLastPathComponent)
        }
        guard !pending.isEmpty else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [self] in
            let dirs = Array(pending)
            pending.removeAll()
            handler(dirs)
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + latency, execute: work)
    }
}
