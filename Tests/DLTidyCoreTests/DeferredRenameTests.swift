import DLTidyKit
import Foundation
import Testing
@testable import DLTidyCore

@Suite("Deferred rename")
struct DeferredRenameTests {
    @Test("API down at arrival, up at 2 h: original and copies renamed as a group; a user-renamed copy keeps its name")
    func upAfterTwoHours() async throws {
        let h = try await Harness()
        h.online.set(false)
        try await h.tick()
        try h.drop("IMG_20.HEIC", "twenty")
        try await h.run(40)
        #expect(h.names() == ["IMG_20.HEIC", "IMG_20.jpg", "IMG_20.png"])
        #expect(h.apiCalls == 0)
        try FileManager.default.moveItem(at: h.watch.appendingPathComponent("IMG_20.jpg"), to: h.watch.appendingPathComponent("mine.jpg"))
        try await h.run(3_600, step: 300)
        #expect(h.apiCalls == 0)
        h.clock.advance(3_600)
        h.online.set(true)
        try await h.tick()
        #expect(h.apiCalls == 1)
        #expect(h.names() == ["content-img-20.heic", "content-img-20.png", "mine.jpg"])
        try await h.run(600, step: 60)
        #expect(h.apiCalls == 1)
        try h.assertConsistent()
    }

    @Test("API up at 25 h: no rename, no call")
    func upAfterWindow() async throws {
        let h = try await Harness()
        h.online.set(false)
        try await h.tick()
        try h.drop("IMG_21.HEIC", "twenty-one")
        try await h.run(40)
        h.clock.advance(25 * 3_600)
        h.online.set(true)
        try await h.run(600, step: 60)
        #expect(h.apiCalls == 0)
        #expect(h.names() == ["IMG_21.HEIC", "IMG_21.jpg", "IMG_21.png"])
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'original' AND name_status = 'expired'") == 1)
    }

    @Test("original renamed by the user during the outage: no call, nothing renamed")
    func userRenamedOriginal() async throws {
        let h = try await Harness()
        h.key.set(nil)
        try await h.tick()
        try h.drop("IMG_22.HEIC", "twenty-two")
        try await h.run(40)
        #expect(h.notifier.posts.get.filter { $0.title.contains("API key") }.count == 1)
        try FileManager.default.moveItem(at: h.watch.appendingPathComponent("IMG_22.HEIC"), to: h.watch.appendingPathComponent("beach.heic"))
        try await h.run(60)
        h.key.set("sk-new")
        try await h.run(600, step: 60)
        #expect(h.apiCalls == 0)
        #expect(h.names() == ["IMG_22.jpg", "IMG_22.png", "beach.heic"])
    }

    @Test("a copy the user deleted during the outage is not regenerated after the rename")
    func deletedCopyNotRegenerated() async throws {
        let h = try await Harness()
        h.online.set(false)
        try await h.tick()
        try h.drop("IMG_23.HEIC", "twenty-three")
        try await h.run(40)
        try FileManager.default.removeItem(at: h.watch.appendingPathComponent("IMG_23.png"))
        try await h.run(60)
        h.online.set(true)
        try await h.run(600, step: 60)
        #expect(h.names() == ["content-img-23.heic", "content-img-23.jpg"])
    }
}
