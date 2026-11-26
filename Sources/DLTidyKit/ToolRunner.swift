import Darwin
import Foundation

public struct ToolResult: Sendable {
    public var status: Int32          // exit code, or 128 + signal
    public var stdout: Data           // truncated to `outputLimit`
    public var stderr: Data           // truncated to 64 KB
    public var timedOut: Bool
    public var succeeded: Bool { status == 0 && !timedOut }
}

public enum ToolError: Error, Sendable, Equatable {
    case notFound(String)
    case spawnFailed(String, Int32)
}

public protocol ToolRunning: Sendable {
    /// Runs one external tool in its own process group at nice 10. stdout and stderr go to temp
    /// files (no pipe deadlock). On timeout (measured on the suspending clock, so system sleep
    /// does not count) the group gets SIGTERM, then SIGKILL 5 s later.
    func run(_ tool: String, _ args: [String], cwd: URL?, timeout: Duration, outputLimit: Int) async throws -> ToolResult
}

public extension ToolRunning {
    func run(_ tool: String, _ args: [String], timeout: Duration) async throws -> ToolResult {
        try await run(tool, args, cwd: nil, timeout: timeout, outputLimit: 1 << 20)
    }
}

public struct ToolRunner: ToolRunning {
    public let searchPath: [String]

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
        guard let path = resolve(tool) else { throw ToolError.notFound(tool) }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dltidy-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outURL = tmp.appendingPathComponent("stdout")
        let errURL = tmp.appendingPathComponent("stderr")

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, outURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, errURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
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
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cEnv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attrs, cArgs, cEnv)
        guard rc == 0 else { throw ToolError.spawnFailed(tool, rc) }
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

        let status: Int32 = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var raw: Int32 = 0
                while waitpid(child, &raw, 0) == -1 && errno == EINTR {}
                // Reap any process-group leftovers the tool left behind.
                kill(-child, SIGKILL)
                let code: Int32 = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
                continuation.resume(returning: code)
            }
        }
        watchdog.cancel()

        return ToolResult(
            status: status,
            stdout: Self.read(outURL, limit: outputLimit),
            stderr: Self.read(errURL, limit: 64 << 10),
            timedOut: state.timedOut
        )
    }

    private static func read(_ url: URL, limit: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: limit)) ?? Data()
    }
}

private final class KillState: @unchecked Sendable {
    private let lock = NSLock()
    private var _timedOut = false
    var timedOut: Bool { lock.withLock { _timedOut } }
    func markTimedOut() { lock.withLock { _timedOut = true } }
}
