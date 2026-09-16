import Foundation

public enum Grid {
    /// Deadlines are quantized onto this grid so widgets registered at
    /// different moments wake together instead of drifting apart.
    public static let quantum: TimeInterval = 0.25

    public static func quantize(_ time: TimeInterval) -> TimeInterval {
        (time / quantum).rounded(.up) * quantum
    }
}

/// When each widget's next tick is due. Holds no timer and reads no clock: the
/// time is always passed in. Isolation comes from its owner.
public struct Scheduler {
    private struct Entry {
        var interval: TimeInterval
        var deadline: TimeInterval
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Due at once, then every `interval`: a widget's first reading is the one
    /// on screen while the user is looking at it.
    public mutating func add(id: String, interval: TimeInterval, now: TimeInterval) {
        entries[id] = Entry(interval: interval, deadline: Grid.quantize(now))
    }

    public mutating func remove(id: String) {
        entries.removeValue(forKey: id)
    }

    /// The earliest deadline, or nil when nothing is scheduled.
    public var nextDeadline: TimeInterval? {
        entries.values.map(\.deadline).min()
    }

    /// Every widget due at or before `now`, re-armed onto the next grid slot.
    /// Re-arming from `now` rather than from the missed deadline stops a slow
    /// command from accumulating a backlog of overdue ticks.
    public mutating func due(now: TimeInterval) -> [String] {
        let ready = entries.filter { $0.value.deadline <= now }
            .sorted { $0.value.deadline < $1.value.deadline }
            .map(\.key)
        for id in ready {
            entries[id]!.deadline = Grid.quantize(now + entries[id]!.interval)
        }
        return ready
    }
}
