import CoreServices
import DLTidyCore
import DLTidyKit
import DLTidyMedia
import DLTidyNaming
import Foundation
import Network
@preconcurrency import UserNotifications

/// Posts notices through the app bundle's notification permission. Outside a bundle (a bare
/// binary) it only logs.
struct UserNotifier: Notifier {
    let log: Log
    let enabled: Bool

    init(log: Log) {
        self.log = log
        enabled = Bundle.main.bundleIdentifier != nil
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if !granted { log.warn("notifications not authorized\(error.map { ": \($0)" } ?? "")") }
            }
        }
    }

    func post(title: String, body: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let log = self.log
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log.error("notification failed: \(error)") }
        }
    }
}

/// Network reachability from NWPathMonitor; naming waits while offline without spending attempts.
final class NetworkStatus: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.online = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "local.dltidy.network"))
    }

    var isOnline: Bool { lock.withLock { online } }
}

/// FSEvents on the watch directory, used only as a hint to scan sooner.
final class FSEventsWatcher: @unchecked Sendable {
    private final class Box {
        let handler: @Sendable () -> Void
        init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "local.dltidy.fsevents")

    init?(path: String, latency: TimeInterval, onEvent: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(onEvent))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().handler()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else {
            box.release()
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            box.release()
            return nil
        }
    }
}

enum Daemon {
    /// Runs forever. Configuration or health problems make it idle and retry; it never exits on
    /// its own, so launchd KeepAlive cannot spin.
    static func run(config: Config, useKeychain: Bool) -> Never {
        let log = Log(url: config.logFile, maxBytes: config.logMaxBytes, filesKept: config.logFilesKept)
        let tools = ToolRunner()
        let network = NetworkStatus()
        let notifier = UserNotifier(log: log)
        let media = MediaProcessor(tools: tools)
        let environment = EngineEnvironment(
            clock: SystemClock(),
            media: media,
            rules: NameRules(),
            extractor: ContentExtractor(tools: tools),
            naming: AnthropicNamingClient(),
            notifier: notifier,
            power: SystemPowerState(),
            apiKey: { useKeychain ? Keychain.readAPIKey() : nil },
            isOnline: { network.isOnline },
            freeSpace: { FS.freeSpace($0) },
            requiredTools: MediaProcessor.requiredTools,
            resolveTool: { tools.resolve($0) },
            magickPolicyProblem: { media.policyProblem() },
            isProcessableExtension: { MediaProcessor.isMediaExtension($0) || ContentExtractor.isNameableExtension($0) },
            failpoints: Failpoints.fromEnvironment(),
            log: log
        )
        let scheduler = Scheduler(config: config, log: log)
        let watcher = FSEventsWatcher(path: config.watchDir.path, latency: config.fsEventsDebounce) { scheduler.hint() }
        if watcher == nil { log.warn("FSEvents stream not started; relying on periodic scans") }

        Task.detached {
            var engine: Engine?
            while engine == nil {
                do {
                    engine = try await Engine(config: config, environment: environment)
                } catch {
                    log.error("engine start failed: \(error); retrying in 5 min")
                    try? await Task.sleep(for: .seconds(300))
                }
            }
            await scheduler.run(engine: engine!)
        }
        withExtendedLifetime(watcher) {
            dispatchMain()
        }
    }
}
