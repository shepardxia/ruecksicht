import Foundation

public struct TickResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// A persistent bash, fed commands on fd 3.
///
/// fd 3 rather than stdin: a widget command containing `read`, a bare `cat` or
/// `ssh host uptime` would otherwise consume the next command's text off the
/// control channel, and one widget would silently eat another's script.
///
/// Foundation's Process cannot map a descriptor above 2, so the child is spawned
/// with posix_spawn and explicit file actions.
public final class PersistentShell: @unchecked Sendable {
    public enum ShellError: Error {
        case spawnFailed(Int32)
        case died
        case timedOut(TimeInterval)
    }

    /// Must stay on ONE physical line. A multi-line driver makes bash report its
    /// own line numbers, so `bash: line 1:` from a widget's own command becomes
    /// a line number inside this loop instead.
    private static let driver = """
        __ubnl=$'\\n'; while IFS= read -r __ubn <&3; do __ubc=$__ubnl; \
        while IFS= read -r __ubl <&3; do [ "$__ubl" = "$__ubn" ] && break; \
        __ubc="$__ubc$__ubl$__ubnl"; done; ( eval "$__ubc" ) </dev/null; __ubr=$?; \
        printf '\\036%s %d\\036\\n' "$__ubn" "$__ubr"; \
        printf '\\036%s\\036\\n' "$__ubn" >&2; done
        """

    private static let recordSeparator = "\u{1E}"

    /// How long a single command may hold its shell. A command that outlasts
    /// this has hung, and the shell is dropped rather than waited on.
    static let timeout: TimeInterval = 30

    public let workingDirectory: String
    private let pid: pid_t
    private let controlWrite: Int32
    private let stdoutRead: Int32
    private let stderrRead: Int32
    private let stateLock = NSLock()
    /// Held for a whole command. The control channel and the two sentinel
    /// streams are one conversation: a second command in flight would read the
    /// first one's output.
    private let runLock = NSLock()
    private var alive = true
    private var nonceCounter = 0

    public var isAlive: Bool { stateLock.lock(); defer { stateLock.unlock() }; return alive }

    /// A write into a shell that has just died must surface as EPIPE, not kill
    /// the process.
    private static let ignoringSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    public init(workingDirectory: String, loginShell: Bool = false) throws {
        Self.ignoringSigpipe
        self.workingDirectory = workingDirectory
        var control = [Int32](repeating: 0, count: 2)
        var out = [Int32](repeating: 0, count: 2)
        var err = [Int32](repeating: 0, count: 2)
        guard pipe(&control) == 0, pipe(&out) == 0, pipe(&err) == 0 else {
            throw ShellError.spawnFailed(errno)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        posix_spawn_file_actions_adddup2(&actions, control[0], 3)
        posix_spawn_file_actions_addclose(&actions, control[1])
        posix_spawn_file_actions_addclose(&actions, out[0])
        posix_spawn_file_actions_addclose(&actions, err[0])
        // The child chdirs itself. FileManager's currentDirectoryPath is
        // process-wide, so setting it around the spawn would race any other
        // thread spawning a shell. Still the `_np` spelling: the name without
        // it arrived in macOS 26 and this daemon runs on 13.
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSIGDEF))

        let arguments = loginShell
            ? ["bash", "-l", "-c", Self.driver]
            : ["bash", "-c", Self.driver]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for arg in argv where arg != nil { free(arg) } }

        var spawned: pid_t = 0
        let status = posix_spawn(&spawned, "/bin/bash", &actions, &attrs, argv, environ)

        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attrs)
        close(control[0])
        close(out[1])
        close(err[1])

        guard status == 0 else {
            close(control[1]); close(out[0]); close(err[0])
            throw ShellError.spawnFailed(status)
        }

        pid = spawned
        controlWrite = control[1]
        stdoutRead = out[0]
        stderrRead = err[0]
    }

    deinit { terminate() }

    public func terminate() {
        stateLock.lock()
        guard alive else { stateLock.unlock(); return }
        alive = false
        stateLock.unlock()

        close(controlWrite)
        kill(pid, SIGTERM)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        close(stdoutRead)
        close(stderrRead)
    }

    /// Runs one command and waits for its sentinels.
    public func run(_ command: String) throws -> TickResult {
        runLock.lock()
        defer { runLock.unlock() }

        stateLock.lock()
        guard alive else { stateLock.unlock(); throw ShellError.died }
        nonceCounter += 1
        let nonce = "UB\(pid)x\(nonceCounter)"
        stateLock.unlock()

        // Leading newline so bash numbers errors from the command text itself.
        let body = command.hasSuffix("\n") ? String(command.dropLast()) : command
        let payload = "\(nonce)\n\(body)\n\(nonce)\n"
        guard write(controlWrite, payload, payload.utf8.count) > 0 else {
            throw ShellError.died
        }

        let deadline = Date().addingTimeInterval(Self.timeout)
        var outBuffer = ""
        var errBuffer = ""
        var exitCode: Int32 = 0
        var sawOut = false
        var sawErr = false

        while !sawOut || !sawErr {
            if Date() > deadline { throw ShellError.timedOut(Self.timeout) }

            if !sawOut, let chunk = try Self.read(stdoutRead) {
                outBuffer += chunk
                let marker = Self.recordSeparator + nonce + " "
                if let start = outBuffer.range(of: marker),
                   let end = outBuffer.range(of: Self.recordSeparator, range: start.upperBound..<outBuffer.endIndex) {
                    exitCode = Int32(outBuffer[start.upperBound..<end.lowerBound]) ?? 0
                    outBuffer = String(outBuffer[outBuffer.startIndex..<start.lowerBound])
                    sawOut = true
                }
            }

            if !sawErr, let chunk = try Self.read(stderrRead) {
                errBuffer += chunk
                let marker = Self.recordSeparator + nonce + Self.recordSeparator
                if let start = errBuffer.range(of: marker) {
                    errBuffer = String(errBuffer[errBuffer.startIndex..<start.lowerBound])
                    sawErr = true
                }
            }
        }

        return TickResult(stdout: outBuffer, stderr: errBuffer, exitCode: exitCode)
    }

    /// Whatever is waiting on `fd`, nil when nothing arrives within 20ms. End
    /// of file means the shell is gone.
    private static func read(_ fd: Int32) throws -> String? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 20) > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n == 0 { throw ShellError.died }
        guard n > 0 else { return nil }
        return String(decoding: buffer[0..<n], as: UTF8.self)
    }
}

/// One persistent shell per widget, so identical commands from several screens
/// share a process, and a shell that dies is replaced rather than mourned.
public final class ShellPool: @unchecked Sendable {
    private let loginShell: Bool
    private var shells: [String: PersistentShell] = [:]
    private let lock = NSLock()

    public init(loginShell: Bool = false) {
        self.loginShell = loginShell
    }

    /// Runs `command` in the shell kept for widget `id`. A shell that died
    /// between ticks is replaced once; a hung command is not retried.
    public func run(_ command: String, for id: String, in workingDirectory: String) throws -> TickResult {
        do {
            return try shell(for: id, in: workingDirectory).run(command)
        } catch {
            forget(id)
            guard case PersistentShell.ShellError.died = error else { throw error }
            return try shell(for: id, in: workingDirectory).run(command)
        }
    }

    /// Runs one command in a shell of its own, for a page's ad-hoc `run()`.
    public func run(_ command: String, in workingDirectory: String) throws -> TickResult {
        let shell = try PersistentShell(workingDirectory: workingDirectory, loginShell: loginShell)
        defer { shell.terminate() }
        return try shell.run(command)
    }

    public func forget(_ id: String) {
        lock.lock()
        let shell = shells.removeValue(forKey: id)
        lock.unlock()
        shell?.terminate()
    }

    private func shell(for id: String, in workingDirectory: String) throws -> PersistentShell {
        lock.lock()
        defer { lock.unlock() }
        if let existing = shells[id], existing.isAlive, existing.workingDirectory == workingDirectory {
            return existing
        }
        let shell = try PersistentShell(workingDirectory: workingDirectory, loginShell: loginShell)
        shells[id]?.terminate()
        shells[id] = shell
        return shell
    }
}
