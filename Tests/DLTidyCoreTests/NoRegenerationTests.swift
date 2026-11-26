import DLTidyKit
import Foundation
import Testing
@testable import DLTidyCore

@Suite("No regeneration")
struct NoRegenerationTests {
    /// Processes one generic HEIC and returns the harness with its action count settled.
    private func processed() async throws -> Harness {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_9.HEIC", "heic-9")
        try await h.run(40)
        #expect(h.names() == ["content-img-9.heic", "content-img-9.jpg", "content-img-9.png"])
        return h
    }

    @Test("delete an output: 0 actions")
    func deleteOutput() async throws {
        let h = try await processed()
        let before = h.actionCount, calls = h.apiCalls
        try FileManager.default.removeItem(at: h.watch.appendingPathComponent("content-img-9.png"))
        try await h.run(120)
        #expect(h.actionCount == before)
        #expect(h.apiCalls == calls)
        #expect(!h.exists("content-img-9.png"))
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE path = 'content-img-9.png' AND missing_since IS NOT NULL") == 1)
    }

    @Test("rename an output: path updated, 0 actions")
    func renameOutput() async throws {
        let h = try await processed()
        let before = h.actionCount
        try FileManager.default.moveItem(at: h.watch.appendingPathComponent("content-img-9.jpg"),
                                         to: h.watch.appendingPathComponent("my receipt.jpg"))
        try await h.run(120)
        #expect(h.actionCount == before)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'output' AND path = 'my receipt.jpg'") == 1)
    }

    @Test("trash-and-restore an output: 0 actions")
    func trashRestore() async throws {
        let h = try await processed()
        let before = h.actionCount
        let trash = h.root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let out = h.watch.appendingPathComponent("content-img-9.png")
        try FileManager.default.moveItem(at: out, to: trash.appendingPathComponent("content-img-9.png"))
        try await h.run(60)
        try FileManager.default.moveItem(at: trash.appendingPathComponent("content-img-9.png"), to: out)
        try await h.run(120)
        #expect(h.actionCount == before)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE path = 'content-img-9.png' AND missing_since IS NULL") == 1)
    }

    @Test("delete the original and re-add the same bytes: 0 actions")
    func readdSameBytes() async throws {
        let h = try await processed()
        let before = h.actionCount, calls = h.apiCalls
        try FileManager.default.removeItem(at: h.watch.appendingPathComponent("content-img-9.heic"))
        try await h.run(30)
        try h.drop("IMG_9.HEIC", "heic-9")
        try await h.run(120)
        #expect(h.actionCount == before)
        #expect(h.apiCalls == calls)
        #expect(h.exists("IMG_9.HEIC"))
    }

    @Test("identical re-download foo (1).jpg: hash match, skipped")
    func identicalRedownload() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_5.jpg", "jpeg-5")
        try await h.run(40)
        let before = h.actionCount, calls = h.apiCalls
        try h.drop("IMG_5 (1).jpg", "jpeg-5")
        try await h.run(60)
        #expect(h.actionCount == before)
        #expect(h.apiCalls == calls)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'duplicate'") == 1)
    }

    @Test("different content, similar name: processed")
    func differentContentProcessed() async throws {
        let h = try await processed()
        try h.drop("IMG_9 (1).HEIC", "heic-9-other")
        try await h.run(60)
        #expect(h.exists("content-img-9-1.heic"))
    }

    @Test("safe-save over a known path: 0 actions")
    func safeSave() async throws {
        let h = try await processed()
        let before = h.actionCount, calls = h.apiCalls
        // Editor pattern: write a temp file, then rename it over the original.
        let tmp = h.root.appendingPathComponent("tmp-save.heic")
        try Data("edited bytes".utf8).write(to: tmp)
        _ = try FileManager.default.replaceItemAt(h.watch.appendingPathComponent("content-img-9.heic"), withItemAt: tmp)
        try await h.run(120)
        #expect(h.actionCount == before)
        #expect(h.apiCalls == calls)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'replaced'") == 1)
    }

    @Test("edit in place: same inode, 0 actions")
    func editInPlace() async throws {
        let h = try await processed()
        let before = h.actionCount
        let handle = try FileHandle(forWritingTo: h.watch.appendingPathComponent("content-img-9.png"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("more".utf8))
        try handle.close()
        try await h.run(120)
        #expect(h.actionCount == before)
    }

    @Test("pre-existing file deleted and the path reused after the replace window: new content is processed")
    func pathReuseAfterWindow() async throws {
        let h = try await Harness()
        try h.drop("IMG_7.HEIC", "old")
        try await h.tick() // baseline: pre-existing
        try FileManager.default.removeItem(at: h.watch.appendingPathComponent("IMG_7.HEIC"))
        try await h.tick()
        h.clock.advance(h.config.replaceWindow + 60)
        try h.drop("IMG_7.HEIC", "new content")
        try await h.run(40)
        #expect(h.exists("content-img-7.heic"))
    }
}
