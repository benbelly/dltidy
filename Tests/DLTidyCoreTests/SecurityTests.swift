import DLTidyKit
import Foundation
import Testing
@testable import DLTidyCore

@Suite("Ledger names, deferred-naming poison, log escaping, oversize images")
struct SecurityTests {
    /// Processes IMG_1.HEIC into content-img-1.{heic,jpg,png} and returns the harness.
    private func renamedGroup() async throws -> Harness {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_1.HEIC", "one")
        try await h.run(40)
        #expect(h.names() == ["content-img-1.heic", "content-img-1.jpg", "content-img-1.png"])
        return h
    }

    private func outside(_ h: Harness) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: h.root.path)) ?? []).filter { !["Downloads", "state", "logs"].contains($0) }
            + ((try? FileManager.default.contentsOfDirectory(atPath: h.root.appendingPathComponent("exfil").path)) ?? [])
    }

    @Test("forged original names + queued undo (review PoC): 0 files leave the watch dir; logged and skipped")
    func forgedUndoNames() async throws {
        let h = try await renamedGroup()
        try FileManager.default.createDirectory(at: h.root.appendingPathComponent("exfil"), withIntermediateDirectories: true)
        let client = try ControlClient(config: h.config)
        // (A NUL cannot come back from the ledger: SQLite text reads stop at it. FS tests cover it.)
        for bad in ["../exfil/stolen.heic", "../stolen.heic", "/tmp/stolen.heic", "sub/stolen.heic", ".stolen.heic", "..", ".", ""] {
            try h.sql("UPDATE items SET original_name = ?, name_status = 'renamed' WHERE role = 'original'", [bad])
            _ = try client.send(.undo, arg: "content-img-1.heic", timeout: 0)
            try await h.tick()
            #expect(h.names() == ["content-img-1.heic", "content-img-1.jpg", "content-img-1.png"], "\(bad)")
            #expect(outside(h) == ["exfil"], "\(bad): \(outside(h))")
            let result = try h.db().query("SELECT result FROM commands ORDER BY id DESC LIMIT 1") { $0.text(0) }.first ?? ""
            #expect(result.contains("skipped"), "\(bad): \(result)")
        }
        #expect(h.log.recent.contains { $0.contains("unsafe original name") })
        #expect(try h.count("SELECT COUNT(*) FROM actions WHERE kind = 'undo'") == 0)
        try h.assertConsistent()
    }

    @Test("undo skips a file whose size or mtime changed since dltidy recorded it")
    func undoVerifiesIdentity() async throws {
        let h = try await renamedGroup()
        let png = h.watch.appendingPathComponent("content-img-1.png")
        let handle = try FileHandle(forWritingTo: png)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("edited".utf8))
        try handle.close()
        _ = try ControlClient(config: h.config).send(.undo, arg: "content-img-1.heic", timeout: 0)
        try await h.tick()
        #expect(h.names() == ["IMG_1.HEIC", "IMG_1.jpg", "content-img-1.png"])
        #expect(h.log.recent.contains { $0.contains("differs from the ledger record") })
    }

    @Test("forged ledger paths never reach clone, rename or recovery outside the watch dir")
    func forgedPaths() async throws {
        let h = try await Harness()
        try await h.tick()
        let exfil = h.root.appendingPathComponent("exfil", isDirectory: true)
        try FileManager.default.createDirectory(at: exfil, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: exfil.appendingPathComponent("secret.jpg"))
        // An active original whose path points outside: probe must not clone it.
        try h.sql("""
            INSERT INTO items(role, state, path, original_name, first_seen, group_id, dev, inode, size, mtime_ns)
            VALUES('original', 'probe', '../exfil/secret.jpg', '../exfil/secret.jpg', 0, 1000, 1, 1, 6, 1)
            """)
        try h.sql("UPDATE items SET group_id = id WHERE path = '../exfil/secret.jpg'")
        // An unfinished action whose target is outside: recovery must discard it.
        try h.sql("INSERT INTO actions(at, item_id, kind, key, from_name, to_name, status) VALUES(0, 1, 'rename', 'rename:1', 'a', '../exfil/x', 'intent')")
        try await h.restart()
        try await h.run(60)
        #expect(h.media.converts.get.isEmpty)
        #expect(try h.items("path = '../exfil/secret.jpg'").first?.state == .abandoned)
        #expect(try h.count("SELECT COUNT(*) FROM actions") == 0)
        #expect(FileManager.default.fileExists(atPath: exfil.appendingPathComponent("secret.jpg").path))
        #expect(h.stagingLeftovers().isEmpty)
    }

    @Test("FS.renameExclusive refuses names that are not one safe component")
    func renameNameCheck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dltidy-rn-\(UUID().uuidString)", isDirectory: true)
        let sub = dir.appendingPathComponent("w", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: sub.appendingPathComponent("a.txt"))
        for bad in ["../a.txt", "x/y", ".a", "..", ".", "", "a\u{0}"] {
            #expect(!FS.isSafeName(bad))
            #expect(throws: POSIXFailure.self) { try FS.renameExclusive("a.txt", in: sub, to: bad, in: sub) }
            #expect(throws: POSIXFailure.self) { try FS.renameExclusive(bad, in: sub, to: "b.txt", in: sub) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["w"])
        try FS.renameExclusive("a.txt", in: sub, to: "b.txt", in: sub)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sub.path) == ["b.txt"])
        try Data("y".utf8).write(to: sub.appendingPathComponent("c.txt"))
        #expect(throws: POSIXFailure.self) { try FS.renameExclusive("c.txt", in: sub, to: "b.txt", in: sub) }
    }

    @Test("deferred naming: an extractor crash on every attempt poisons the item after 3, also after resume")
    func deferredExtractorCrashPoisons() async throws {
        let h = try await Harness()
        h.online.set(false)
        try await h.tick()
        try h.drop("IMG_7.HEIC", "seven")
        try await h.run(40)
        #expect(h.names() == ["IMG_7.HEIC", "IMG_7.jpg", "IMG_7.png"])
        h.online.set(true)
        var crashes = 0
        for _ in 0..<8 {
            h.failpoints.arm("during-extract")
            do {
                for _ in 0..<10 { try await h.tick(); h.clock.advance(2) }
            } catch is SimulatedCrash {
                crashes += 1
            }
            h.failpoints.disarmAll()
            try await h.restart(after: 180)
        }
        #expect(crashes == 3)
        let leader = try #require(try h.items("role = 'original'").first)
        #expect(leader.state == .failedPoison)
        #expect(leader.nameStatus == .keep)
        #expect(try h.meta("safe_mode") == nil)
        // resume (as after safe mode) does not restart the loop
        _ = try ControlClient(config: h.config).send(.resume, timeout: 0)
        let hits = h.failpoints.hitCount("during-extract")
        h.failpoints.arm("during-extract")
        try await h.run(600, step: 30)
        #expect(h.failpoints.hitCount("during-extract") == hits)
        #expect(h.apiCalls == 0)
        #expect(h.names() == ["IMG_7.HEIC", "IMG_7.jpg", "IMG_7.png"])
    }

    @Test("an image over the pixel cap fails at once: no retry, no API call, no outputs")
    func tooLargeIsFinal() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_9.png", "HUGE")
        try await h.run(1_200, step: 10)
        let item = try #require(try h.items("role = 'original'").first)
        #expect(item.state == .failedUnreadable)
        #expect(item.decodeFailures == 0)
        #expect(item.note?.contains("too large") == true)
        #expect(h.apiCalls == 0)
        #expect(h.names() == ["IMG_9.png"])
        #expect(h.log.recent.filter { $0.contains("failed_unreadable: IMG_9.png") }.count == 1)
    }

    @Test("log lines escape control characters, so a file name cannot forge a line")
    func logEscaping() throws {
        let log = Log(url: nil)
        log.info("placed: evil\n2026-01-01T00:00:00.000Z ERROR forged\r\tx\u{1b}[31m\u{7f}\u{85}\u{2028}.jpg")
        let line = try #require(log.recent.last)
        #expect(line.filter { $0 == "\n" }.count == 1 && line.hasSuffix("\n"))
        #expect(line.contains(#"evil\n2026-01-01T00:00:00.000Z ERROR forged\r\tx\x1b[31m\x7f\x85\u{2028}.jpg"#))
        #expect(Log.escape("plain é ü 日本") == "plain é ü 日本")
    }

    @Test("a dropped file whose name holds a newline yields one log line per event")
    func newlineFileName() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("x\nINFO fake.HEIC", "nl")
        try await h.run(40)
        let text = try String(contentsOf: h.logs.appendingPathComponent("dltidy.log"), encoding: .utf8)
        #expect(!text.split(separator: "\n").contains { $0.hasPrefix("INFO fake") })
        #expect(text.contains(#"x\nINFO fake.HEIC"#))
    }
}
