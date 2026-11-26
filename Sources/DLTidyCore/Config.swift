import Foundation

/// Every tunable in one place. Defaults are the plan's constants.
public struct Config: Sendable {
    // Paths
    public var watchDir: URL
    public var stateDir: URL
    public var logDir: URL
    public var label: String

    // Readiness (rules 2, 5, 6, 7, 8)
    public var partialExtensions: Set<String> = [
        "download", "crdownload", "part", "partial", "tmp", "temp", "opdownload", "aria2", "!qb",
    ]
    public var partialSiblingSuffixes: [String] = ["part", "crdownload"]
    public var stableScans = 3
    public var stableSpan: TimeInterval = 5
    public var batchSettle: TimeInterval = 5
    public var batchMaxWait: TimeInterval = 60
    public var minAge: TimeInterval = 20
    public var decodeRetryDelays: [TimeInterval] = [30, 120, 600]

    // Scan triggers
    public var fsEventsDebounce: TimeInterval = 1
    public var pendingScanInterval: TimeInterval = 2
    public var periodicScanInterval: TimeInterval = 300
    public var healthInterval: TimeInterval = 300

    // Identity
    /// A known path whose inode vanished at most this long ago marks a new inode at that path as
    /// `replaced` (safe-save). Older vacancies hold no claim; identical bytes are still caught by hash.
    public var replaceWindow: TimeInterval = 86_400

    // Naming and cost
    public var deferredRenameWindow: TimeInterval = 86_400
    public var maxRequestsPerGroup = 3
    public var maxClassifyRequestsPerGroup = 1
    public var maxNamingRequestsPerGroup = 2
    public var transientRetryDelay: TimeInterval = 300
    public var dailyCallCap = 300
    public var monthlyCallCap = 3_000
    public var monthlyInputTokenCap = 6_000_000
    public var estimatedTokensImage = 1_600
    public var estimatedTokensText = 1_000
    public var estimatedTokensClassify = 300
    public var breakerThreshold = 3
    public var breakerBaseInterval: TimeInterval = 900
    public var breakerMaxInterval: TimeInterval = 21_600
    public var rateLimitMinCooldown: TimeInterval = 60
    public var rateLimitMaxCooldown: TimeInterval = 3_600

    // Crash safety and fuse
    public var poisonThreshold = 3
    public var crashLoopStarts = 5
    public var crashLoopWindow: TimeInterval = 600
    public var ledgerResetSafeModeWindow: TimeInterval = 7 * 86_400
    public var fuseActionsPerHour = 2_000

    // Conversion scheduling
    public var minFreeBytes: Int64 = 5 << 30
    public var outputSizeFactor: Int64 = 2
    public var toolMissingRetry: TimeInterval = 300
    public var longEncodeRetry: TimeInterval = 600
    public var diskSpaceRetry: TimeInterval = 600
    public var errorRetry: TimeInterval = 600

    // Background hashing of pre-existing files
    public var preexistingHashFilesPerTick = 20
    public var preexistingHashBytesPerTick: Int64 = 256 << 20
    public var preexistingHashMaxFileBytes: Int64 = 4 << 30

    // Ledger and log
    public var backupsKept = 7
    public var logMaxBytes = 5 << 20
    public var logFilesKept = 5

    public init(watchDir: URL, stateDir: URL, logDir: URL, label: String = "local.dltidy") {
        self.watchDir = watchDir.standardizedFileURL
        self.stateDir = stateDir.standardizedFileURL
        self.logDir = logDir.standardizedFileURL
        self.label = label
    }

    /// The installed daemon's configuration.
    public static func standard(watchDir: URL? = nil, stateDir: URL? = nil, label: String = "local.dltidy") -> Config {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Config(
            watchDir: watchDir ?? home.appendingPathComponent("Downloads", isDirectory: true),
            stateDir: stateDir ?? home.appendingPathComponent("Library/Application Support/dltidy", isDirectory: true),
            logDir: home.appendingPathComponent("Library/Logs/dltidy", isDirectory: true),
            label: label
        )
    }

    public var ledgerURL: URL { stateDir.appendingPathComponent("ledger.sqlite") }
    public var stagingDir: URL { stateDir.appendingPathComponent("staging", isDirectory: true) }
    public var backupsDir: URL { stateDir.appendingPathComponent("backups", isDirectory: true) }
    public var resetsFile: URL { stateDir.appendingPathComponent("ledger-resets") }
    public var logFile: URL { logDir.appendingPathComponent("dltidy.log") }
}
