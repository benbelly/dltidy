import Darwin
import Foundation

public struct ToolResult: Sendable {
    public var status: Int32          // exit code, or 128 + signal
    public var stdout: Data           // at most `outputLimit` bytes
    public var stderr: Data           // first 64 KB
    public var timedOut: Bool
    /// stdout reached `outputLimit`; the runner killed the process group and `status` reflects that.
    public var outputTruncated: Bool = false
    public var succeeded: Bool { status == 0 && !timedOut }
}

public enum ToolError: Error, Sendable, Equatable {
    case notFound(String)
    case spawnFailed(String, Int32)
    /// The runner cannot pass the requested environment to the tool.
    case environmentUnsupported(String)
}

public protocol ToolRunning: Sendable {
    /// Runs one external tool in its own process group at nice 10. stdout and stderr are read from
    /// pipes into memory: stdout up to `outputLimit` bytes (the process group is killed when it
    /// writes more), stderr up to 64 KB (the rest is discarded). Nothing is written to disk. On
    /// timeout (measured on the suspending clock, so system sleep does not count) the group gets
    /// SIGTERM, then SIGKILL 5 s later.
    func run(_ tool: String, _ args: [String], cwd: URL?, timeout: Duration, outputLimit: Int) async throws -> ToolResult

    /// As above, with `environment` added to (or replacing entries of) the child's environment.
    func run(_ tool: String, _ args: [String], cwd: URL?, environment: [String: String], timeout: Duration,
             outputLimit: Int) async throws -> ToolResult
}

public extension ToolRunning {
    func run(_ tool: String, _ args: [String], timeout: Duration) async throws -> ToolResult {
        try await run(tool, args, cwd: nil, timeout: timeout, outputLimit: 1 << 20)
    }

    /// Default for runners without environment support: a non-empty environment is refused, so a
    /// setting passed this way (e.g. a security policy) is never dropped.
    func run(_ tool: String, _ args: [String], cwd: URL?, environment: [String: String], timeout: Duration,
             outputLimit: Int) async throws -> ToolResult {
        guard environment.isEmpty else { throw ToolError.environmentUnsupported(tool) }
        return try await run(tool, args, cwd: cwd, timeout: timeout, outputLimit: outputLimit)
    }
}

public struct ToolRunner: ToolRunning {
    public let searchPath: [String]
    static let stderrLimit = 64 << 10

    public init(searchPath: [String]? = nil) {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var dirs = searchPath ?? env.split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !dirs.contains(extra) {
            dirs.append(extra)
        }
        self.searchPath = dirs
    }

    /// Absolute path of `tool`, or nil.
    public func resolve(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        for dir in searchPath {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func run(_ tool: String, _ args: [String], cwd: URL?, timeout: Duration, outputLimit: Int) async throws -> ToolResult {
        try await run(tool, args, cwd: cwd, environment: [:], timeout: timeout, outputLimit: outputLimit)
    }

    public func run(_ tool: String, _ args: [String], cwd: URL?, environment: [String: String], timeout: Duration,
                    outputLimit: Int) async throws -> ToolResult {
        guard let path = resolve(tool) else { throw ToolError.notFound(tool) }

        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw ToolError.spawnFailed(tool, errno) }
        guard pipe(&errPipe) == 0 else {
            let e = errno
            close(outPipe[0]); close(outPipe[1])
            throw ToolError.spawnFailed(tool, e)
        }
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var writeEndsOpen = true
        func closeWriteEnds() {
            guard writeEndsOpen else { return }
            close(outPipe[1]); close(errPipe[1])
            writeEndsOpen = false
        }
        defer { closeWriteEnds() }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd.path) }

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attrs, 0)
        // Children must not inherit a blocked or ignored SIGTERM/SIGINT from the daemon or test host.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attrs, &emptyMask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGQUIT] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attrs, &defaults)

        let argv = [path] + args
        let cArgs = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        for (k, v) in environment { env[k] = v }
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cEnv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attrs, cArgs, cEnv)
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw ToolError.spawnFailed(tool, rc)
        }
        closeWriteEnds()
        let child = pid
        setpriority(PRIO_PROCESS, id_t(child), 10)

        let state = KillState()
        let watchdog = Task.detached { @Sendable in
            do {
                try await SuspendingClock().sleep(for: timeout)
            } catch { return }
            state.markTimedOut()
            kill(-child, SIGTERM)
            do { try await SuspendingClock().sleep(for: .seconds(5)) } catch { return }
            kill(-child, SIGKILL)
        }

        let outFD = outPipe[0], errFD = errPipe[0]
        let limit = max(0, outputLimit)
        let collected: Collected = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: Self.collect(child: child, outFD: outFD, errFD: errFD, outLimit: limit))
            }
        }
        watchdog.cancel()

        return ToolResult(status: collected.status, stdout: collected.stdout, stderr: collected.stderr,
                          timedOut: state.timedOut, outputTruncated: collected.truncated)
    }

    private struct Collected: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var truncated: Bool
    }

    /// Reads both pipes until the child exits, then drains what is buffered. stdout beyond
    /// `outLimit` kills the process group. Closes both fds.
    private static func collect(child: pid_t, outFD: Int32, errFD: Int32, outLimit: Int) -> Collected {
        for fd in [outFD, errFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var out = Data(), err = Data()
        var outOpen = true, errOpen = true
        var truncated = false
        var raw: Int32 = 0
        var exited = false
        let chunk = 64 << 10
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buf.deallocate() }

        /// Reads what is available now. Returns false at EOF or error (fd closed).
        func drain(_ fd: Int32, isOut: Bool) -> Bool {
            while true {
                let room = isOut ? (outLimit - out.count) : chunk
                // stdout at the limit: one more byte decides whether the tool wanted to write more.
                let want = isOut ? max(1, min(room, chunk)) : chunk
                let n = read(fd, buf, want)
                if n > 0 {
                    if isOut {
                        if room <= 0 {
                            truncated = true
                            kill(-child, SIGKILL)
                            close(fd)
                            return false
                        }
                        out.append(buf.assumingMemoryBound(to: UInt8.self), count: n)
                    } else if err.count < stderrLimit {
                        err.append(buf.assumingMemoryBound(to: UInt8.self), count: min(n, stderrLimit - err.count))
                    }
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN { return true }
                close(fd)
                return false
            }
        }

        while outOpen || errOpen {
            var fds: [pollfd] = []
            if outOpen { fds.append(pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)) }
            if errOpen { fds.append(pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)) }
            let ready = poll(&fds, nfds_t(fds.count), exited ? 0 : 25)
            if ready < 0 && errno != EINTR { break }
            if outOpen { outOpen = drain(outFD, isOut: true) }
            if errOpen { errOpen = drain(errFD, isOut: false) }
            if !exited {
                let r = waitpid(child, &raw, WNOHANG)
                if r == child || (r == -1 && errno == ECHILD) { exited = true }
            } else {
                // The child is gone and the pipes are drained; a leftover writer (a detached
                // grandchild) must not hold up the caller.
                break
            }
        }
        if outOpen { close(outFD) }
        if errOpen { close(errFD) }
        if !exited {
            while waitpid(child, &raw, 0) == -1 && errno == EINTR {}
        }
        // Reap any process-group leftovers the tool left behind.
        kill(-child, SIGKILL)
        let code: Int32 = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
        return Collected(status: code, stdout: out, stderr: err, truncated: truncated)
    }
}

private final class KillState: @unchecked Sendable {
    private let lock = NSLock()
    private var _timedOut = false
    var timedOut: Bool { lock.withLock { _timedOut } }
    func markTimedOut() { lock.withLock { _timedOut = true } }
}
