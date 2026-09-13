import Foundation

/// One tick's result. Identity is the whole triple: a command that starts
/// failing while printing the same thing to stdout has changed, and comparing
/// stdout alone would pin the widget to a stale error forever.
public struct TickResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Holds each widget's latest result and tracks what every page has already
/// been told, so a command runs once and fans out to every screen showing it.
///
/// The ledger is per subscriber rather than one global "last sent" value. With
/// a single value, a page that connects late, or reloads after a display
/// hot-plug, is told nothing until the next real change and renders blank.
public actor WidgetState {
    private struct Record {
        var result: TickResult
        var sequence: Int
    }

    private var records: [String: Record] = [:]
    private var delivered: [String: [String: Int]] = [:]
    private var sequence = 0

    public init() {}

    public var widgetCount: Int { records.count }

    /// Returns true when this is a real change. An unchanged triple is dropped
    /// here, before any page is woken to re-render identical output.
    @discardableResult
    public func record(widget: String, result: TickResult) -> Bool {
        if let existing = records[widget], existing.result == result {
            return false
        }
        sequence += 1
        records[widget] = Record(result: result, sequence: sequence)
        return true
    }

    public func latest(widget: String) -> TickResult? {
        records[widget]?.result
    }

    /// What this page has not yet been shown. A page that has seen nothing gets
    /// everything, which is what makes reconnect and hot-plug repaint correctly.
    public func pending(for page: String) -> [String: TickResult] {
        var out: [String: TickResult] = [:]
        for (widget, record) in records {
            let seen = delivered[page]?[widget] ?? 0
            if record.sequence > seen {
                out[widget] = record.result
            }
        }
        return out
    }

    public func markDelivered(page: String, widgets: [String]) {
        for widget in widgets {
            guard let record = records[widget] else { continue }
            delivered[page, default: [:]][widget] = record.sequence
        }
    }

    public func forget(page: String) {
        delivered.removeValue(forKey: page)
    }

    public func forget(widget: String) {
        records.removeValue(forKey: widget)
        for page in delivered.keys {
            delivered[page]?.removeValue(forKey: widget)
        }
    }
}
