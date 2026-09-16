import Foundation

/// Runs widget commands on the server, once per widget however many screens
/// show it. Everything the loop mutates lives here rather than in globals the
/// timer and the file watcher would race over.
public actor CommandLoop {
    private struct Entry {
        let schedule: WidgetSource.Schedule
        let directory: String
    }

    private var scheduler = Scheduler()
    private var entries: [String: Entry] = [:]
    private var results: [String: TickResult] = [:]
    private let shells: ShellPool

    public init(shells: ShellPool) {
        self.shells = shells
    }

    public var drivenWidgets: [String] { entries.keys.sorted() }

    /// The latest result of every widget, for a page that has just connected.
    public var currentResults: [(id: String, result: TickResult)] {
        results.map { ($0.key, $0.value) }
    }

    public var nextDeadline: TimeInterval? { scheduler.nextDeadline }

    /// Picks up widgets whose command or cadence changed, and forgets the ones
    /// that are gone. A widget whose command is unchanged keeps its place in
    /// the schedule rather than being re-armed on every save.
    public func refresh(widgets: [Widget], now: TimeInterval) {
        var live = Set<String>()
        for widget in widgets {
            guard let schedule = widget.schedule else { continue }
            live.insert(widget.id)
            if entries[widget.id]?.schedule != schedule {
                scheduler.add(id: widget.id, interval: schedule.interval, now: now)
            }
            entries[widget.id] = Entry(schedule: schedule, directory: widget.workingDirectory)
        }
        for gone in Set(entries.keys).subtracting(live) {
            entries.removeValue(forKey: gone)
            results.removeValue(forKey: gone)
            scheduler.remove(id: gone)
            shells.forget(gone)
        }
    }

    /// Runs whatever is due, concurrently: a widget's command may take seconds
    /// or hang until the shell timeout, and in series it would hold back every
    /// other widget's tick.
    ///
    /// Every tick is reported, including one whose output repeats the last. A
    /// widget's `updateState` is its clock as much as its parser.
    public func tick(now: TimeInterval) async -> [(id: String, result: TickResult)] {
        let due = scheduler.due(now: now).compactMap { id in
            entries[id].map { (id: id, command: $0.schedule.command, directory: $0.directory) }
        }
        guard !due.isEmpty else { return [] }

        let shells = self.shells
        let ran = await withTaskGroup(of: (String, TickResult).self) { group in
            for widget in due {
                group.addTask { (widget.id, await Self.run(widget.command, for: widget.id, in: widget.directory, on: shells)) }
            }
            var all: [(String, TickResult)] = []
            for await result in group { all.append(result) }
            return all
        }
        for (id, result) in ran { results[id] = result }
        return ran.map { (id: $0.0, result: $0.1) }
    }

    /// Off the cooperative pool: a shell command blocks its thread for as long
    /// as it runs, and enough of them would leave the pool with no thread to
    /// resume anything on.
    private nonisolated static func run(_ command: String, for id: String, in directory: String, on shells: ShellPool) async -> TickResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try shells.run(command, for: id, in: directory))
                } catch {
                    continuation.resume(returning: TickResult(stdout: "", stderr: "\(error)", exitCode: -1))
                }
            }
        }
    }
}
