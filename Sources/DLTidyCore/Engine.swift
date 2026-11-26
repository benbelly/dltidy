import Foundation
import DLTidyKit

struct FuseTripped: Error {}

/// Owns the ledger and makes every change in the watch directory. All work runs serially:
/// the scheduler (or a test) calls `tick()`, which scans, reconciles and advances items.
public actor Engine {
    public let config: Config
    let env: EngineEnvironment
    let ledger: Ledger
    let log: Log
    let notices: Notices
    let budget: Budget
    let gate: NamingGate
    let readiness: Readiness
    var healthBlocking = false
    var ticking = false

    var nowDate: Date { env.clock.now() }
    var now: Double { nowDate.timeIntervalSince1970 }

    /// Opens (or recovers) the ledger, records the start, resolves interrupted actions and empties
    /// staging. Throws only when the state directory or a fresh ledger cannot be created.
    public init(config: Config, environment: EngineEnvironment) async throws {
        self.config = config
        env = environment
        log = environment.log
        try FS.makeDir(config.stateDir)
        try FS.makeDir(config.stagingDir)
        try FS.makeDir(config.backupsDir)
        let opened = try Engine.openLedger(config: config, log: environment.log)
        ledger = opened.ledger
        notices = Notices(ledger: opened.ledger, notifier: environment.notifier, clock: environment.clock, log: environment.log)
        budget = Budget(ledger: opened.ledger, config: config, clock: environment.clock, notices: notices,
                        log: environment.log, isOnline: environment.isOnline)
        gate = NamingGate(service: environment.naming)
        readiness = Readiness(config: config)
        try startup(ledgerReset: opened.reset)
    }

    // MARK: - Startup

    static func openLedger(config: Config, log: Log) throws -> (ledger: Ledger, reset: Bool) {
        let fm = FileManager.default
        let url = config.ledgerURL
        if fm.fileExists(atPath: url.path) {
            if let ledger = try? Ledger(url: url), ledger.db.quickCheck() { return (ledger, false) }
            let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
            log.error("ledger failed to open or quick_check; moving it aside")
            for suffix in ["", "-wal", "-shm"] {
                let p = url.path + suffix
                guard fm.fileExists(atPath: p) else { continue }
                do {
                    try fm.moveItem(atPath: p, toPath: "\(url.path).corrupt-\(stamp)\(suffix)")
                } catch {
                    try fm.removeItem(atPath: p)
                }
            }
        } else if Ledger.newestGoodBackup(in: config.backupsDir) == nil {
            return (try Ledger(url: url), false)   // first run
        }
        if let backup = Ledger.newestGoodBackup(in: config.backupsDir) {
            try fm.copyItem(at: backup, to: url)
            log.warn("ledger restored from \(backup.lastPathComponent)")
        } else {
            log.warn("no usable ledger backup; starting a fresh ledger")
        }
        return (try Ledger(url: url), true)
    }

    private func startup(ledgerReset: Bool) throws {
        let t = now
        try ledger.db.run("INSERT INTO starts(at, pid) VALUES(?, ?)", t, Int(getpid()))
        let recentStarts = try ledger.db.scalarInt("SELECT COUNT(*) FROM starts WHERE at >= ?", t - config.crashLoopWindow) ?? 0
        if recentStarts >= Int64(config.crashLoopStarts) && !ledger.flag("safe_mode") {
            try enterSafeMode(reason: "\(recentStarts) starts within \(Int(config.crashLoopWindow / 60)) min")
        }
        if ledgerReset { try handleLedgerReset() }
        try budget.recoverAfterRestart()
        try recoverActions()
        cleanStaging(keep: [])
        log.info("start: watch \(config.watchDir.path), state \(config.stateDir.path), label \(config.label)"
                 + (ledger.flag("safe_mode") ? " [SAFE MODE]" : "") + (ledger.flag("paused") ? " [paused]" : ""))
    }

    func enterSafeMode(reason: String) throws {
        try ledger.setMeta("safe_mode", "1")
        try ledger.setMeta("safe_mode_reason", reason)
        notices.raise("safe-mode", title: "dltidy is in safe mode",
                      body: "\(reason). No API calls or conversions. Check the log, then run `dltidy resume`.")
    }

    /// After a restore or a lost ledger: nothing in flight resumes, unknown files are baselined
    /// as pre-existing, and a second reset within 7 days enters safe mode.
    private func handleLedgerReset() throws {
        let t = now
        try ledger.db.transaction {
            try ledger.setMeta("rebaseline", "1")
            try ledger.db.run("""
                UPDATE items SET state = 'abandoned', note = 'ledger reset', updated_at = ?
                WHERE role = 'original' AND state IN ('probe', 'naming', 'convert')
                """, t)
            try ledger.db.run("UPDATE items SET role = 'preexisting', state = 'known', note = 'ledger reset' WHERE role = 'candidate'")
            try ledger.db.run("""
                UPDATE items SET name_status = 'keep' WHERE role = 'original' AND name_status IN ('waitClassify', 'waitName', 'renaming', 'none')
                """)
        }
        var stamps = ((try? String(contentsOf: config.resetsFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { Double($0) }
        stamps.append(t)
        try? stamps.map { String($0) }.joined(separator: "\n").write(to: config.resetsFile, atomically: true, encoding: .utf8)
        notices.raise("ledger-reset", title: "dltidy ledger was reset",
                      body: "The ledger was unreadable and was restored. Files present now are treated as pre-existing.")
        if stamps.filter({ t - $0 <= config.ledgerResetSafeModeWindow }).count >= 2 {
            try enterSafeMode(reason: "second ledger reset within 7 days")
        }
    }

    /// Resolves writes that were in flight at the last exit, by checking where the inode is.
    private func recoverActions() throws {
        let intents = try ledger.db.query("SELECT id, item_id, kind, to_name FROM actions WHERE status = 'intent'") {
            (id: $0.int(0), itemID: $0.int(1), kind: $0.text(2), to: $0.text(3))
        }
        for a in intents {
            guard let item = try ledger.item(a.itemID) else {
                try ledger.db.run("DELETE FROM actions WHERE id = ?", a.id)
                continue
            }
            var landed = false
            if let target = watchURL(a.to, for: "recover \(a.kind)") {
                landed = (try? FS.lstatEntry(target)).flatMap { $0 }.map { $0.inode == item.inode && $0.dev == item.dev } ?? false
            }
            try ledger.db.transaction {
                if landed {
                    try ledger.db.run("UPDATE actions SET status = 'done' WHERE id = ?", a.id)
                    try ledger.db.run("UPDATE items SET path = ?, assigned_name = ?, missing_since = NULL WHERE id = ?", a.to, a.to, item.id)
                    if a.kind == "place" { try ledger.setState(item.id, .placed, now: now) }
                    log.info("recovered completed \(a.kind) -> \(a.to)")
                } else {
                    try ledger.db.run("DELETE FROM actions WHERE id = ?", a.id)
                    if a.kind == "place" { try ledger.db.run("DELETE FROM items WHERE id = ? AND state = 'placing'", item.id) }
                    log.info("discarded unfinished \(a.kind) -> \(a.to)")
                }
            }
        }
        // Placing rows without an intent cannot exist (same transaction), but never leave one dangling.
        try ledger.db.run("DELETE FROM items WHERE role = 'output' AND state = 'placing'")
    }

    func stagingDir(_ id: Int64) -> URL { config.stagingDir.appendingPathComponent(String(id), isDirectory: true) }

    func cleanStaging(keep: Set<Int64>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: config.stagingDir.path)) ?? []
        for name in names where !keep.contains(Int64(name) ?? -1) {
            FS.removeTree(config.stagingDir.appendingPathComponent(name))
        }
    }

    // MARK: - Flags

    var paused: Bool { ledger.flag("paused") }
    var safeMode: Bool { ledger.flag("safe_mode") }
    var canProcess: Bool { !paused && !safeMode && !healthBlocking }

    public func isPaused() -> Bool { paused }
    public func isSafeMode() -> Bool { safeMode }

    /// Candidates waiting for readiness or originals with work due: scan every 2 s.
    public func hasPendingWork() -> Bool {
        let t = now
        let n = (try? ledger.db.scalarInt("""
            SELECT COUNT(*) FROM items WHERE missing_since IS NULL AND (
              role = 'candidate' OR
              (role = 'original' AND state IN ('probe', 'naming', 'convert') AND COALESCE(next_attempt_at, 0) <= ?))
            """, t)) ?? nil
        return (n ?? 0) > 0
    }

    public func hasQueuedCommands() -> Bool {
        ((try? ledger.db.scalarInt("SELECT COUNT(*) FROM commands WHERE status = 'queued'")) ?? nil).map { $0 > 0 } ?? false
    }

    public func heartbeat() {
        try? ledger.setMeta("heartbeat_at", String(Date().timeIntervalSince1970))
    }

    // MARK: - Tick

    /// One serial pass: commands, backup, scan, reconcile, readiness, processing.
    /// Throws only `SimulatedCrash` (tests) and ledger errors.
    public func tick() async throws {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }

        try processCommands()
        ledger.backupIfDue(dir: config.backupsDir, day: Period.day(nowDate), keep: config.backupsKept, log: log)
        pruneIfDue()

        let entries: [DirEntry]
        do {
            entries = try FS.scanTopLevel(config.watchDir)
        } catch {
            log.error("scan aborted: \(error)")
            notices.raise("health-downloads", title: "dltidy cannot read Downloads",
                          body: "Grant access in System Settings > Privacy & Security > Files and Folders > DLTidy > Downloads Folder.")
            return
        }
        notices.clear("health-downloads")
        heartbeat()

        if ledger.meta("baseline_done_at") == nil || ledger.flag("rebaseline") {
            try baseline(entries)
            return
        }
        try reconcile(entries)
        hashPreexisting()
        guard canProcess else { return }
        do {
            try await promoteReady(entries)
            try await advanceGroups()
            try await advanceDeferred()
        } catch is FuseTripped {
            return
        }
    }

    // MARK: - Retention

    /// Once per day, after the backup: deletes ledger rows past their retention (see `Config`).
    /// Each cutoff is clamped so no row a live check still reads is deleted: api_calls of the current
    /// month (day/month caps), actions of the last hour (fuse), starts within the crash-loop window.
    func pruneIfDue() {
        let day = Period.day(nowDate)
        guard ledger.meta("last_prune_day") != day else { return }
        let t = now
        let monthStart = Calendar.current.dateInterval(of: .month, for: nowDate)?.start.timeIntervalSince1970 ?? t
        do {
            let n = try ledger.prune(
                day: day,
                apiCallsBefore: min(t - config.apiCallRetention, monthStart),
                actionsBefore: min(t - config.actionRetention, t - 3_600),
                commandsBefore: t - config.finishedCommandRetention,
                noticesBefore: t - config.clearedNoticeRetention,
                startsBefore: min(t - config.startRetention, t - config.crashLoopWindow),
                missingItemsBefore: t - config.missingItemRetention)
            log.info("ledger retention: removed \(n.apiCalls) api_calls, \(n.actions) actions, \(n.commands) commands, "
                     + "\(n.notices) notices, \(n.starts) starts, \(n.items) items")
        } catch {
            log.error("ledger retention failed: \(error)")
        }
    }

    // MARK: - Baseline

    /// First successful scan (or after a ledger reset): every entry is recorded as pre-existing
    /// (or adopted, when it carries the dltidy xattr) in one transaction, before any processing.
    func baseline(_ entries: [DirEntry]) throws {
        let t = now
        var pre = 0, adopted = 0, known = 0
        try ledger.db.transaction {
            let present = try ledger.presentByInode()
            var seen = Set<InodeKey>()
            for e in entries where e.kind == .regular {
                let key = InodeKey(dev: e.dev, inode: e.inode)
                if let it = present[key] {
                    seen.insert(key)
                    if it.path != e.name { try ledger.db.run("UPDATE items SET path = ? WHERE id = ?", e.name, it.id) }
                    known += 1
                    continue
                }
                if let it = try ledger.latestByInode(dev: e.dev, inode: e.inode) {
                    try ledger.db.run("UPDATE items SET path = ?, missing_since = NULL WHERE id = ?", e.name, it.id)
                    known += 1
                    continue
                }
                if FS.getXattr(config.watchDir.appendingPathComponent(e.name), name: FS.roleXattr) != nil {
                    try ledger.insertItem(role: .adopted, state: .known, entry: e, now: t, note: "baseline")
                    adopted += 1
                } else {
                    try ledger.insertItem(role: .preexisting, state: .known, entry: e, now: t)
                    pre += 1
                }
            }
            for (key, it) in present where !seen.contains(key) {
                try ledger.db.run("UPDATE items SET missing_since = ? WHERE id = ?", t, it.id)
            }
            try ledger.setMeta("baseline_done_at", String(t))
            try ledger.setMeta("rebaseline", nil)
        }
        log.info("baseline: \(pre) pre-existing, \(adopted) adopted (xattr), \(known) already known")
    }

    // MARK: - Reconcile

    /// Diffs the scan against the ledger. Decision order for an entry: known inode → update path;
    /// dltidy xattr → adopt; path of a recently vanished known item → replaced; else candidate.
    func reconcile(_ entries: [DirEntry]) throws {
        let t = now
        try ledger.db.transaction {
            let present = try ledger.presentByInode()
            var seen = Set<InodeKey>()
            var unmatched: [DirEntry] = []
            for e in entries where e.kind == .regular {
                let key = InodeKey(dev: e.dev, inode: e.inode)
                if let it = present[key] {
                    seen.insert(key)
                    try update(it, with: e, at: t)
                } else {
                    unmatched.append(e)
                }
            }
            for (key, it) in present where !seen.contains(key) {
                try ledger.db.run("UPDATE items SET missing_since = ? WHERE id = ?", t, it.id)
                if it.role != .candidate { log.info("missing: \(it.path) [\(it.role.rawValue) #\(it.id)]") }
            }
            for e in unmatched {
                if let it = try ledger.latestByInode(dev: e.dev, inode: e.inode) {
                    if it.role == .candidate {
                        try ledger.db.run("""
                            UPDATE items SET path = ?, missing_since = NULL, size = ?, mtime_ns = ?, stable_count = 1,
                              stable_since = ?, path_since = ? WHERE id = ?
                            """, e.name, e.size, e.mtimeNs, t, t, it.id)
                    } else {
                        try ledger.db.run("UPDATE items SET path = ?, missing_since = NULL WHERE id = ?", e.name, it.id)
                        log.info("reappeared: \(e.name) [\(it.role.rawValue) #\(it.id)]")
                    }
                    continue
                }
                if let role = FS.getXattr(config.watchDir.appendingPathComponent(e.name), name: FS.roleXattr) {
                    let id = try ledger.insertItem(role: .adopted, state: .known, entry: e, now: t, note: "xattr \(role)")
                    log.info("adopted (dltidy xattr): \(e.name) #\(id)")
                    continue
                }
                if let holder = try replacedHolder(name: e.name, at: t) {
                    let id = try ledger.insertItem(role: .replaced, state: .known, entry: e, now: t, note: "replaces #\(holder)")
                    log.info("replaced in place: \(e.name) #\(id) (was #\(holder)); no action")
                    continue
                }
                let id = try ledger.insertItem(role: .candidate, state: .pending, entry: e, now: t)
                log.debug("candidate: \(e.name) #\(id)")
            }
        }
    }

    private func update(_ it: Item, with e: DirEntry, at t: Double) throws {
        if it.role == .candidate {
            if it.path != e.name {
                // Renamed while waiting (e.g. .crdownload → final name): readiness restarts for the new name.
                try ledger.db.run("UPDATE items SET path = ?, size = ?, mtime_ns = ?, stable_count = 1, stable_since = ?, path_since = ? WHERE id = ?",
                                  e.name, e.size, e.mtimeNs, t, t, it.id)
            } else if e.size == it.size && e.mtimeNs == it.mtimeNs {
                try ledger.db.run("UPDATE items SET stable_count = stable_count + 1 WHERE id = ?", it.id)
            } else {
                try ledger.db.run("UPDATE items SET path = ?, size = ?, mtime_ns = ?, stable_count = 1, stable_since = ? WHERE id = ?",
                                  e.name, e.size, e.mtimeNs, t, it.id)
            }
            return
        }
        if it.path != e.name {
            try ledger.db.run("UPDATE items SET path = ? WHERE id = ?", e.name, it.id)
            log.info("renamed outside dltidy: \(it.path) -> \(e.name) [\(it.role.rawValue) #\(it.id)]")
        }
    }

    private func replacedHolder(name: String, at t: Double) throws -> Int64? {
        try ledger.db.scalarInt("""
            SELECT id FROM items WHERE path = ? COLLATE NOCASE AND role != 'candidate' AND inode IS NOT NULL
              AND missing_since IS NOT NULL AND missing_since >= ? ORDER BY id DESC LIMIT 1
            """, name, t - config.replaceWindow)
    }

    // MARK: - Background hashing of pre-existing files

    /// Hashes a few pre-existing files per tick so later copies of them are recognised.
    func hashPreexisting() {
        guard let rows = try? ledger.items(where: """
            role IN ('preexisting', 'adopted', 'replaced') AND sha256 IS NULL AND missing_since IS NULL
            ORDER BY id LIMIT ?
            """, [config.preexistingHashFilesPerTick]) else { return }
        var bytes: Int64 = 0
        for it in rows {
            if bytes > config.preexistingHashBytesPerTick { break }
            var sha = "-"
            if let size = it.size, size <= config.preexistingHashMaxFileBytes {
                bytes += size
                if FS.isSafeName(it.path) {
                    sha = (try? FS.sha256(config.watchDir.appendingPathComponent(it.path), expectInode: it.inode)) ?? "-"
                }
            }
            _ = try? ledger.db.run("UPDATE items SET sha256 = ? WHERE id = ?", sha, it.id)
        }
    }

    // MARK: - Actions (every write into the watch directory)

    func emit(_ event: ActionEvent) {
        env.onAction?(event)
    }

    /// Fuse: trips on a repeated action key or on too many actions in an hour. Tripping pauses
    /// processing and posts one notice.
    func checkFuse(_ key: String) throws {
        var reason: String?
        if try ledger.actionExists(key: key) {
            reason = "repeat of action \(key)"
        } else if try ledger.actionCount(since: now - 3_600) >= config.fuseActionsPerHour {
            reason = "more than \(config.fuseActionsPerHour) actions in an hour"
        }
        guard let reason else { return }
        try ledger.setMeta("paused", "1")
        try ledger.setMeta("paused_reason", "fuse: \(reason)")
        log.error("FUSE tripped: \(reason); processing paused")
        notices.raise("fuse", title: "dltidy paused itself",
                      body: "Safety fuse: \(reason). Check `dltidy log`, then run `dltidy resume`.")
        throw FuseTripped()
    }

    /// URL of a ledger name inside the watch dir, or nil (logged) when the name is not one safe path
    /// component. The ledger is writable by any process of the user, so its names are untrusted.
    func watchURL(_ name: String, for purpose: String) -> URL? {
        guard FS.isSafeName(name) else {
            log.warn("unsafe name in ledger, skipped (\(purpose)): \(name)")
            return nil
        }
        return config.watchDir.appendingPathComponent(name)
    }

    /// Renames a file inside the watch dir with RENAME_EXCL, relative to an fd of the watch dir.
    /// Returns false when a name is unsafe, the target exists or the source vanished (nothing written).
    func performRename(_ item: Item, to target: String, kind: ActionEvent.Kind, key: String) throws -> Bool {
        let from = item.path
        guard watchURL(from, for: "\(kind.rawValue) from") != nil, watchURL(target, for: "\(kind.rawValue) to") != nil else {
            return false
        }
        try checkFuse(key)
        let t = now
        let actionID = try ledger.db.transaction {
            try ledger.insertAction(at: t, itemID: item.id, kind: kind.rawValue, key: key, from: from, to: target)
        }
        try env.failpoints.hit("before-rename")
        do {
            try FS.renameExclusive(from, in: config.watchDir, to: target, in: config.watchDir)
        } catch let f as POSIXFailure {
            try ledger.db.run("DELETE FROM actions WHERE id = ?", actionID)
            log.warn("rename \(from) -> \(target) not done: \(f)")
            return false
        }
        try env.failpoints.hit("after-rename")
        try ledger.db.transaction {
            try ledger.db.run("UPDATE items SET path = ?, assigned_name = ?, updated_at = ? WHERE id = ?", target, target, t, item.id)
            try ledger.db.run("UPDATE actions SET status = 'done' WHERE id = ?", actionID)
        }
        log.info("\(kind.rawValue): \(from) -> \(target)")
        emit(ActionEvent(kind: kind, itemID: item.id, from: from, to: target))
        return true
    }
}
