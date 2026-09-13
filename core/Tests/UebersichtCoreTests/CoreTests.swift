import XCTest
@testable import UebersichtCore

final class SchedulerTests: XCTestCase {
    func testDeadlinesLandOnTheSharedGrid() async {
        let scheduler = Scheduler()
        await scheduler.add(id: "a", interval: 1.0, now: 0.13)
        await scheduler.add(id: "b", interval: 1.0, now: 0.31)

        let a = await scheduler.entry("a")!.deadline
        let b = await scheduler.entry("b")!.deadline

        XCTAssertEqual(a.truncatingRemainder(dividingBy: Grid.quantum), 0, accuracy: 1e-9)
        XCTAssertEqual(b.truncatingRemainder(dividingBy: Grid.quantum), 0, accuracy: 1e-9)
    }

    func testWidgetsAddedApartStillCoalesce() async {
        let scheduler = Scheduler()
        // Added 60ms apart; on the grid they converge on the same wake.
        await scheduler.add(id: "a", interval: 5.0, now: 0.01)
        await scheduler.add(id: "b", interval: 5.0, now: 0.07)

        let a = await scheduler.entry("a")!.deadline
        let b = await scheduler.entry("b")!.deadline
        XCTAssertEqual(a, b, accuracy: 1e-9)
    }

    func testDueReturnsOnlyReadyWidgetsAndRearmsThem() async {
        let scheduler = Scheduler()
        await scheduler.add(id: "fast", interval: 0.5, now: 0)
        await scheduler.add(id: "slow", interval: 10, now: 0)

        let firstRound = await scheduler.due(now: 1.0)
        XCTAssertEqual(firstRound, ["fast"])

        let immediatelyAgain = await scheduler.due(now: 1.0)
        XCTAssertTrue(immediatelyAgain.isEmpty, "a widget is not due twice for one deadline")

        let later = await scheduler.due(now: 2.0)
        XCTAssertEqual(later, ["fast"], "it re-armed onto the next slot")
    }

    func testOverdueWidgetsDoNotAccumulateABacklog() async {
        let scheduler = Scheduler()
        await scheduler.add(id: "w", interval: 1.0, now: 0)

        // Nothing ran for a minute: the widget is due once, not sixty times.
        _ = await scheduler.due(now: 60)
        let next = await scheduler.entry("w")!.deadline
        XCTAssertGreaterThan(next, 60)
    }

    func testParkedWidgetsAreNeverDueAndStopTheTimer() async {
        let scheduler = Scheduler()
        await scheduler.add(id: "w", interval: 0.5, now: 0)
        await scheduler.park(id: "w")

        let due = await scheduler.due(now: 100)
        XCTAssertTrue(due.isEmpty, "a parked widget is not due")

        let deadline = await scheduler.nextDeadline()
        XCTAssertNil(deadline, "with everything parked there is no reason to wake")
    }

    func testUnparkingRearmsFromNowNotFromTheMissedDeadline() async {
        let scheduler = Scheduler()
        await scheduler.add(id: "w", interval: 1.0, now: 0)
        await scheduler.park(id: "w")
        await scheduler.unpark(id: "w", now: 500)

        let due = await scheduler.due(now: 500)
        XCTAssertTrue(due.isEmpty, "waking does not immediately fire a stale tick")
        let deadline = await scheduler.nextDeadline()
        XCTAssertNotNil(deadline)
    }

    func testLeewayIsClampedToAUsefulRange() {
        XCTAssertEqual(Grid.leeway(for: 0.2), 0.05, accuracy: 1e-9)
        XCTAssertEqual(Grid.leeway(for: 10), 1.0, accuracy: 1e-9)
        XCTAssertEqual(Grid.leeway(for: 3600), 5.0, accuracy: 1e-9)
    }
}

final class WidgetStateTests: XCTestCase {
    private let first = TickResult(stdout: "88", stderr: "", exitCode: 0)

    func testAnUnchangedTickIsDropped() async {
        let state = WidgetState()
        let changed = await state.record(widget: "w", result: first)
        let again = await state.record(widget: "w", result: first)

        XCTAssertTrue(changed)
        XCTAssertFalse(again, "an identical triple is not a change")
    }

    func testStderrAloneCountsAsAChange() async {
        let state = WidgetState()
        await state.record(widget: "w", result: first)
        let changed = await state.record(
            widget: "w",
            result: TickResult(stdout: "88", stderr: "boom", exitCode: 0)
        )
        XCTAssertTrue(changed, "same stdout but now failing is a change")
    }

    func testExitCodeAloneCountsAsAChange() async {
        let state = WidgetState()
        await state.record(widget: "w", result: first)
        let changed = await state.record(
            widget: "w",
            result: TickResult(stdout: "88", stderr: "", exitCode: 1)
        )
        XCTAssertTrue(changed, "same output but a new exit code is a change")
    }

    func testOneRunFansOutToEveryPage() async {
        let state = WidgetState()
        await state.record(widget: "w", result: first)

        let one = await state.pending(for: "screen-1")
        let two = await state.pending(for: "screen-2")
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(two.count, 1)

        await state.markDelivered(page: "screen-1", widgets: ["w"])
        let afterDelivery = await state.pending(for: "screen-1")
        let untouched = await state.pending(for: "screen-2")
        XCTAssertTrue(afterDelivery.isEmpty)
        XCTAssertEqual(
            untouched.count, 1,
            "delivering to one page does not mark the others"
        )
    }

    func testAPageThatHasSeenNothingGetsEverything() async {
        let state = WidgetState()
        await state.record(widget: "a", result: first)
        await state.record(widget: "b", result: first)
        await state.markDelivered(page: "old", widgets: ["a", "b"])

        // A display hot-plug brings up a page that has seen nothing; it must
        // repaint from truth rather than wait for the next change.
        let fresh = await state.pending(for: "new-screen")
        XCTAssertEqual(fresh.count, 2)
    }

    func testForgettingAPageMakesItPendingAgain() async {
        let state = WidgetState()
        await state.record(widget: "w", result: first)
        await state.markDelivered(page: "p", widgets: ["w"])
        await state.forget(page: "p")
        let pending = await state.pending(for: "p")
        XCTAssertEqual(pending.count, 1)
    }
}

final class ShellPoolTests: XCTestCase {
    private var pool: ShellPool!

    override func setUp() {
        pool = ShellPool(workingDirectory: "/tmp")
    }

    override func tearDown() {
        pool.shutdown()
        pool = nil
    }

    func testItRunsACommand() throws {
        let result = try pool.run("echo yay")
        XCTAssertEqual(result.stdout, "yay\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testStreamsAndExitCodeStaySeparate() throws {
        let result = try pool.run("echo out; echo err >&2; exit 7")
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertEqual(result.exitCode, 7)
    }

    func testBashErrorsKeepTheirOriginalLineNumbers() throws {
        let single = try pool.run("fake-command")
        XCTAssertEqual(single.stderr, "bash: line 1: fake-command: command not found\n")

        let multi = try pool.run("echo a\necho b\nfake-command")
        XCTAssertTrue(multi.stderr.contains("line 3:"), multi.stderr)
    }

    func testTheShellPersistsBetweenTicks() throws {
        let first = try pool.run("echo $$").stdout
        let second = try pool.run("echo $$").stdout
        XCTAssertEqual(first, second, "the same command reuses the same shell")
        XCTAssertEqual(pool.shellCount, 1)
    }

    func testCommandsRunWithStdinAtEOF() throws {
        // Reading stdin must not consume the control channel, or this widget
        // would swallow the next one's command text.
        let read = try pool.run("read x; echo \"[$x]\"")
        XCTAssertEqual(read.stdout, "[]\n")

        let after = try pool.run("echo survived")
        XCTAssertEqual(after.stdout, "survived\n", "the next command is intact")
    }

    func testStateCannotLeakIntoALaterTick() throws {
        _ = try pool.run("cd /; export LEAKED=1")
        let after = try pool.run("pwd; echo \"[$LEAKED]\"")
        let lines = after.stdout.split(separator: "\n").map(String.init)

        // The working directory is compared by suffix: /tmp is a symlink to
        // /private/tmp and bash reports the resolved path.
        XCTAssertTrue(lines[0].hasSuffix("/tmp"), "cd did not escape: \(lines[0])")
        XCTAssertEqual(lines[1], "[]", "export did not escape")
    }

    func testMultilineCommands() throws {
        let result = try pool.run("echo one\necho two")
        XCTAssertEqual(result.stdout, "one\ntwo\n")
    }

    func testOutputContainingTheFramingByteSurvives() throws {
        let result = try pool.run(#"printf "a\036b\036c\n""#)
        XCTAssertEqual(result.stdout, "a\u{1E}b\u{1E}c\n")
    }
}
