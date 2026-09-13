import Foundation

/// The current set of widgets, refreshed when the directory changes rather than
/// rebuilt per request.
///
/// Serving a bundle or a state document used to re-list the directory and
/// re-read every widget's source to answer one question about one widget.
public final class WidgetIndex {
    private let directory: String
    private let lock = NSLock()
    private var widgets: [Widget] = []
    private var driven: Set<String> = []

    public init(directory: String) {
        self.directory = directory
        refresh()
    }

    /// Re-reads the directory. Whether a widget's command can be hoisted is
    /// decided here too, so the answer is read from source once per change
    /// rather than once per request.
    @discardableResult
    public func refresh() -> [Widget] {
        let found = WidgetDirectory.scan(directory)
        var hoistable: Set<String> = []
        for widget in found where WidgetSource.schedule(forSourceAt: widget.path) != nil {
            hoistable.insert(widget.id)
        }
        lock.lock()
        widgets = found
        driven = hoistable
        lock.unlock()
        return found
    }

    public var all: [Widget] {
        lock.lock(); defer { lock.unlock() }
        return widgets
    }

    public func widget(id: String) -> Widget? {
        lock.lock(); defer { lock.unlock() }
        return widgets.first { $0.id == id }
    }

    public func isServerDriven(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return driven.contains(id)
    }
}
