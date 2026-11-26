import DLTidyKit
import Foundation
import Testing
@testable import DLTidyCore

@Suite("Readiness")
struct ReadinessTests {
    @Test("a file appended every second is not picked")
    func growingFile() async throws {
        let h = try await Harness()
        try await h.tick()
        let url = try h.drop("Quarterly Budget Photo.jpg", "x")
        let handle = try FileHandle(forWritingTo: url)
        for _ in 0..<90 {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("more".utf8))
            try await h.tick()
            h.clock.advance(1)
        }
        try handle.close()
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'original'") == 0)
        #expect(h.actionCount == 0)
        try await h.run(40)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'original'") == 1)
        #expect(h.names() == ["Quarterly Budget Photo.jpg", "Quarterly Budget Photo.png"])
    }

    @Test(".crdownload → rename gives 1 action")
    func crdownloadRename() async throws {
        let h = try await Harness()
        try await h.tick()
        let partial = try h.drop("Quarterly Budget Photo.jpg.crdownload", "jpeg data")
        try await h.run(90)
        #expect(h.actionCount == 0)
        try FileManager.default.moveItem(at: partial, to: h.watch.appendingPathComponent("Quarterly Budget Photo.jpg"))
        // Readiness restarts for the final name: nothing within 20 s of the rename.
        try await h.run(16)
        #expect(h.actionCount == 0)
        try await h.run(24)
        #expect(h.actionCount == 1)
        #expect(h.names() == ["Quarterly Budget Photo.jpg", "Quarterly Budget Photo.png"])
        #expect(h.naming.count == 0) // meaningful name
    }

    @Test("a 0-byte placeholder beside a .part is ignored; the finished file is processed once")
    func firefoxPlaceholder() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("Garden Plan.png", "")
        let part = try h.drop("Garden Plan.png.part", "png bytes")
        try await h.run(90)
        #expect(h.actionCount == 0)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'original'") == 0)
        // Firefox renames the .part over the placeholder.
        _ = rename(part.path, h.watch.appendingPathComponent("Garden Plan.png").path)
        try await h.run(40)
        #expect(h.actionCount == 1)
        #expect(h.names() == ["Garden Plan.jpg", "Garden Plan.png"])
        try await h.run(60)
        #expect(h.actionCount == 1)
    }

    @Test("partial extensions, dotfiles, directories and symlinks are never picked")
    func neverReady() async throws {
        let h = try await Harness()
        try await h.tick()
        for ext in ["download", "part", "partial", "tmp", "temp", "opdownload", "aria2", "!qb"] {
            try h.drop("file.\(ext)", "data")
        }
        try h.drop(".hidden.jpg", "data")
        try FileManager.default.createDirectory(at: h.watch.appendingPathComponent("bundle.download"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: h.watch.appendingPathComponent("link.jpg"),
                                                   withDestinationURL: h.root.appendingPathComponent("elsewhere.jpg"))
        try await h.run(120)
        #expect(h.actionCount == 0)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role != 'candidate'") == 0)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE path IN ('bundle.download', 'link.jpg')") == 0)
    }

    @Test("nothing happens before 20 s, and the file waits for 3 stable scans over 5 s")
    func minAgeAndStability() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("Desk Photo.jpg", "desk")
        try await h.run(18)
        #expect(h.actionCount == 0)
        try await h.run(6)
        #expect(h.actionCount == 1)

        let r = Readiness(config: h.config)
        var c = try #require(try h.items("path = 'Desk Photo.jpg'").first)
        c.stableCount = 2
        #expect(r.verdict(c, names: [], now: c.firstSeen + 100) == .unstable)
        c.stableCount = 3
        c.stableSince = c.firstSeen + 98
        #expect(r.verdict(c, names: [], now: c.firstSeen + 100) == .unstable)
        c.stableSince = c.firstSeen + 90
        #expect(r.verdict(c, names: [], now: c.firstSeen + 100) == .ready)
        c.stableSince = c.firstSeen
        #expect(r.verdict(c, names: [], now: c.firstSeen + 19) == .tooYoung)
        #expect(r.verdict(c, names: ["desk photo.jpg.crdownload"], now: c.firstSeen + 100) == .partialSibling)
    }

    @Test("batch settle: arrivals every 3 s hold the batch; 60 s max wait releases it")
    func batchSettle() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("First Photo.jpg", "first")
        var t: TimeInterval = 0
        var i = 0
        while t < 58 {
            try await h.tick()
            if Int(t) % 3 == 0 { i += 1; try h.drop("Trickle \(i).pdf", "doc \(i)") }
            h.clock.advance(1)
            t += 1
        }
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'original'") == 0)
        try await h.run(4, step: 1)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'original' AND path LIKE 'First Photo%'") == 1)
    }

    @Test("decode failure: retries at 30 s, 2 min, 10 min, then failed_unreadable with no API call")
    func decodeRetries() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_66.HEIC", "CORRUPT data")
        try await h.run(30)
        var item = try #require(try h.items("path = 'IMG_66.HEIC'").first)
        #expect(item.role == .original && item.state == .probe && item.decodeFailures == 1)
        try await h.run(30)
        item = try #require(try h.items("id = ?", [item.id]).first)
        #expect(item.decodeFailures == 2)
        try await h.run(120)
        item = try #require(try h.items("id = ?", [item.id]).first)
        #expect(item.decodeFailures == 3)
        try await h.run(600, step: 10)
        item = try #require(try h.items("id = ?", [item.id]).first)
        #expect(item.state == .failedUnreadable)
        #expect(h.apiCalls == 0)
        #expect(h.actionCount == 0)
        #expect(h.stagingLeftovers().isEmpty)
    }
}
