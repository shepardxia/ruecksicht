import XCTest
@testable import UebersichtCore

final class CommandLoopTests: XCTestCase {
    private func widget(_ id: String, command: String, every interval: TimeInterval) -> Widget {
        Widget(
            id: id, path: "/tmp/\(id).jsx", modified: Date(), directory: NSTemporaryDirectory(), name: id,
            workingDirectory: NSTemporaryDirectory(),
            schedule: WidgetSource.Schedule(command: command, interval: interval)
        )
    }

    func testAWidgetIsDueAtOnceAndThenOnItsInterval() async {
        let loop = CommandLoop(shells: ShellPool())
        await loop.refresh(widgets: [widget("a", command: "echo a", every: 10)], now: 100)

        let first = await loop.claim(now: 100)
        XCTAssertEqual(first.map(\.id), ["a"])
        let result = await loop.run(first[0])
        XCTAssertEqual(result.stdout, "a\n")

        let early = await loop.claim(now: 105)
        XCTAssertTrue(early.isEmpty)
        let next = await loop.claim(now: 110)
        XCTAssertEqual(next.map(\.id), ["a"])
    }

    /// A command still running when its widget comes due again must not stop
    /// the others from being claimed, nor be started a second time.
    func testASlowCommandHoldsBackOnlyItsOwnWidget() async {
        let loop = CommandLoop(shells: ShellPool())
        await loop.refresh(widgets: [
            widget("slow", command: "sleep 1; echo done", every: 1),
            widget("fast", command: "echo fast", every: 1),
        ], now: 100)

        let first = await loop.claim(now: 100)
        XCTAssertEqual(Set(first.map(\.id)), ["slow", "fast"])
        let slow = first.first { $0.id == "slow" }!
        let fast = first.first { $0.id == "fast" }!
        async let slowResult = loop.run(slow)
        _ = await loop.run(fast)

        let second = await loop.claim(now: 101)
        XCTAssertEqual(second.map(\.id), ["fast"])
        _ = await loop.run(second[0])

        let finished = await slowResult
        XCTAssertEqual(finished.stdout, "done\n")
        let third = await loop.claim(now: 102)
        XCTAssertEqual(Set(third.map(\.id)), ["slow", "fast"])
    }

    func testAResultArrivingAfterItsWidgetIsGoneIsNotKept() async {
        let loop = CommandLoop(shells: ShellPool())
        await loop.refresh(widgets: [widget("a", command: "echo a", every: 10)], now: 100)
        let jobs = await loop.claim(now: 100)
        await loop.refresh(widgets: [], now: 100)
        _ = await loop.run(jobs[0])
        let kept = await loop.currentResults
        XCTAssertTrue(kept.isEmpty)
    }

    func testATickReportsEachResult() async {
        let loop = CommandLoop(shells: ShellPool())
        await loop.refresh(widgets: [widget("a", command: "echo a", every: 10)], now: 100)

        let reported = expectation(description: "result reported")
        await loop.tick(now: 100) { id, result in
            XCTAssertEqual(id, "a")
            XCTAssertEqual(result.stdout, "a\n")
            reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 5)
    }
}
