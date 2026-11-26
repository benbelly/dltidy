import Foundation
import DLTidyKit

/// Whether long re-encodes may run now (false on battery or at serious thermal state).
public protocol PowerState: Sendable {
    func allowLongEncode() -> Bool
}

/// A write into the watch directory, reported to observers after it happens.
public struct ActionEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case rename, place, undo }
    public var kind: Kind
    public var itemID: Int64
    public var from: String
    public var to: String
}

/// Every side effect the Engine needs, injected. The executable wires the real implementations;
/// tests wire fakes.
public struct EngineEnvironment: Sendable {
    public var clock: any Clock
    public var media: any MediaProcessing
    public var rules: any NameRuling
    public var extractor: any ContentExtracting
    public var naming: any NamingService
    public var notifier: any Notifier
    public var power: any PowerState
    /// API key from the Keychain; nil when absent.
    public var apiKey: @Sendable () -> String?
    /// Network reachability. While false, naming waits without consuming an attempt.
    public var isOnline: @Sendable () -> Bool
    /// Free bytes on the volume holding the given URL.
    public var freeSpace: @Sendable (URL) -> Int64?
    /// Tools the media module needs, checked by health.
    public var requiredTools: [String]
    public var resolveTool: @Sendable (String) -> String?
    /// nil when the ImageMagick policy is in place; otherwise why not. Checked by health.
    public var magickPolicyProblem: @Sendable () -> String?
    /// True for extensions dltidy converts or names (media or nameable document). Others are ignored
    /// without cloning or hashing.
    public var isProcessableExtension: @Sendable (String) -> Bool
    public var failpoints: Failpoints
    public var onAction: (@Sendable (ActionEvent) -> Void)?
    public var log: Log

    public init(
        clock: any Clock,
        media: any MediaProcessing,
        rules: any NameRuling,
        extractor: any ContentExtracting,
        naming: any NamingService,
        notifier: any Notifier,
        power: any PowerState,
        apiKey: @escaping @Sendable () -> String?,
        isOnline: @escaping @Sendable () -> Bool = { true },
        freeSpace: @escaping @Sendable (URL) -> Int64? = { FS.freeSpace($0) },
        requiredTools: [String] = [],
        resolveTool: @escaping @Sendable (String) -> String? = { ToolRunner().resolve($0) },
        magickPolicyProblem: @escaping @Sendable () -> String? = { nil },
        isProcessableExtension: @escaping @Sendable (String) -> Bool,
        failpoints: Failpoints = Failpoints(),
        onAction: (@Sendable (ActionEvent) -> Void)? = nil,
        log: Log
    ) {
        self.clock = clock
        self.media = media
        self.rules = rules
        self.extractor = extractor
        self.naming = naming
        self.notifier = notifier
        self.power = power
        self.apiKey = apiKey
        self.isOnline = isOnline
        self.freeSpace = freeSpace
        self.requiredTools = requiredTools
        self.resolveTool = resolveTool
        self.magickPolicyProblem = magickPolicyProblem
        self.isProcessableExtension = isProcessableExtension
        self.failpoints = failpoints
        self.onAction = onAction
        self.log = log
    }
}

/// Error raised by an armed failpoint in tests; stands in for a process crash.
public struct SimulatedCrash: Error, Equatable, Sendable {
    public let point: String
}

/// Named crash points at each state transition. In the daemon a point armed through
/// `DLTIDY_FAILPOINT=<name>` calls `abort()`; in tests it throws `SimulatedCrash`.
public final class Failpoints: @unchecked Sendable {
    public static let all = [
        "after-stage", "after-probe", "during-extract", "after-reserve", "after-request", "after-name-decided",
        "before-rename", "after-rename", "after-convert", "before-place", "after-place", "after-group",
    ]

    private let lock = NSLock()
    private var armed: [String: Int] = [:]
    private let abortProcess: Bool
    private var hits: [String: Int] = [:]

    public init(abortProcess: Bool = false) {
        self.abortProcess = abortProcess
    }

    public static func fromEnvironment() -> Failpoints {
        let fp = Failpoints(abortProcess: true)
        if let name = ProcessInfo.processInfo.environment["DLTIDY_FAILPOINT"], !name.isEmpty {
            fp.arm(name)
        }
        return fp
    }

    /// Fires on the `(skip + 1)`-th hit of `name`, once.
    public func arm(_ name: String, skip: Int = 0) {
        lock.withLock { armed[name] = skip }
    }

    public func disarmAll() { lock.withLock { armed.removeAll() } }

    public func hitCount(_ name: String) -> Int { lock.withLock { hits[name, default: 0] } }

    func hit(_ name: String) throws {
        let fire: Bool = lock.withLock {
            hits[name, default: 0] += 1
            guard let remaining = armed[name] else { return false }
            if remaining == 0 {
                armed[name] = nil
                return true
            }
            armed[name] = remaining - 1
            return false
        }
        guard fire else { return }
        if abortProcess { abort() }
        throw SimulatedCrash(point: name)
    }
}
