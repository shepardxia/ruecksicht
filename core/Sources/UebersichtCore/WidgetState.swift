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

/// Holds each widget's latest result, so a command runs once and fans out to
/// every screen showing it.
public struct WidgetState {
    private var records: [String: TickResult] = [:]

    public init() {}

    /// Returns true when this is a real change. An unchanged triple is dropped
    /// here, before any page is woken to re-render identical output.
    public mutating func record(widget: String, result: TickResult) {
        records[widget] = result
    }

    /// Everything already known, for a page that has just connected. Without it
    /// a page opened between two identical ticks renders nothing until the value
    /// happens to change.
    public func latestAll() -> [String: TickResult] {
        records
    }

    public mutating func forget(widget: String) {
        records.removeValue(forKey: widget)
    }
}
