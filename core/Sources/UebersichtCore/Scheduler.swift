import Foundation

/// When a widget's next tick is due.
///
/// Deadlines are quantized onto a shared grid, so widgets registered at
/// different moments converge on the same wake instants instead of drifting
/// apart: one timer is not one wake unless the deadlines line up.
struct ScheduleEntry: Equatable {
    let id: String
    var interval: TimeInterval
    var deadline: TimeInterval
}

public enum Grid {
    /// Widgets are aligned to this grid so their wakes coalesce.
    public static let quantum: TimeInterval = 0.25

    public static func quantize(_ time: TimeInterval) -> TimeInterval {
        (time / quantum).rounded(.up) * quantum
    }
}

/// Decides which widget runs next. Holds no timer and reads no clock: the time
/// is always passed in. Isolation comes from its owner.
public struct Scheduler {
    private var entries: [String: ScheduleEntry] = [:]

    public init() {}

    public mutating func add(id: String, interval: TimeInterval, now: TimeInterval) {
        entries[id] = ScheduleEntry(
            id: id,
            interval: interval,
            deadline: Grid.quantize(now + interval)
        )
    }

    public mutating func remove(id: String) {
        entries.removeValue(forKey: id)
    }

    /// Every widget due at or before `now`, re-armed onto the next grid slot.
    /// Re-arming from `now` rather than from the missed deadline stops a slow
    /// command from accumulating a backlog of overdue ticks.
    public mutating func due(now: TimeInterval) -> [String] {
        let ready = entries.values
            .filter { $0.deadline <= now }
            .sorted { $0.deadline < $1.deadline }
            .map(\.id)

        for id in ready {
            guard let interval = entries[id]?.interval else { continue }
            entries[id]?.deadline = Grid.quantize(now + interval)
        }
        return ready
    }
}
