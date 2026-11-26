import DLTidyKit
import Foundation
import Testing
@testable import DLTidyCore

/// Files covering every transition: Live Photo pair (naming + rename + still outputs), a short
/// video (mp4 + gif), an unclear name (classification + naming).
private func dropScenario(_ h: Harness) throws {
    try h.drop("IMG_1.HEIC", "still-1")
    try h.drop("IMG_1.MOV", "live dur=3")
    try h.drop("VID_2.mov", "clip dur=4")
    try h.drop("maybe_doc.png", "png-doc")
}

private func assertInvariants(_ h: Harness, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let perGroup = try h.db().query("SELECT group_id, COUNT(*) FROM api_calls GROUP BY group_id") { Int($0.int(1)) }
    #expect(perGroup.allSatisfy { $0 <= 3 }, "more than 3 requests for a group", sourceLocation: sourceLocation)
    #expect(h.apiCalls <= h.config.dailyCallCap, sourceLocation: sourceLocation)
    try h.assertNoDuplicateOutputs(sourceLocation: sourceLocation)
    try h.assertConsistent(sourceLocation: sourceLocation)
    #expect(h.stagingLeftovers().isEmpty, "staging leftovers: \(h.stagingLeftovers())", sourceLocation: sourceLocation)
    #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'original' AND state IN ('probe', 'naming', 'convert')") == 0,
            "items left mid-work", sourceLocation: sourceLocation)
    // At most one placed output per (original, format).
    let dup = try h.count("SELECT COUNT(*) FROM (SELECT parent_id, format FROM items WHERE role = 'output' AND state = 'placed' GROUP BY parent_id, format HAVING COUNT(*) > 1)")
    #expect(dup == 0, sourceLocation: sourceLocation)
}

@Suite("Crash safety")
struct CrashSafetyTests {
    @Test("one crash at each transition, then recovery to a complete, consistent result", arguments: Failpoints.all)
    func crashOnce(point: String) async throws {
        let h = try await Harness()
        try await h.tick()
        try dropScenario(h)
        h.failpoints.arm(point)
        var crashes = 0
        for _ in 0..<60 {
            do {
                try await h.tick()
            } catch is SimulatedCrash {
                crashes += 1
                try await h.restart()
            }
            h.clock.advance(2)
        }
        try await h.run(3_600, step: 30)
        #expect(crashes == 1, "failpoint \(point) not reached")
        try assertInvariants(h)
        // Every original finished; outputs exist for the non-Live-Photo media.
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'original' AND state = 'done'") == 4)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'output' AND state = 'placed'") == 5) // png+jpg, mp4+gif, jpg
        #expect(try h.meta("safe_mode") == nil)
    }

    @Test("crash at the same transition on every pass, 10 restarts 3 min apart", arguments: Failpoints.all)
    func repeatedCrash(point: String) async throws {
        let h = try await Harness()
        try await h.tick()
        try dropScenario(h)
        var crashes = 0
        for _ in 0..<10 {
            let startedAt = h.clock.now()
            h.failpoints.arm(point)
            do {
                for _ in 0..<60 {
                    try await h.tick()
                    h.clock.advance(2)
                }
            } catch is SimulatedCrash {
                crashes += 1
            }
            h.failpoints.disarmAll()
            // KeepAlive restarts the process; the next start is 3 min after the previous one.
            let gap = 180 - h.clock.now().timeIntervalSince(startedAt)
            try await h.restart(after: max(gap, 0))
        }
        try await h.run(3_600, step: 30)
        #expect(crashes >= 1)
        #expect(try h.meta("safe_mode") == nil, "4 starts per 10 min must not enter safe mode")
        try assertInvariants(h)
    }

    @Test("3 unfinished starts on one item → failed_poison, no further work")
    func poison() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("Garden Photo.HEIC", "five")
        for _ in 0..<5 {
            h.failpoints.arm("before-place")
            do {
                for _ in 0..<30 { try await h.tick(); h.clock.advance(2) }
            } catch is SimulatedCrash {}
            try await h.restart()
        }
        try await h.run(600, step: 30)
        let item = try #require(try h.items("role = 'original'").first)
        #expect(item.state == .failedPoison)
        #expect(h.apiCalls == 0)
        #expect(h.actionCount == 0)
        #expect(h.stagingLeftovers().isEmpty)
    }

    @Test("5 starts in 10 min → safe mode: 0 calls, 0 conversions, 1 notice; resume clears it")
    func safeMode() async throws {
        let h = try await Harness()
        try await h.tick()
        for _ in 0..<4 { try await h.restart(after: 60) }
        #expect(try h.meta("safe_mode") == "1")
        try h.drop("IMG_6.HEIC", "six")
        try await h.run(600, step: 10)
        #expect(h.apiCalls == 0)
        #expect(h.actionCount == 0)
        #expect(h.media.converts.get.isEmpty)
        #expect(h.notifier.posts.get.filter { $0.title.contains("safe mode") }.count == 1)
        let client = try ControlClient(config: h.config)
        _ = try client.send(.resume, timeout: 0)
        try await h.run(40)
        #expect(h.names() == ["content-img-6.heic", "content-img-6.jpg", "content-img-6.png"])
    }

    @Test("second ledger reset within 7 days → safe mode")
    func repeatedReset() async throws {
        let h = try await Harness()
        try await h.tick()
        for _ in 0..<2 {
            h.engine = nil
            try Data("not a database".utf8).write(to: h.config.ledgerURL)
            try? FileManager.default.removeItem(atPath: h.config.ledgerURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: h.config.ledgerURL.path + "-shm")
            try await h.restart(after: 3_600)
            try await h.tick()
        }
        #expect(try h.meta("safe_mode") == "1")
    }
}

@Suite("Fuse")
struct FuseTests {
    @Test("a forced repeat placement of the same output → pause + 1 notice, nothing written")
    func repeatPlacement() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_7.HEIC", "seven")
        try await h.run(40)
        let before = h.actionCount
        let original = try #require(try h.items("role = 'original'").first)
        // Force: the png row vanishes from the ledger, the file is gone, and the item is re-queued.
        try FileManager.default.removeItem(at: h.watch.appendingPathComponent("content-img-7.png"))
        try h.sql("DELETE FROM items WHERE role = 'output' AND format = 'png'")
        try h.sql("UPDATE items SET state = 'convert' WHERE id = ?", [original.id])
        try await h.run(60)
        #expect(h.actionCount == before)
        #expect(!h.exists("content-img-7.png"))
        #expect(try h.meta("paused") == "1")
        #expect(h.notifier.posts.get.filter { $0.title.contains("paused") }.count == 1)
        try await h.run(300, step: 30)
        #expect(h.notifier.count == 1)
    }

    @Test("more than N actions in an hour → pause + 1 notice")
    func actionRate() async throws {
        let h = try await Harness { $0.fuseActionsPerHour = 5 }
        try await h.tick()
        for i in 1...3 { try h.drop("IMG_\(i).HEIC", "heic \(i)") }
        try await h.run(60)
        #expect(h.actionCount == 5)
        #expect(try h.meta("paused") == "1")
        #expect(h.notifier.count == 1)
        try await h.run(300, step: 30)
        #expect(h.actionCount == 5)
    }
}

@Suite("Atomicity")
struct AtomicityTests {
    @Test("no file in the watch dir is ever undecodable or missing its xattr")
    func watcher() async throws {
        let h = try await Harness()
        try await h.tick()
        let inputs = Locked(Set<Int64>())
        let violations = Locked<[String]>([])
        let watch = h.watch
        let check: @Sendable () -> Void = {
            for name in (try? FS.listNames(watch)) ?? [] {
                let url = watch.appendingPathComponent(name)
                guard let e = try? FS.lstatEntry(url), e.kind == .regular else { continue }
                if inputs.get.contains(e.inode) { continue }
                let role = FS.getXattr(url, name: FS.roleXattr)
                let body = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
                if role != "output" || !body.hasPrefix("OUT:") {
                    violations.mutate { $0.append("\(name) role=\(role ?? "nil") body=\(body.prefix(12))") }
                }
            }
        }
        h.observer.set { _ in check() }
        for i in 1...6 { try h.drop("IMG_\(i).HEIC", "still \(i) " + String(repeating: "x", count: 100_000)) }
        try h.drop("VID_9.mov", "clip dur=6")
        inputs.set(h.inputInodes)
        let stop = Locked(false)
        let poller = Task.detached {
            while !stop.get {
                check()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        try await h.run(60)
        stop.set(true)
        await poller.value
        #expect(h.actionCount == 6 * 3 + 3)
        #expect(violations.get.isEmpty, "\(violations.get.prefix(5))")
    }
}
