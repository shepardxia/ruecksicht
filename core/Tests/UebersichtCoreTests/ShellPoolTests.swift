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

    /// A slow tick can still be running when the next one reaches the shell.
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
    private let dir = NSTemporaryDirectory()

    /// `$$` names the persistent bash, not the subshell a command runs in.
    func testKeepsOneShellPerWidget() throws {
        let pool = ShellPool()
        let first = try pool.run("echo $$", for: "a", in: dir).stdout
        XCTAssertEqual(try pool.run("echo $$", for: "a", in: dir).stdout, first)
        XCTAssertNotEqual(try pool.run("echo $$", for: "b", in: dir).stdout, first)
    }

    func testReplacesAShellThatDied() throws {
        let pool = ShellPool()
        let first = try pool.run("echo $$", for: "a", in: dir).stdout
        _ = try? pool.run("kill -9 $$", for: "a", in: dir)
        let again = try pool.run("echo $$", for: "a", in: dir).stdout
        XCTAssertNotEqual(again, first)
    }

    func testForgottenWidgetGetsAFreshShell() throws {
        let pool = ShellPool()
        let first = try pool.run("echo $$", for: "a", in: dir).stdout
        pool.forget("a")
        XCTAssertNotEqual(try pool.run("echo $$", for: "a", in: dir).stdout, first)
    }

    func testAdHocCommandsEachGetTheirOwnShell() throws {
        let pool = ShellPool()
        XCTAssertNotEqual(try pool.run("echo $$", in: dir).stdout, try pool.run("echo $$", in: dir).stdout)
    }
}
