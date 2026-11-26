import DLTidyKit
import Foundation
import Testing
@testable import DLTidyCore

@Suite("Caps and retries")
struct CostTests {
    @Test("400 files at cap 300: 300 reserved rows, 100 converted with deferred rename, 1 notice")
    func dailyCap() async throws {
        let h = try await Harness()
        try await h.tick()
        for i in 1...400 { try h.drop(String(format: "IMG_%04d.png", i), "png \(i)") }
        try await h.run(40)
        #expect(h.apiCalls == 300)
        #expect(h.naming.count == 300)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'original' AND name_status = 'renamed'") == 300)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'original' AND name_status = 'waitName' AND state = 'done'") == 100)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'output' AND state = 'placed'") == 400)
        #expect(h.notifier.count == 1)
        #expect(h.notifier.posts.get.first?.title.contains("cap") == true)
        // More scans the same day: no further calls, no further notice.
        try await h.run(600, step: 60)
        #expect(h.apiCalls == 300)
        #expect(h.notifier.count == 1)
        // Next day, within 24 h of first_seen: the 100 deferred groups are renamed with their copies.
        h.clock.advance(12 * 3_600)
        try await h.tick()
        #expect(h.apiCalls == 400)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'original' AND name_status = 'renamed'") == 400)
        #expect(h.names().filter { $0.hasPrefix("IMG_") }.isEmpty)
        try h.assertConsistent()
    }

    @Test("monthly token cap counts failures and estimates")
    func tokenCap() async throws {
        let h = try await Harness { $0.monthlyInputTokenCap = 2_000; $0.estimatedTokensImage = 900 }
        h.naming.nameResponder.set { _, _ in .transient(reason: "HTTP 500") }
        try await h.tick()
        for i in 1...4 { try h.drop("IMG_\(i).png", "png \(i)") }
        try await h.run(40)
        // Two failed requests with no usage count 900 each; a third would exceed 2,000.
        #expect(h.apiCalls == 2)
    }

    @Test("500 on every call: ≤ 2 calls per item, breaker opens after 3")
    func serverErrors() async throws {
        let h = try await Harness()
        h.naming.nameResponder.set { _, _ in .transient(reason: "HTTP 500") }
        try await h.tick()
        for i in 1...5 { try h.drop("IMG_\(i).png", "png \(i)") }
        try await h.run(30)
        #expect(h.apiCalls == 3)
        let mode = try h.db().query("SELECT state FROM breaker WHERE id = 1") { $0.text(0) }.first
        #expect(mode == "open")
        try await h.run(26 * 3_600, step: 120)
        let perGroup = try h.db().query("SELECT group_id, COUNT(*) FROM api_calls GROUP BY group_id") { $0.int(1) }
        #expect(perGroup.allSatisfy { $0 <= 2 })
        #expect(h.apiCalls <= 10)
        // Conversions still happened under the old names.
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'output' AND state = 'placed'") == 5)
        #expect(h.notifier.count == 0)
    }

    @Test("breaker: probe after 15 min, interval doubles on probe failure")
    func breakerProbe() async throws {
        let h = try await Harness()
        h.naming.nameResponder.set { _, _ in .transient(reason: "timeout") }
        try await h.tick()
        for i in 1...6 { try h.drop("IMG_\(i).png", "png \(i)") }
        try await h.run(30)
        #expect(h.apiCalls == 3)
        try await h.run(14 * 60, step: 30)
        #expect(h.apiCalls == 3)
        try await h.run(2 * 60, step: 30)
        #expect(h.apiCalls == 4) // one probe
        let interval = try h.db().query("SELECT interval FROM breaker") { $0.double(0) }.first
        #expect(interval == 1_800)
        try await h.run(28 * 60, step: 30) // probe failed at ~930 s; open until ~2,730 s
        #expect(h.apiCalls == 4)
        try await h.run(4 * 60, step: 30)
        #expect(h.apiCalls == 5)
    }

    @Test("401: one call in total; set-key closes the breaker")
    func authFailure() async throws {
        let h = try await Harness()
        h.naming.nameResponder.set { _, _ in .authFailure(status: 401) }
        try await h.tick()
        for i in 1...3 { try h.drop("IMG_\(i).png", "png \(i)") }
        try await h.run(3 * 3_600, step: 60)
        #expect(h.apiCalls == 1)
        #expect(h.notifier.posts.get.filter { $0.title.contains("rejected") }.count == 1)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'output' AND state = 'placed'") == 3)

        h.naming.nameResponder.set { _, name in .ok(NameSuggestion(name: "fixed \(name.fileStem)", confidence: .high), APIUsage(inputTokens: 1, outputTokens: 1)) }
        let client = try ControlClient(config: h.config)
        _ = try client.send(.keyUpdated, timeout: 0)
        try await h.tick()
        #expect(h.apiCalls == 4)
        #expect(h.names().contains("fixed-img-2.png"))
    }

    @Test("429 honours retry-after (minimum 60 s)")
    func rateLimit() async throws {
        let h = try await Harness()
        h.naming.nameResponder.set { i, name in
            i == 0 ? .rateLimited(retryAfter: 120)
                   : .ok(NameSuggestion(name: "named \(name.fileStem)", confidence: .high), APIUsage(inputTokens: 1, outputTokens: 1))
        }
        try await h.tick()
        try h.drop("IMG_1.png", "one")
        try h.drop("IMG_2.png", "two")
        try await h.run(30)
        #expect(h.apiCalls == 1)
        try await h.run(80, step: 10) // t = 110; cool-down ends at first call + 120
        #expect(h.apiCalls == 1)
        try await h.run(40, step: 10)
        #expect(h.apiCalls == 3)
        let times = try h.db().query("SELECT at FROM api_calls ORDER BY id") { $0.double(0) }
        #expect(times[1] - times[0] >= 120)
        #expect(h.names().contains("named-img-1.png") && h.names().contains("named-img-2.png"))
    }

    @Test("transient failure: one second attempt 5 min later, then the copies are renamed")
    func transientThenSuccess() async throws {
        let h = try await Harness()
        h.naming.nameResponder.set { i, name in
            i == 0 ? .transient(reason: "HTTP 529")
                   : .ok(NameSuggestion(name: "later \(name.fileStem)", confidence: .high), APIUsage(inputTokens: 1, outputTokens: 1))
        }
        try await h.tick()
        try h.drop("IMG_8.HEIC", "eight")
        try await h.run(30)
        #expect(h.names() == ["IMG_8.HEIC", "IMG_8.jpg", "IMG_8.png"])
        try await h.run(4 * 60, step: 20)
        #expect(h.apiCalls == 1)
        try await h.run(60, step: 20)
        #expect(h.apiCalls == 2)
        #expect(h.names() == ["later-img-8.heic", "later-img-8.jpg", "later-img-8.png"])
    }

    @Test("Budget.reserve refuses non-originals, duplicate hashes and exhausted groups")
    func reserveGuards() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_1.png", "one")
        try await h.run(30)
        let ledger = try Ledger(url: h.config.ledgerURL)
        let notices = Notices(ledger: ledger, notifier: h.notifier, clock: h.clock, log: h.log)
        let budget = Budget(ledger: ledger, config: h.config, clock: h.clock, notices: notices, log: h.log, isOnline: { true })
        let original = try #require(try ledger.items(where: "role = 'original'").first)
        // Renamed: status no longer waiting.
        guard case .exhausted = try budget.reserve(.name, leader: original, estimatedTokens: 1) else {
            Issue.record("reserve granted for a renamed item"); return
        }
        let output = try #require(try ledger.items(where: "role = 'output'").first)
        guard case .exhausted = try budget.reserve(.name, leader: output, estimatedTokens: 1) else {
            Issue.record("reserve granted for an output"); return
        }
        // Waiting status but hash seen twice.
        try ledger.db.run("UPDATE items SET name_status = 'waitName' WHERE id = ?", original.id)
        try ledger.db.run("INSERT INTO items(role, state, path, original_name, first_seen, sha256) VALUES('duplicate', 'known', 'x', 'x', 0, ?)",
                          original.sha256)
        guard case .exhausted = try budget.reserve(.name, leader: original, estimatedTokens: 1) else {
            Issue.record("reserve granted for a hash seen twice"); return
        }
        try ledger.db.run("DELETE FROM items WHERE path = 'x'")
        // Group allowance: 1 call used; 1 more naming call allowed, then exhausted.
        guard case .granted = try budget.reserve(.name, leader: original, estimatedTokens: 1) else {
            Issue.record("second naming attempt refused"); return
        }
        guard case .exhausted = try budget.reserve(.name, leader: original, estimatedTokens: 1) else {
            Issue.record("third naming attempt granted"); return
        }
        guard case .granted = try budget.reserve(.classify, leader: original, estimatedTokens: 1) else {
            Issue.record("classification refused with allowance left"); return
        }
        guard case .exhausted = try budget.reserve(.classify, leader: original, estimatedTokens: 1) else {
            Issue.record("fourth request for a group granted"); return
        }
    }
}
