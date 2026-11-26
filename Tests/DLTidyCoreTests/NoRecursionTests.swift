import DLTidyKit
import Foundation
import Testing
@testable import DLTidyCore

@Suite("No recursion")
struct NoRecursionTests {
    @Test("one HEIC + 50 scans: 2 outputs, 1 naming call, 0 further actions")
    func oneHeicFiftyScans() async throws {
        let h = try await Harness()
        try await h.tick() // baseline (empty)
        try h.drop("IMG_1234.HEIC", "heic-bytes-1")
        try await h.run(40)
        #expect(h.names() == ["content-img-1234.heic", "content-img-1234.jpg", "content-img-1234.png"])
        #expect(h.naming.count == 1)
        #expect(h.actionCount == 3) // 1 rename + 2 placements
        let after = h.actionCount
        for _ in 0..<50 {
            try await h.tick()
            h.clock.advance(2)
        }
        #expect(h.actionCount == after)
        #expect(h.naming.count == 1)
        #expect(h.media.converts.get.count == 2)
        #expect(h.content("content-img-1234.png").hasPrefix("OUT:png:heic-bytes-1"))
        for out in ["content-img-1234.png", "content-img-1234.jpg"] {
            #expect(FS.getXattr(h.watch.appendingPathComponent(out), name: FS.roleXattr) == "output")
        }
        #expect(h.stagingLeftovers().isEmpty)
        try h.assertConsistent()
    }

    @Test("a copied output with the xattr stripped is skipped by hash")
    func strippedCopySkippedByHash() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_1.HEIC", "heic-a")
        try await h.run(40)
        let before = h.actionCount
        let calls = h.naming.count
        let src = h.watch.appendingPathComponent("content-img-1.png")
        let copy = h.watch.appendingPathComponent("IMG_77.png")
        try FileManager.default.copyItem(at: src, to: copy)
        FS.removeXattr(copy, name: FS.roleXattr)
        FS.removeXattr(copy, name: FS.itemXattr)
        #expect(FS.getXattr(copy, name: FS.roleXattr) == nil)
        try await h.run(60)
        #expect(h.actionCount == before)
        #expect(h.naming.count == calls)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'duplicate' AND path = 'IMG_77.png'") == 1)
    }

    @Test("a copied output that keeps the xattr is adopted")
    func copyWithXattrAdopted() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_2.HEIC", "heic-b")
        try await h.run(40)
        let before = h.actionCount
        try FileManager.default.copyItem(at: h.watch.appendingPathComponent("content-img-2.jpg"),
                                         to: h.watch.appendingPathComponent("IMG_2 copy.jpg"))
        try await h.run(60)
        #expect(h.actionCount == before)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'adopted'") == 1)
    }

    @Test("ledger deleted with files present: 0 reprocessing")
    func ledgerDeleted() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_3.HEIC", "heic-c")
        try h.drop("DSC_0001.mov", "video dur=4")
        try await h.run(40)
        let before = h.actionCount
        let calls = h.naming.count
        #expect(before > 0)
        // Daemon stops, the whole state dir is lost (no backups either).
        h.engine = nil
        try FileManager.default.removeItem(at: h.state)
        try await h.restart()
        try await h.run(120)
        #expect(h.actionCount == before)
        #expect(h.naming.count == calls)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'original'") == 0)
        let adopted = try h.count("SELECT COUNT(*) FROM items WHERE role = 'adopted'")
        #expect(adopted == 4) // png, jpg, mp4, gif carry the xattr
    }

    @Test("ledger deleted, backups present: restored, nothing reprocessed")
    func ledgerDeletedWithBackup() async throws {
        let h = try await Harness()
        try await h.tick() // writes today's backup (empty ledger)
        try h.drop("IMG_4.HEIC", "heic-d")
        try await h.run(40)
        let before = h.actionCount, calls = h.naming.count
        h.engine = nil
        try FileManager.default.removeItem(at: h.config.ledgerURL)
        try await h.restart()
        try await h.run(120)
        #expect(h.actionCount == before)
        #expect(h.naming.count == calls)
        #expect(try h.meta("baseline_done_at") != nil)
        #expect(h.notifier.posts.get.contains { $0.title.contains("ledger") })
    }
}
