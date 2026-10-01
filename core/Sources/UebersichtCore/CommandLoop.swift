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
    private var running = Set<String>()
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

    /// Starts the command of every widget that is due and returns without
    /// waiting for any of them: a command may take seconds, or hang until the
    /// shell timeout. Each result goes to `report` as it arrives, including
    /// one that repeats the last: a widget's `updateState` is its clock as
    /// much as its parser.
    public func tick(now: TimeInterval, report: @escaping @Sendable (String, TickResult) -> Void) {
        for job in claim(now: now) {
            Task { report(job.id, await run(job)) }
        }
    }

    /// One due tick of one widget. Its widget is not claimed again until the
    /// job has been run.
    struct Job: Sendable {
        let id: String
        let command: String
        let directory: String
    }

    /// A widget whose last command is still running sits the tick out. Its
    /// shell runs one command at a time, and ticks queued behind a hung one
    /// would only pile up.
    func claim(now: TimeInterval) -> [Job] {
        scheduler.due(now: now).compactMap { id in
            guard let entry = entries[id], running.insert(id).inserted else { return nil }
            return Job(id: id, command: entry.schedule.command, directory: entry.directory)
        }
    }

    func run(_ job: Job) async -> TickResult {
        let result = await Self.run(job.command, for: job.id, in: job.directory, on: shells)
        running.remove(job.id)
        if entries[job.id] != nil { results[job.id] = result }
        return result
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
