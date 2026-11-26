import DLTidyKit
import Foundation
import Testing
@testable import DLTidyCore

@Suite("Ledger retention")
struct RetentionTests {
    private func walSize(_ h: Harness) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: h.config.ledgerURL.path + "-wal")[.size]) as? NSNumber)?.int64Value ?? -1
    }

    @Test("daily job: api_calls > 62 d, actions > 90 d, finished commands / cleared notices / starts > 7 d")
    func windows() async throws {
        let h = try await Harness()
        try await h.tick()
        h.clock.advance(86_400)   // a new day, so the job is due on the next tick
        let t = h.clock.now().timeIntervalSince1970
        let d = 86_400.0
        for age in [63.0, 61.0] {
            try h.sql("INSERT INTO api_calls(at, day, month, kind, status, est_input_tokens) VALUES(?, 'x', 'x', 'name', 'ok', 1)", [t - age * d])
        }
        try h.sql("INSERT INTO api_calls(at, day, month, kind, status, est_input_tokens) VALUES(?, 'x', 'x', 'name', 'reserved', 1)", [t - 63 * d])
        for age in [91.0, 89.0] {
            try h.sql("INSERT INTO actions(at, item_id, kind, key, from_name, to_name, status) VALUES(?, 1, 'rename', ?, 'a', 'b', 'done')",
                      [t - age * d, "k\(age)"])
        }
        for age in [8.0, 6.0] {
            try h.sql("INSERT INTO commands(at, cmd, status, result, done_at) VALUES(?, 'scan', 'done', 'ok', ?)", [t - age * d, t - age * d])
            try h.sql("INSERT INTO notices(key, active, first_at, last_at, count) VALUES(?, 0, ?, ?, 1)", ["n\(age)", t - age * d, t - age * d])
            try h.sql("INSERT INTO starts(at, pid) VALUES(?, 1)", [t - age * d])
        }
        try h.sql("INSERT INTO notices(key, active, first_at, last_at, count) VALUES('open', 1, ?, ?, 1)", [t - 30 * d, t - 30 * d])
        let startsBefore = try h.count("SELECT COUNT(*) FROM starts")
        try await h.tick()
        #expect(try h.count("SELECT COUNT(*) FROM api_calls WHERE status = 'ok'") == 1)
        #expect(try h.count("SELECT COUNT(*) FROM api_calls WHERE status = 'reserved'") == 1)
        #expect(try h.count("SELECT COUNT(*) FROM actions") == 1)
        #expect(try h.count("SELECT COUNT(*) FROM commands") == 1)
        #expect(try h.count("SELECT COUNT(*) FROM notices") == 2)
        #expect(try h.count("SELECT COUNT(*) FROM notices WHERE key = 'n8.0'") == 0)
        #expect(try h.count("SELECT COUNT(*) FROM starts") == startsBefore - 1)
        // Once per day: more rows aged past retention the same day stay until tomorrow.
        try h.sql("INSERT INTO starts(at, pid) VALUES(?, 1)", [t - 30 * d])
        try await h.tick()
        #expect(try h.count("SELECT COUNT(*) FROM starts WHERE at < ?", [t - 7 * d]) == 1)
        h.clock.advance(86_400)
        try await h.tick()
        #expect(try h.count("SELECT COUNT(*) FROM starts WHERE at < ?", [t - 7 * d]) == 0)
        #expect(h.log.recent.filter { $0.contains("ledger retention:") }.count == 3)
    }

    @Test("clamps: current-month api_calls (caps), last-hour actions (fuse) and crash-loop starts survive a 0 retention")
    func clamps() async throws {
        let h = try await Harness { c in
            c.apiCallRetention = 0
            c.actionRetention = 0
            c.startRetention = 0
            c.fuseActionsPerHour = 4
        }
        try await h.tick()
        try h.drop("IMG_1.HEIC", "one")
        try await h.run(40)
        #expect(h.apiCalls == 1)
        h.clock.advance(86_400)   // still March: the call counts toward the month cap
        let t = h.clock.now().timeIntervalSince1970
        for i in 0..<3 {
            try h.sql("INSERT INTO actions(at, item_id, kind, key, from_name, to_name, status) VALUES(?, 1, 'rename', ?, 'a', 'b', 'done')",
                      [t - 600, "recent\(i)"])
            try h.sql("INSERT INTO starts(at, pid) VALUES(?, 1)", [t - 300])
        }
        try await h.tick()
        #expect(h.apiCalls == 1)
        #expect(try ControlClient(config: h.config).status(now: h.clock.now()).contains("month 1/3000"))
        #expect(try h.count("SELECT COUNT(*) FROM actions") == 3)   // the 3 day-old renames went, the last hour stayed
        #expect(try h.count("SELECT COUNT(*) FROM starts WHERE at >= ?", [t - h.config.crashLoopWindow]) == 3)
        // The fuse still sees the hour: one more action reaches 4 and the next trips it.
        try h.drop("IMG_2.HEIC", "two")
        try await h.run(40)
        #expect(try h.meta("paused_reason")?.contains("fuse") == true)
        // Two restarts within 10 min plus the 3 recent starts: crash-loop detection still counts them.
        try await h.restart(after: 10)
        try await h.restart(after: 10)
        #expect(try h.meta("safe_mode") == "1")
    }

    @Test("items missing > 365 d are dropped unless referenced; present files are not reprocessed")
    func items() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_1.HEIC", "one")
        try h.drop("IMG_2.HEIC", "two")
        try await h.run(40)
        try h.drop("IMG_3.HEIC", "three")
        try await h.run(40)
        #expect(h.names().count == 9)
        let fm = FileManager.default
        try fm.removeItem(at: h.watch.appendingPathComponent("content-img-1.heic"))   // its copies stay
        for ext in ["heic", "jpg", "png"] { try fm.removeItem(at: h.watch.appendingPathComponent("content-img-2.\(ext)")) }
        try await h.tick()
        let rowsBefore = try h.count("SELECT COUNT(*) FROM items")
        h.clock.advance(364 * 86_400)
        try await h.tick()
        #expect(try h.count("SELECT COUNT(*) FROM items") == rowsBefore)
        #expect(try h.count("SELECT COUNT(*) FROM api_calls") == 0)
        #expect(try h.count("SELECT COUNT(*) FROM actions") == 0)
        h.clock.advance(2 * 86_400)
        try await h.tick()
        #expect(try h.count("SELECT COUNT(*) FROM items") == rowsBefore - 3)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE path LIKE 'content-img-2%'") == 0)
        let original1 = try h.items("role = 'original' AND path = 'content-img-1.heic'")
        #expect(original1.count == 1, "referenced by its present copies")
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE parent_id IS NOT NULL AND parent_id NOT IN (SELECT id FROM items)") == 0)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE group_id IS NOT NULL AND group_id NOT IN (SELECT id FROM items)") == 0)
        let names = h.names()
        let actions = h.actionCount
        try await h.run(30 * 86_400, step: 3_600)
        #expect(h.names() == names)
        #expect(h.actionCount == actions)
        #expect(h.apiCalls == 0)
        #expect(h.media.converts.get.count == 6)
        try h.assertConsistent()
    }

    @Test("the highest item id is kept, so SQLite never reuses an id")
    func maxIDKept() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("note.txt", "x")
        try await h.run(40)
        try FileManager.default.removeItem(at: h.watch.appendingPathComponent("note.txt"))
        try await h.tick()
        let maxID = try h.count("SELECT MAX(id) FROM items")
        h.clock.advance(400 * 86_400)
        try await h.tick()
        #expect(try h.count("SELECT MAX(id) FROM items") == maxID)
    }

    @Test("WAL truncated; incremental_vacuum when auto_vacuum is on (new ledgers)")
    func walAndIncrementalVacuum() async throws {
        let h = try await Harness()
        try await h.tick()
        #expect(try h.count("PRAGMA auto_vacuum") == 2)
        let t = h.clock.now().timeIntervalSince1970
        for i in 0..<3_000 {
            try h.sql("INSERT INTO api_calls(at, day, month, kind, status, reason, est_input_tokens) VALUES(?, 'x', 'x', 'name', 'ok', ?, 1)",
                      [t - 100 * 86_400, String(repeating: "r", count: 200) + "\(i)"])
        }
        h.clock.advance(86_400)
        await h.engine.pruneIfDue()
        #expect(walSize(h) == 0)
        #expect(try h.count("PRAGMA freelist_count") == 0)
        #expect(try h.count("SELECT COUNT(*) FROM api_calls") == 0)
    }

    @Test("ledger without auto_vacuum: rows pruned, no VACUUM (pages stay allocated)")
    func noVacuumWithoutAutoVacuum() async throws {
        let h = try await Harness { c in
            // An existing ledger from before auto_vacuum was set: the file has tables already.
            try? FileManager.default.createDirectory(at: c.stateDir, withIntermediateDirectories: true)
            let db = try? Database(path: c.ledgerURL.path)
            try? db?.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
        }
        try await h.tick()
        #expect(try h.count("PRAGMA auto_vacuum") == 0)
        let t = h.clock.now().timeIntervalSince1970
        for i in 0..<3_000 {
            try h.sql("INSERT INTO api_calls(at, day, month, kind, status, reason, est_input_tokens) VALUES(?, 'x', 'x', 'name', 'ok', ?, 1)",
                      [t - 100 * 86_400, String(repeating: "r", count: 200) + "\(i)"])
        }
        let pages = try h.count("PRAGMA page_count")
        h.clock.advance(86_400)
        await h.engine.pruneIfDue()
        #expect(try h.count("SELECT COUNT(*) FROM api_calls") == 0)
        #expect(try h.count("PRAGMA page_count") == pages)
        #expect(try h.count("PRAGMA freelist_count") > 0)
        #expect(walSize(h) == 0)
    }
}
