import Foundation
import DLTidyKit

public enum Role: String, Sendable, CaseIterable {
    case candidate      // new inode, waiting for readiness
    case original       // accepted for processing
    case output         // a file dltidy generated
    case preexisting    // present at baseline
    case duplicate      // bytes already in the ledger
    case replaced       // new inode at a known path (safe-save)
    case adopted        // unknown inode carrying the dltidy xattr
    case ignored        // extension dltidy never names or converts
    case skipped        // backlog dropped by `resume --skip-backlog`
}

public enum ItemState: String, Sendable {
    case pending                        // candidate
    case probe, naming, convert         // original, active
    case done
    case skippedChanged = "skipped_changed"
    case failedUnreadable = "failed_unreadable"
    case failedPoison = "failed_poison"
    case abandoned                      // original vanished mid-work, or ledger reset
    case placing, placed                // output
    case skippedExists = "skipped_exists"
    case failed
    case known                          // terminal for non-original roles

    var isActiveOriginal: Bool { self == .probe || self == .naming || self == .convert }
}

public enum NameStatus: String, Sendable {
    case none           // not decided
    case keep           // final: keep the name
    case waitClassify   // name unclear; classification call pending (deferred)
    case waitName       // naming call pending (deferred or retry)
    case renaming       // target stem chosen; renames in progress
    case renamed
    case expired        // 24 h window passed
    case undone
}

/// One ledger row.
public struct Item: Sendable, Equatable {
    public var id: Int64
    public var role: Role
    public var state: ItemState
    public var dev: Int64?
    public var inode: Int64?
    public var size: Int64?
    public var mtimeNs: Int64?
    public var path: String
    public var originalName: String
    public var assignedName: String?
    public var parentID: Int64?
    public var format: String?
    public var groupID: Int64?
    public var sha256: String?
    public var firstSeen: Double
    public var missingSince: Double?
    public var stableCount: Int
    public var stableSince: Double?
    public var workStarts: Int
    public var decodeFailures: Int
    public var nextAttemptAt: Double?
    public var nameStatus: NameStatus
    public var nextNameAt: Double?
    public var slug: String?
    public var mediaKind: MediaKind?
    public var duration: Double?
    public var isHDR: Bool
    public var width: Int?
    public var height: Int?
    public var isLiveVideo: Bool
    public var note: String?
    /// Candidates: when the current name appeared (a rename restarts readiness rule 7).
    public var pathSince: Double?

    static let columns = """
        id, role, state, dev, inode, size, mtime_ns, path, original_name, assigned_name, parent_id, format, \
        group_id, sha256, first_seen, missing_since, stable_count, stable_since, work_starts, decode_failures, \
        next_attempt_at, name_status, next_name_at, slug, media_kind, duration, is_hdr, width, height, \
        is_live_video, note, path_since
        """

    init(_ s: Statement) {
        id = s.int(0)
        role = Role(rawValue: s.text(1)) ?? .ignored
        state = ItemState(rawValue: s.text(2)) ?? .known
        dev = s.optInt(3)
        inode = s.optInt(4)
        size = s.optInt(5)
        mtimeNs = s.optInt(6)
        path = s.text(7)
        originalName = s.text(8)
        assignedName = s.optText(9)
        parentID = s.optInt(10)
        format = s.optText(11)
        groupID = s.optInt(12)
        sha256 = s.optText(13)
        firstSeen = s.double(14)
        missingSince = s.optDouble(15)
        stableCount = Int(s.int(16))
        stableSince = s.optDouble(17)
        workStarts = Int(s.int(18))
        decodeFailures = Int(s.int(19))
        nextAttemptAt = s.optDouble(20)
        nameStatus = NameStatus(rawValue: s.text(21)) ?? .keep
        nextNameAt = s.optDouble(22)
        slug = s.optText(23)
        mediaKind = s.optText(24).flatMap(MediaKind.init(rawValue:))
        duration = s.optDouble(25)
        isHDR = s.int(26) != 0
        width = s.optInt(27).map(Int.init)
        height = s.optInt(28).map(Int.init)
        isLiveVideo = s.int(29) != 0
        note = s.optText(30)
        pathSince = s.optDouble(31)
    }

    public var ext: String { path.fileExtension }
    public var originalExt: String { originalName.fileExtension }

    var mediaInfo: MediaInfo? {
        guard let mediaKind else { return nil }
        return MediaInfo(kind: mediaKind, durationSeconds: duration, isHDR: isHDR, width: width, height: height)
    }
}

struct InodeKey: Hashable { var dev: Int64; var inode: Int64 }

/// Typed access to the SQLite ledger.
final class Ledger {
    let db: Database
    let url: URL

    init(url: URL) throws {
        self.url = url
        db = try Database(path: url.path)
        // A new ledger reclaims pruned pages with `PRAGMA incremental_vacuum` (set before any table).
        if try db.scalarInt("SELECT COUNT(*) FROM sqlite_master") == 0 {
            try db.execute("PRAGMA auto_vacuum=INCREMENTAL")
        }
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=FULL")
        try db.execute("PRAGMA foreign_keys=OFF")
        try Schema.migrate(db)
    }

    /// Opens an existing ledger without migrating (CLI). Throws if the file is absent.
    init(existing url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SQLiteError(code: 14, message: "no ledger at \(url.path); the daemon has not run yet")
        }
        self.url = url
        db = try Database(path: url.path)
        try db.execute("PRAGMA synchronous=FULL")
    }

    // MARK: meta

    func meta(_ key: String) -> String? {
        (try? db.scalarText("SELECT value FROM meta WHERE key = ?", key)) ?? nil
    }

    func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", key, value)
        } else {
            try db.run("DELETE FROM meta WHERE key = ?", key)
        }
    }

    func flag(_ key: String) -> Bool { meta(key) == "1" }

    // MARK: items

    func item(_ id: Int64) throws -> Item? {
        try db.query("SELECT \(Item.columns) FROM items WHERE id = ?", [id], Item.init).first
    }

    func items(where clause: String, _ args: [any SQLBindable] = []) throws -> [Item] {
        try db.query("SELECT \(Item.columns) FROM items WHERE \(clause)", args, Item.init)
    }

    func group(_ groupID: Int64) throws -> [Item] {
        try items(where: "group_id = ? AND role = 'original' ORDER BY id", [groupID])
    }

    func outputs(parent: Int64) throws -> [Item] {
        try items(where: "parent_id = ? AND role = 'output' ORDER BY id", [parent])
    }

    /// Items currently present in the watch dir (inode known, not missing), by inode.
    func presentByInode() throws -> [InodeKey: Item] {
        var map: [InodeKey: Item] = [:]
        for it in try items(where: "missing_since IS NULL AND inode IS NOT NULL ORDER BY id") {
            if let dev = it.dev, let ino = it.inode { map[InodeKey(dev: dev, inode: ino)] = it }
        }
        return map
    }

    func latestByInode(dev: Int64, inode: Int64) throws -> Item? {
        try items(where: "dev = ? AND inode = ? ORDER BY id DESC LIMIT 1", [dev, inode]).first
    }

    @discardableResult
    func insertItem(role: Role, state: ItemState, entry: DirEntry, now: Double, sha: String? = nil, note: String? = nil) throws -> Int64 {
        try db.run("""
            INSERT INTO items(role, state, dev, inode, size, mtime_ns, path, original_name, first_seen,
                              stable_count, stable_since, sha256, note, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
            """, role.rawValue, state.rawValue, entry.dev, entry.inode, entry.size, entry.mtimeNs,
                   entry.name, entry.name, now, now, sha, note, now)
        return db.lastInsertID
    }

    func setState(_ id: Int64, _ state: ItemState, note: String? = nil, now: Double) throws {
        if let note {
            try db.run("UPDATE items SET state = ?, note = ?, updated_at = ? WHERE id = ?", state.rawValue, note, now, id)
        } else {
            try db.run("UPDATE items SET state = ?, updated_at = ? WHERE id = ?", state.rawValue, now, id)
        }
    }

    func setGroupNameStatus(_ groupID: Int64, _ status: NameStatus, now: Double) throws {
        try db.run("UPDATE items SET name_status = ?, updated_at = ? WHERE group_id = ? AND role = 'original'",
                   status.rawValue, now, groupID)
    }

    func hashKnown(_ sha: String, excluding id: Int64) throws -> Item? {
        try items(where: "sha256 = ? AND id != ? ORDER BY id LIMIT 1", [sha, id]).first
    }

    func hashCount(_ sha: String) throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM items WHERE sha256 = ?", sha) ?? 0)
    }

    // MARK: actions

    func actionExists(key: String) throws -> Bool {
        (try db.scalarInt("SELECT COUNT(*) FROM actions WHERE key = ? AND status = 'done'", key) ?? 0) > 0
    }

    func actionCount(since: Double) throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM actions WHERE at >= ? AND status = 'done'", since) ?? 0)
    }

    func insertAction(at: Double, itemID: Int64, kind: String, key: String, from: String, to: String) throws -> Int64 {
        try db.run("INSERT INTO actions(at, item_id, kind, key, from_name, to_name, status) VALUES(?, ?, ?, ?, ?, ?, 'intent')",
                   at, itemID, kind, key, from, to)
        return db.lastInsertID
    }

    // MARK: backups

    /// `VACUUM INTO` a dated copy once per day; keeps the newest `keep`.
    func backupIfDue(dir: URL, day: String, keep: Int, log: Log) {
        guard meta("last_backup_day") != day else { return }
        do {
            try FS.makeDir(dir)
            let dest = dir.appendingPathComponent("ledger-\(day).sqlite")
            try? FileManager.default.removeItem(at: dest)
            try db.execute("VACUUM INTO '\(dest.path.replacingOccurrences(of: "'", with: "''"))'")
            try setMeta("last_backup_day", day)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let backups = files.filter { $0.hasPrefix("ledger-") && $0.hasSuffix(".sqlite") }.sorted()
            for old in backups.dropLast(keep) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
            }
            log.info("ledger backup written: \(dest.lastPathComponent)")
        } catch {
            log.error("ledger backup failed: \(error)")
        }
    }

    // MARK: retention

    struct PruneCounts: Equatable {
        var apiCalls = 0, actions = 0, commands = 0, notices = 0, starts = 0, items = 0
        var total: Int { apiCalls + actions + commands + notices + starts + items }
    }

    /// Deletes rows past their retention and records `day` as done, in one transaction; then, when
    /// auto_vacuum is on, returns free pages, and last truncates the WAL. Never runs a full VACUUM.
    /// Cutoffs are epoch seconds.
    func prune(day: String, apiCallsBefore: Double, actionsBefore: Double, commandsBefore: Double, noticesBefore: Double,
               startsBefore: Double, missingItemsBefore: Double) throws -> PruneCounts {
        var n = PruneCounts()
        try db.transaction {
            // Only finished calls: a 'reserved' row is a request in flight (recoverAfterRestart settles it).
            n.apiCalls = try db.run("DELETE FROM api_calls WHERE at < ? AND status != 'reserved'", apiCallsBefore)
            // Only done actions: an 'intent' row is resolved by recoverActions at the next start.
            n.actions = try db.run("DELETE FROM actions WHERE at < ? AND status = 'done'", actionsBefore)
            n.commands = try db.run("DELETE FROM commands WHERE status = 'done' AND COALESCE(done_at, at) < ?", commandsBefore)
            n.notices = try db.run("DELETE FROM notices WHERE active = 0 AND COALESCE(last_at, first_at, 0) < ?", noticesBefore)
            n.starts = try db.run("DELETE FROM starts WHERE at < ?", startsBefore)
            // Items: drop long-missing rows that no kept row refers to (outputs → parent_id, originals →
            // group_id, remaining actions and api_calls → item/group). The highest id is always kept so
            // SQLite never reuses an item id (ids appear in action keys and output xattrs).
            n.items = try db.run("""
                WITH RECURSIVE
                  edges(src, dst) AS (
                    SELECT id, parent_id FROM items WHERE parent_id IS NOT NULL
                    UNION ALL SELECT id, group_id FROM items WHERE group_id IS NOT NULL),
                  keep(id) AS (
                    SELECT id FROM items WHERE missing_since IS NULL OR missing_since >= ?1
                    UNION SELECT MAX(id) FROM items
                    UNION SELECT item_id FROM actions WHERE item_id IS NOT NULL
                    UNION SELECT item_id FROM api_calls WHERE item_id IS NOT NULL
                    UNION SELECT group_id FROM api_calls WHERE group_id IS NOT NULL
                    UNION SELECT e.dst FROM edges e JOIN keep k ON e.src = k.id)
                DELETE FROM items WHERE missing_since < ?1 AND id NOT IN (SELECT id FROM keep WHERE id IS NOT NULL)
                """, missingItemsBefore)
            try setMeta("last_prune_day", day)
        }
        if (try db.scalarInt("PRAGMA auto_vacuum") ?? 0) != 0 {
            try db.execute("PRAGMA incremental_vacuum")
        }
        _ = try db.query("PRAGMA wal_checkpoint(TRUNCATE)") { _ in () }
        return n
    }

    static func newestGoodBackup(in dir: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in files.filter({ $0.hasPrefix("ledger-") && $0.hasSuffix(".sqlite") }).sorted().reversed() {
            let url = dir.appendingPathComponent(name)
            if let db = try? Database(path: url.path, readOnly: true), db.quickCheck() { return url }
        }
        return nil
    }
}

/// Calendar keys for cap accounting, in the user's time zone.
enum Period {
    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func month(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
