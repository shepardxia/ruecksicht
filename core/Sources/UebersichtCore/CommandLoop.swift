import Foundation

/// Runs widget commands on the server, once per widget however many screens
/// show it, and reports only the ticks whose output actually changed.
///
/// Everything the loop mutates lives here rather than in globals the timer and
/// the file watcher would race over.
public actor CommandLoop {
    private var scheduler = Scheduler()
    private var state = WidgetState()
    private let shells: ShellPool
    private let widgetDirectory: String
    private var schedules: [String: WidgetSource.Schedule] = [:]

    public init(shells: ShellPool, widgetDirectory: String) {
        self.shells = shells
        self.widgetDirectory = widgetDirectory
    }

    public var drivenWidgets: [String] { schedules.keys.sorted() }

    /// Everything already known, for a page that has just connected. Without
    /// this a page opened between two identical ticks renders nothing until the
    /// value happens to change.
    public func currentResults() -> [(id: String, result: TickResult)] {
        state.latestAll().map { ($0.key, $0.value) }
    }

    /// Picks up widgets whose command or cadence changed, and forgets the ones
    /// that are gone. A widget whose command is unchanged keeps its place in
    /// the schedule rather than being re-armed on every save.
    public func refresh(now: TimeInterval) {
        var live = Set<String>()
        for widget in WidgetDirectory.scan(widgetDirectory) {
            guard let schedule = WidgetSource.schedule(forSourceAt: widget.path) else { continue }
            live.insert(widget.id)
            if schedules[widget.id]?.command != schedule.command
                || schedules[widget.id]?.interval != schedule.interval
            {
                schedules[widget.id] = schedule
                scheduler.remove(id: widget.id)
                scheduler.add(id: widget.id, interval: schedule.interval, now: now)
            }
        }
        for gone in Set(schedules.keys).subtracting(live) {
            schedules.removeValue(forKey: gone)
            scheduler.remove(id: gone)
            state.forget(widget: gone)
        }
    }

    /// Runs whatever is due and returns only the results worth sending.
    public func tick(now: TimeInterval) -> [(id: String, result: TickResult)] {
        var changed: [(id: String, result: TickResult)] = []
        for id in scheduler.due(now: now) {
            guard let schedule = schedules[id] else { continue }
            let result: TickResult
            do {
                result = try shells.run(schedule.command)
            } catch {
                result = TickResult(stdout: "", stderr: "\(error)", exitCode: -1)
            }
            if state.record(widget: id, result: result) {
                changed.append((id, result))
            }
        }
        return changed
    }
}
