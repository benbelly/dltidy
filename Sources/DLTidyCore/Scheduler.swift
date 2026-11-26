import Foundation

/// Feeds the Engine's serial queue. Triggers: FSEvents hint (1 s debounce), every 2 s while work
/// is pending or a CLI command is queued, every 5 min, on wake (detected as a wall-clock jump),
/// on start. Health runs at start and every 5 min. Never exits.
public final class Scheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var hintFirst: Date?
    private var hintLast: Date?
    private let config: Config
    private let log: Log

    public init(config: Config, log: Log) {
        self.config = config
        self.log = log
    }

    /// Called from the FSEvents callback.
    public func hint() {
        let now = Date()
        lock.withLock {
            if hintFirst == nil { hintFirst = now }
            hintLast = now
        }
    }

    private func takeHint(now: Date) -> Bool {
        lock.withLock {
            guard let first = hintFirst, let last = hintLast else { return false }
            // Quiet for the debounce interval, or 5 s of continuous events.
            guard now.timeIntervalSince(last) >= config.fsEventsDebounce || now.timeIntervalSince(first) >= 5 else { return false }
            hintFirst = nil
            hintLast = nil
            return true
        }
    }

    public func run(engine: Engine) async {
        await engine.runHealth()
        await tick(engine, reason: "start")
        var lastFull = Date()
        var lastHealth = Date()
        var lastPendingCheck = Date.distantPast
        var lastLoop = Date()
        var lastHeartbeat = Date()
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            let now = Date()
            var reason: String?
            if now.timeIntervalSince(lastLoop) > 30 { reason = "wake" }
            lastLoop = now
            if reason == nil, takeHint(now: now) { reason = "fsevents" }
            if reason == nil, now.timeIntervalSince(lastPendingCheck) >= config.pendingScanInterval {
                lastPendingCheck = now
                if await engine.hasQueuedCommands() { reason = "command" }
                else if await engine.hasPendingWork() { reason = "pending" }
            }
            if reason == nil, now.timeIntervalSince(lastFull) >= config.periodicScanInterval { reason = "periodic" }
            if let reason {
                await tick(engine, reason: reason)
                lastFull = Date()
            }
            if now.timeIntervalSince(lastHealth) >= config.healthInterval || reason == "wake" {
                await engine.runHealth()
                lastHealth = Date()
            }
            if now.timeIntervalSince(lastHeartbeat) >= 60 {
                await engine.heartbeat()
                lastHeartbeat = now
            }
        }
    }

    private func tick(_ engine: Engine, reason: String) async {
        do {
            try await engine.tick()
        } catch {
            log.error("tick (\(reason)) failed: \(error)")
        }
    }
}
