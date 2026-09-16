import Foundation

/// The current set of widgets, refreshed when a source changes rather than
/// rebuilt per request.
public final class WidgetIndex {
    private let registry: String
    private let defaultDirectory: String
    private let lock = NSLock()
    private var widgets: [Widget] = []
    private var sourceList: [String] = []

    public init(registry: String, defaultDirectory: String) {
        self.registry = registry
        self.defaultDirectory = defaultDirectory
        refresh()
    }

    /// Re-reads the registry and every source.
    @discardableResult
    public func refresh() -> [Widget] {
        let sources = Sources.read(registry: registry, defaultDirectory: defaultDirectory)
        let found = Sources.scan(sources)
        lock.lock()
        widgets = found
        sourceList = sources
        lock.unlock()
        return found
    }

    public var all: [Widget] {
        lock.lock(); defer { lock.unlock() }
        return widgets
    }

    public var sources: [String] {
        lock.lock(); defer { lock.unlock() }
        return sourceList
    }

    public func widget(id: String) -> Widget? {
        lock.lock(); defer { lock.unlock() }
        return widgets.first { $0.id == id }
    }

    /// The directory whose files are served under `name`.
    public func directory(named name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return widgets.first { $0.name == name }?.directory
    }
}
