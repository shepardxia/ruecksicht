import Foundation

/// When a widget's next tick is due, and whether it should run at all.
///
/// Deadlines are quantized onto a shared grid *before* leeway is applied, so N
/// widgets converge on the same wake instants instead of drifting apart. One
/// timer is not one wake unless the deadlines line up; leeway alone merges
/// nothing once phases have separated.
public struct ScheduleEntry: Equatable, Sendable {
    public let id: String
    public var interval: TimeInterval
    public var deadline: TimeInterval
    public var parked: Bool

    public init(id: String, interval: TimeInterval, deadline: TimeInterval, parked: Bool = false) {
        self.id = id
        self.interval = interval
        self.deadline = deadline
        self.parked = parked
    }
}

public enum Grid {
    /// Widgets are aligned to this grid so their wakes coalesce.
    public static let quantum: TimeInterval = 0.25

    public static func quantize(_ time: TimeInterval) -> TimeInterval {
        (time / quantum).rounded(.up) * quantum
    }

    /// Leeway lets the OS slide a wake into a batch it was already making.
    /// Clamped so a fast widget stays responsive and a slow one is very cheap.
    public static func leeway(for interval: TimeInterval) -> TimeInterval {
        min(max(interval / 10, 0.05), 5.0)
    }
}

/// Decides which widget runs next. Holds no timer and reads no clock: the time
/// is always passed in, which is what makes the ordering testable.
public actor Scheduler {
    private var entries: [String: ScheduleEntry] = [:]

    public init() {}

    public var count: Int { entries.count }

    public func entry(_ id: String) -> ScheduleEntry? { entries[id] }

    public func add(id: String, interval: TimeInterval, now: TimeInterval) {
        entries[id] = ScheduleEntry(
            id: id,
            interval: interval,
            deadline: Grid.quantize(now + interval)
        )
    }

    public func remove(id: String) {
        entries.removeValue(forKey: id)
    }

    /// A parked widget keeps its registration but is never handed back as due,
    /// and is not re-armed. Occlusion, display sleep and Low Power Mode all
    /// park; nothing re-arms until the widget is explicitly unparked.
    public func park(id: String) {
        entries[id]?.parked = true
    }

    public func unpark(id: String, now: TimeInterval) {
        guard var entry = entries[id], entry.parked else { return }
        entry.parked = false
        entry.deadline = Grid.quantize(now + entry.interval)
        entries[id] = entry
    }

    public func parkAll() {
        for id in Array(entries.keys) { entries[id]?.parked = true }
    }

    public func unparkAll(now: TimeInterval) {
        for id in Array(entries.keys) { unpark(id: id, now: now) }
    }

    /// The instant the single timer should next fire, or nil when everything is
    /// parked and the process has no reason to wake at all.
    public func nextDeadline() -> TimeInterval? {
        entries.values.filter { !$0.parked }.map(\.deadline).min()
    }

    public func leewayForNextDeadline() -> TimeInterval? {
        let live = entries.values.filter { !$0.parked }
        guard let soonest = live.min(by: { $0.deadline < $1.deadline }) else { return nil }
        return Grid.leeway(for: soonest.interval)
    }

    /// Every widget due at or before `now`, re-armed onto the next grid slot.
    /// Re-arming from `now` rather than from the missed deadline stops a slow
    /// command from accumulating a backlog of overdue ticks.
    public func due(now: TimeInterval) -> [String] {
        let ready = entries.values
            .filter { !$0.parked && $0.deadline <= now }
            .sorted { $0.deadline < $1.deadline }
            .map(\.id)

        for id in ready {
            guard let interval = entries[id]?.interval else { continue }
            entries[id]?.deadline = Grid.quantize(now + interval)
        }
        return ready
    }
}
