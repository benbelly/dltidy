import DLTidyKit
import Foundation
import Testing
@testable import DLTidyCore

@Suite("Grouping")
struct GroupingTests {
    @Test("Live Photo IMG_1.HEIC + IMG_1.MOV: 1 naming call, shared slug, no mp4/gif for the MOV")
    func livePhoto() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_1.HEIC", "still-1")
        try h.drop("IMG_1.MOV", "live video dur=3")
        try await h.run(40)
        #expect(h.naming.count == 1)
        #expect(h.names() == ["content-img-1.heic", "content-img-1.jpg", "content-img-1.mov", "content-img-1.png"])
        let mov = try #require(try h.items("path = 'content-img-1.mov'").first)
        #expect(mov.isLiveVideo)
        #expect(h.media.converts.get.allSatisfy { $0.format == .png || $0.format == .jpg })
    }

    @Test("a pre-existing IMG_1.jpg blocks JPG generation after the rename")
    func preexistingSiblingBlocks() async throws {
        let h = try await Harness()
        try h.drop("IMG_1.jpg", "old jpg")
        try await h.tick() // baseline
        try h.drop("IMG_1.HEIC", "still-1")
        try h.drop("IMG_1.MOV", "live video dur=3")
        try await h.run(40)
        #expect(h.names() == ["IMG_1.jpg", "content-img-1.heic", "content-img-1.mov", "content-img-1.png"])
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'output' AND format = 'jpg' AND state = 'skipped_exists'") == 1)
    }

    @Test("a lone video gets mp4 and, at ≤ 10 s, a gif; a long one gets mp4 only")
    func videoOutputs() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("VID_2.mov", "clip dur=8")
        try h.drop("VID_3.mov", "clip dur=30")
        try await h.run(40)
        #expect(h.names() == ["content-vid-2.gif", "content-vid-2.mov", "content-vid-2.mp4", "content-vid-3.mov", "content-vid-3.mp4"])
        #expect(h.naming.count == 2)
    }

    @Test("slug collision takes -2, checked case-insensitively against planned siblings")
    func collision() async throws {
        let h = try await Harness()
        try h.drop("CONTENT-IMG-4.PNG", "unrelated")
        try await h.tick()
        try h.drop("IMG_4.HEIC", "still-4")
        try await h.run(40)
        #expect(h.names() == ["CONTENT-IMG-4.PNG", "content-img-4-2.heic", "content-img-4-2.jpg", "content-img-4-2.png"])
    }

    @Test("unclear name: 1 classification + 1 naming call")
    func unclearName() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("maybe_thing.png", "png")
        try await h.run(40)
        #expect(h.naming.calls.get.map(\.kind) == ["classify", "name"])
        #expect(h.names() == ["content-maybe-thing.jpg", "content-maybe-thing.png"])
    }

    @Test("meaningful name: 0 calls; low confidence and invalid slug keep the name")
    func keepName() async throws {
        let h = try await Harness()
        h.naming.nameResponder.set { i, name in
            i == 0 ? .ok(NameSuggestion(name: "receipt", confidence: .low), APIUsage(inputTokens: 1, outputTokens: 1))
                   : .ok(NameSuggestion(name: "!!", confidence: .high), APIUsage(inputTokens: 1, outputTokens: 1))
        }
        try await h.tick()
        try h.drop("Device_Stand_-_3_Slots.png", "stand")
        try h.drop("IMG_10.png", "a")
        try await h.run(40)
        try h.drop("IMG_11.png", "b")
        try await h.run(40)
        #expect(h.naming.count == 2)
        #expect(h.names() == ["Device_Stand_-_3_Slots.jpg", "Device_Stand_-_3_Slots.png", "IMG_10.jpg", "IMG_10.png", "IMG_11.jpg", "IMG_11.png"])
    }

    @Test("non-media nameable document is renamed, archives are ignored without hashing")
    func documentsAndArchives() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("8F14E45F-CEEA-467A-9575-2C16C8B6A1B2.pdf", "pdf text")
        try h.drop("IMG_5.zip", "zip")
        try await h.run(40)
        #expect(h.names() == ["IMG_5.zip", "content-8f14e45f-ceea-467a-9575-2c16c8b6a1b2.pdf"])
        let zip = try #require(try h.items("path = 'IMG_5.zip'").first)
        #expect(zip.role == .ignored && zip.sha256 == nil)
    }
}
