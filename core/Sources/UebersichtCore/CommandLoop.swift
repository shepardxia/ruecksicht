import Foundation

/// Runs widget commands on the server, once per widget however many screens
/// show it.
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

    /// Runs whatever is due.
    ///
    /// Every tick is reported, including one whose output repeats the last.
    /// A widget's `updateState` is its clock as much as its parser -- a widget
    /// that animates from command output stops moving the moment an identical
    /// result is swallowed.
    ///
    /// The commands run off the actor and alongside each other. A widget's
    /// command is a shell process that may take seconds or hang until the
    /// shell timeout, and in series one such widget would hold back every
    /// other widget's tick and every page that has just connected.
    public func tick(now: TimeInterval) async -> [(id: String, result: TickResult)] {
        let due = scheduler.due(now: now).compactMap { id in
            schedules[id].map { (id: id, command: $0.command) }
        }
        guard !due.isEmpty else { return [] }

        let shells = self.shells
        let results = await withTaskGroup(of: (String, TickResult).self) { group in
            for widget in due {
                group.addTask { (widget.id, await Self.run(widget.command, on: shells)) }
            }
            var all: [(String, TickResult)] = []
            for await result in group { all.append(result) }
            return all
        }

        for (id, result) in results {
            state.record(widget: id, result: result)
        }
        return results.map { (id: $0.0, result: $0.1) }
    }

    /// Off the cooperative pool: a shell command blocks its thread for as long
    /// as it runs, and enough of them would leave the pool with no thread to
    /// resume anything on.
    private nonisolated static func run(_ command: String, on shells: ShellPool) async -> TickResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try shells.run(command))
                } catch {
                    continuation.resume(
                        returning: TickResult(stdout: "", stderr: "\(error)", exitCode: -1)
                    )
                }
            }
        }
    }
}
