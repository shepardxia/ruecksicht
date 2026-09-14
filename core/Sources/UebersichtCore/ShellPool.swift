import Foundation

/// A persistent bash, fed commands on fd 3.
///
/// fd 3 rather than stdin: a widget command containing `read`, a bare `cat` or
/// `ssh host uptime` would otherwise consume the next command's text off the
/// control channel, and one widget would silently eat another's script.
///
/// Foundation's Process cannot map a descriptor above 2, so the child is spawned
/// with posix_spawn and explicit file actions.
public final class PersistentShell {
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

    private let pid: pid_t
    private let controlWrite: Int32
    private let stdoutRead: Int32
    private let stderrRead: Int32
    private let lock = NSLock()
    private var alive = true
    private var nonceCounter = 0

    public var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return alive }

    public init(workingDirectory: String, loginShell: Bool = false) throws {
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

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSIGDEF))

        let arguments = loginShell
            ? ["bash", "-l", "-c", Self.driver]
            : ["bash", "-c", Self.driver]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for arg in argv where arg != nil { free(arg) } }

        let previousDirectory = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(workingDirectory)
        var spawned: pid_t = 0
        let status = posix_spawn(&spawned, "/bin/bash", &actions, &attrs, argv, environ)
        FileManager.default.changeCurrentDirectoryPath(previousDirectory)

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
        lock.lock()
        guard alive else { lock.unlock(); return }
        alive = false
        lock.unlock()

        close(controlWrite)
        kill(pid, SIGTERM)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        close(stdoutRead)
        close(stderrRead)
    }

    /// Runs one command and waits for its sentinels. Serialized by the caller:
    /// one shell serves one command at a time.
    public func run(_ command: String, timeout: TimeInterval = 30) throws -> TickResult {
        lock.lock()
        guard alive else { lock.unlock(); throw ShellError.died }
        nonceCounter += 1
        let nonce = "UB\(pid)x\(nonceCounter)"
        lock.unlock()

        // Leading newline so bash numbers errors from the command text itself.
        let body = command.hasSuffix("\n") ? String(command.dropLast()) : command
        let payload = "\(nonce)\n\(body)\n\(nonce)\n"
        guard write(controlWrite, payload, payload.utf8.count) > 0 else {
            throw ShellError.died
        }

        let deadline = Date().addingTimeInterval(timeout)
        var outBuffer = ""
        var errBuffer = ""
        var exitCode: Int32 = 0
        var sawOut = false
        var sawErr = false

        while !sawOut || !sawErr {
            if Date() > deadline { throw ShellError.timedOut(timeout) }

            if !sawOut, let chunk = Self.read(stdoutRead, deadline: deadline) {
                outBuffer += chunk
                let marker = Self.recordSeparator + nonce + " "
                if let start = outBuffer.range(of: marker),
                   let end = outBuffer.range(of: Self.recordSeparator, range: start.upperBound..<outBuffer.endIndex) {
                    exitCode = Int32(outBuffer[start.upperBound..<end.lowerBound]) ?? 0
                    outBuffer = String(outBuffer[outBuffer.startIndex..<start.lowerBound])
                    sawOut = true
                }
            }

            if !sawErr, let chunk = Self.read(stderrRead, deadline: deadline) {
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

    private static func read(_ fd: Int32, deadline: Date) -> String? {
        var set = fd_set()
        fdZero(&set)
        fdSet(fd, &set)
        var tv = timeval(tv_sec: 0, tv_usec: 20_000)
        guard select(fd + 1, &set, nil, nil, &tv) > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.read(fd, &buffer, buffer.count)
        guard n > 0 else { return nil }
        return String(decoding: buffer[0..<n], as: UTF8.self)
    }
}

private func fdZero(_ set: inout fd_set) {
    withUnsafeMutableBytes(of: &set) { raw in
        raw.copyBytes(from: [UInt8](repeating: 0, count: raw.count))
    }
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let index = Int(fd) / 32
    let bit = Int32(1) << (Int32(fd) % 32)
    withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
        pointer.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[index] |= bit
        }
    }
}

/// One shell per distinct command, so identical commands from several screens
/// share a process and a shell that dies is replaced rather than mourned.
public final class ShellPool {
    private let workingDirectory: String
    private let loginShell: Bool
    private var shells: [String: PersistentShell] = [:]
    private let lock = NSLock()

    public init(workingDirectory: String, loginShell: Bool = false) {
        self.workingDirectory = workingDirectory
        self.loginShell = loginShell
    }

    public func run(_ command: String, timeout: TimeInterval = 30) throws -> TickResult {
        let shell = try existingOrNew(for: command)
        do {
            return try shell.run(command, timeout: timeout)
        } catch {
            drop(command)
            // One relaunch is honest recovery from a shell reaped between
            // ticks; a second would mask a command that kills its own shell.
            let replacement = try existingOrNew(for: command)
            return try replacement.run(command, timeout: timeout)
        }
    }

    private func existingOrNew(for command: String) throws -> PersistentShell {
        lock.lock()
        if let existing = shells[command], existing.isAlive {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let shell = try PersistentShell(
            workingDirectory: workingDirectory,
            loginShell: loginShell
        )
        lock.lock()
        shells[command] = shell
        lock.unlock()
        return shell
    }

    private func drop(_ command: String) {
        lock.lock()
        let shell = shells.removeValue(forKey: command)
        lock.unlock()
        shell?.terminate()
    }
}
