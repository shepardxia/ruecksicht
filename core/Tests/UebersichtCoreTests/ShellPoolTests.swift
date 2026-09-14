import XCTest
@testable import UebersichtCore

final class PersistentShellTests: XCTestCase {
    private func shell() throws -> PersistentShell {
        let shell = try PersistentShell(workingDirectory: NSTemporaryDirectory())
        addTeardownBlock { shell.terminate() }
        return shell
    }

    func testSeparatesOutputStreamsAndExitCodes() throws {
        let shell = try shell()
        XCTAssertEqual(try shell.run("echo hello"), TickResult(stdout: "hello\n", stderr: "", exitCode: 0))
        XCTAssertEqual(try shell.run("echo oops >&2"), TickResult(stdout: "", stderr: "oops\n", exitCode: 0))
        XCTAssertEqual(try shell.run("exit 3").exitCode, 3)
    }

    /// The reason commands arrive on fd 3 rather than stdin. A widget running
    /// `cat`, `read` or `ssh host uptime` would otherwise swallow the next
    /// widget's command off the control channel.
    func testACommandReadingStdinDoesNotEatTheNextOne() throws {
        let shell = try shell()
        _ = try shell.run("cat")
        XCTAssertEqual(try shell.run("echo still here").stdout, "still here\n")
    }

    /// The driver evaluates each command in a subshell, so a widget that exports
    /// a variable, changes directory or defines a function cannot alter what the
    /// next tick -- possibly another widget -- runs in.
    func testOneCommandCannotChangeTheShellTheNextOneGets() throws {
        let shell = try shell()
        _ = try shell.run("export UB_TEST=leaked; cd /")
        XCTAssertEqual(try shell.run("echo ${UB_TEST:-clean}").stdout, "clean\n")
        XCTAssertNotEqual(try shell.run("pwd").stdout, "/\n")
    }

    func testRunsInTheWorkingDirectoryItWasGiven() throws {
        let shell = try shell()
        let actual = try shell.run("pwd").stdout.trimmingCharacters(in: .newlines)
        XCTAssertEqual(
            URL(fileURLWithPath: actual).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        )
    }

    /// The HTTP thread serving a widget's `run()` and the command loop reach
    /// the same shell whenever their command text matches.
    func testConcurrentCommandsDoNotReadEachOthersOutput() throws {
        let shell = try shell()
        let lock = NSLock()
        var outputs: [Int: String] = [:]

        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let stdout = (try? shell.run("echo \(index)"))?.stdout
            lock.lock()
            outputs[index] = stdout
            lock.unlock()
        }

        for index in 0..<8 {
            XCTAssertEqual(outputs[index], "\(index)\n")
        }
    }

    func testTerminatedShellRefusesFurtherCommands() throws {
        let shell = try PersistentShell(workingDirectory: NSTemporaryDirectory())
        shell.terminate()
        XCTAssertFalse(shell.isAlive)
        XCTAssertThrowsError(try shell.run("echo hi"))
    }
}

final class ShellPoolTests: XCTestCase {
    /// One shell per distinct command, so a widget cannot see another's
    /// environment.
    func testGivesEachCommandItsOwnShell() throws {
        let pool = ShellPool(workingDirectory: NSTemporaryDirectory())
        _ = try pool.run("export UB_POOL=one")
        XCTAssertEqual(try pool.run("echo ${UB_POOL:-unset}").stdout, "unset\n")
    }

    func testReusesTheShellForARepeatedCommand() throws {
        let pool = ShellPool(workingDirectory: NSTemporaryDirectory())
        let first = try pool.run("echo $$").stdout
        XCTAssertEqual(try pool.run("echo $$").stdout, first)
    }

    /// `$$` names the persistent bash, not the subshell a command runs in, so a
    /// changed value means the old shell was evicted and a new one spawned.
    func testEvictsTheLeastRecentlyUsedShellOverTheCap() throws {
        let pool = ShellPool(workingDirectory: NSTemporaryDirectory())
        let oldest = "echo $$ # oldest"
        let before = try pool.run(oldest).stdout

        for filler in 0...ShellPool.capacity {
            _ = try pool.run("echo filler\(filler)")
        }

        XCTAssertNotEqual(try pool.run(oldest).stdout, before)
    }
}
