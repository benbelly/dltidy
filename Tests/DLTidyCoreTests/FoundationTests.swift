import DLTidyKit
import Foundation
import Testing
@testable import DLTidyCore

private func runTool(_ path: String, _ args: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

@Suite("M1: ledger, scanner, staging, baseline")
struct FoundationTests {
    @Test("xattr and inode survive mv and a Trash-style round trip; cp and FileManager copies keep the xattr with a new inode")
    func xattrInodeSurvival() async throws {
        let h = try await Harness()
        let a = try h.drop("a.png", "data")
        try FS.setXattr(a, name: FS.roleXattr, value: "output")
        let inode = try #require(try FS.lstatEntry(a)).inode

        let moved = h.watch.appendingPathComponent("moved.png")
        #expect(try runTool("/bin/mv", [a.path, moved.path]) == 0)
        #expect(try FS.lstatEntry(moved)?.inode == inode)
        #expect(FS.getXattr(moved, name: FS.roleXattr) == "output")

        let trash = h.root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: moved, to: trash.appendingPathComponent("moved.png"))
        try FileManager.default.moveItem(at: trash.appendingPathComponent("moved.png"), to: moved)
        #expect(try FS.lstatEntry(moved)?.inode == inode)
        #expect(FS.getXattr(moved, name: FS.roleXattr) == "output")

        let cp = h.watch.appendingPathComponent("cp.png")
        #expect(try runTool("/bin/cp", [moved.path, cp.path]) == 0)
        #expect(try FS.lstatEntry(cp)?.inode != inode)
        #expect(FS.getXattr(cp, name: FS.roleXattr) == "output")

        let fmCopy = h.watch.appendingPathComponent("fm.png")
        try FileManager.default.copyItem(at: moved, to: fmCopy)
        #expect(FS.getXattr(fmCopy, name: FS.roleXattr) == "output")

        let dittoCopy = h.watch.appendingPathComponent("ditto.png")
        #expect(try runTool("/usr/bin/ditto", [moved.path, dittoCopy.path]) == 0)
        #expect(FS.getXattr(dittoCopy, name: FS.roleXattr) == "output")
    }

    @Test("baseline of a 10,000-file dir: one transaction, all pre-existing, 0 actions afterwards")
    func baselineTenThousand() async throws {
        let h = try await Harness()
        for i in 0..<10_000 {
            let url = h.watch.appendingPathComponent(String(format: "IMG_%05d.jpg", i))
            #expect(FileManager.default.createFile(atPath: url.path, contents: Data("f\(i)".utf8)))
        }
        let start = Date()
        try await h.tick()
        let baselineSeconds = Date().timeIntervalSince(start)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'preexisting'") == 10_000)
        #expect(try h.meta("baseline_done_at") != nil)
        let scanStart = Date()
        try await h.run(60, step: 2)
        let perScan = Date().timeIntervalSince(scanStart) / 31
        #expect(h.actionCount == 0)
        #expect(h.apiCalls == 0)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role != 'preexisting'") == 0)
        #expect(baselineSeconds < 10, "baseline took \(baselineSeconds) s")
        #expect(perScan < 1, "scan of 10,000 entries took \(perScan) s")
        // Background hashing proceeds in bounded steps.
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE sha256 IS NOT NULL") > 0)
    }

    @Test("a scan of an unreadable or missing watch dir aborts: no baseline, one notice")
    func scanAbort() async throws {
        let h = try await Harness()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: h.watch.path)
        try await h.tick()
        try await h.tick()
        #expect(try h.meta("baseline_done_at") == nil)
        #expect(h.notifier.count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.watch.path)
        try h.drop("Existing Photo.jpg", "x")
        try await h.tick()
        #expect(try h.meta("baseline_done_at") != nil)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'preexisting'") == 1)
        #expect(try h.count("SELECT COUNT(*) FROM notices WHERE active = 1") == 0)

        // A watch dir that disappears is not "empty": no item is marked missing.
        try FileManager.default.moveItem(at: h.watch, to: h.root.appendingPathComponent("gone"))
        try await h.tick()
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE missing_since IS NOT NULL") == 0)
        try FileManager.default.moveItem(at: h.root.appendingPathComponent("gone"), to: h.watch)
    }

    @Test("scanner: top level only, lstat kinds, no recursion into directories")
    func scanner() async throws {
        let h = try await Harness()
        try h.drop("a.txt", "a")
        let sub = h.watch.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("b".utf8).write(to: sub.appendingPathComponent("b.txt"))
        try FileManager.default.createSymbolicLink(at: h.watch.appendingPathComponent("l"), withDestinationURL: sub)
        let entries = try FS.scanTopLevel(h.watch)
        #expect(Set(entries.map(\.name)) == ["a.txt", "sub", "l"])
        #expect(entries.first { $0.name == "a.txt" }?.kind == .regular)
        #expect(entries.first { $0.name == "sub" }?.kind == .directory)
        #expect(entries.first { $0.name == "l" }?.kind == .symlink)
    }

    @Test("staging: clonefile works; leftovers are removed at start")
    func staging() async throws {
        let h = try await Harness()
        let src = try h.drop("x.jpg", "payload")
        let dst = h.config.stagingDir.appendingPathComponent("probe-clone")
        try FS.clone(src, to: dst)
        #expect(try FS.sha256(dst) == (try FS.sha256(src)))
        try FileManager.default.createDirectory(at: h.config.stagingDir.appendingPathComponent("99/work"), withIntermediateDirectories: true)
        try await h.restart()
        #expect(h.stagingLeftovers().isEmpty)
    }

    @Test("renameExclusive never overwrites")
    func renameExcl() async throws {
        let h = try await Harness()
        let a = try h.drop("a.jpg", "a")
        let b = try h.drop("b.jpg", "b")
        #expect(throws: POSIXFailure.self) { try FS.renameExclusive(a, to: b) }
        #expect(h.content("b.jpg") == "b")
    }

    @Test("ledger: WAL, synchronous=FULL, schema_version, quick_check")
    func ledgerPragmas() async throws {
        let h = try await Harness()
        let ledger = try Ledger(url: h.config.ledgerURL)
        #expect(try ledger.db.scalarText("PRAGMA journal_mode") == "wal")
        #expect(try ledger.db.scalarInt("PRAGMA synchronous") == 2)
        #expect(ledger.meta("schema_version") == String(Schema.currentVersion))
        #expect(ledger.db.quickCheck())
        // Migration is idempotent.
        try Schema.migrate(ledger.db)
        #expect(ledger.meta("schema_version") == String(Schema.currentVersion))
    }

    @Test("daily VACUUM INTO backup keeps 7; a corrupt ledger is restored and rebaselined")
    func backupsAndRestore() async throws {
        let h = try await Harness()
        try await h.tick()
        for _ in 0..<10 {
            h.clock.advance(86_400)
            try await h.tick()
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: h.config.backupsDir.path).filter { $0.hasSuffix(".sqlite") }
        #expect(backups.count == 7)

        try h.drop("IMG_1.HEIC", "one")
        try await h.run(40)
        let actions = h.actionCount
        h.engine = nil
        try Data(repeating: 0x41, count: 4096).write(to: h.config.ledgerURL)
        try? FileManager.default.removeItem(atPath: h.config.ledgerURL.path + "-wal")
        try await h.restart()
        try await h.run(120)
        #expect(h.actionCount == actions)
        #expect(h.notifier.posts.get.filter { $0.title.contains("ledger") }.count == 1)
        #expect(try h.meta("rebaseline") == nil)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'adopted'") == 2)
    }

    @Test("log rotates at the size limit, keeping N files")
    func logRotation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dltidy-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Log(url: dir.appendingPathComponent("dltidy.log"), maxBytes: 1_000, filesKept: 5)
        for i in 0..<500 { log.info("line \(i) " + String(repeating: "x", count: 40)) }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["dltidy.log", "dltidy.log.1", "dltidy.log.2", "dltidy.log.3", "dltidy.log.4", "dltidy.log.5"])
        let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("dltidy.log").path)[.size] as? Int
        #expect((size ?? 0) <= 1_000)
    }
}

@Suite("Soak")
struct SoakTests {
    @Test("1,000 scans after processing: 0 unexpected actions, 0 further calls")
    func soak() async throws {
        let h = try await Harness()
        try h.drop("Old Report.pdf", "old")
        try await h.tick()
        try h.drop("IMG_1.HEIC", "still")
        try h.drop("IMG_1.MOV", "live dur=2")
        try h.drop("VID_2.mov", "clip dur=7")
        try h.drop("maybe_thing.png", "png")
        try h.drop("Notes.txt", "text")
        try h.drop("archive.zip", "zip")
        try await h.run(60)
        let actions = h.actionCount, calls = h.apiCalls, converts = h.media.converts.get.count
        #expect(actions > 0)
        for i in 0..<1_000 {
            try await h.tick()
            h.clock.advance(i % 100 == 99 ? 300 : 2)
            // Benign user activity along the way.
            if i == 200 {
                try FileManager.default.moveItem(at: h.watch.appendingPathComponent("content-vid-2.gif"),
                                                 to: h.watch.appendingPathComponent("loop.gif"))
            }
            if i == 400 { try FileManager.default.removeItem(at: h.watch.appendingPathComponent("content-vid-2.mp4")) }
            if i == 600 { FS.removeTree(h.watch.appendingPathComponent("archive.zip")) }
        }
        #expect(h.actionCount == actions)
        #expect(h.apiCalls == calls)
        #expect(h.media.converts.get.count == converts)
        try h.assertNoDuplicateOutputs()
        #expect(h.stagingLeftovers().isEmpty)
    }
}

@Suite("Commands and health")
struct CommandTests {
    @Test("pause stops processing; resume processes the backlog")
    func pauseResume() async throws {
        let h = try await Harness()
        try await h.tick()
        let client = try ControlClient(config: h.config)
        _ = try client.send(.pause, timeout: 0)
        try h.drop("IMG_1.HEIC", "one")
        try await h.run(120)
        #expect(h.actionCount == 0)
        #expect(try client.status().contains("paused"))
        _ = try client.send(.resume, timeout: 0)
        try await h.run(10)
        #expect(h.actionCount == 3)
    }

    @Test("resume --skip-backlog drops files that arrived while paused")
    func skipBacklog() async throws {
        let h = try await Harness()
        try await h.tick()
        let client = try ControlClient(config: h.config)
        _ = try client.send(.pause, timeout: 0)
        try h.drop("IMG_1.HEIC", "one")
        try await h.run(60)
        _ = try client.send(.resume, arg: "skip-backlog", timeout: 0)
        try await h.run(120)
        #expect(h.actionCount == 0)
        #expect(try h.count("SELECT COUNT(*) FROM items WHERE role = 'skipped'") == 1)
        #expect(try h.db().query("SELECT result FROM commands ORDER BY id DESC LIMIT 1") { $0.text(0) }.first?.contains("1 waiting") == true)
    }

    @Test("undo --last and undo <name> restore old names of the original and its present copies; no further renames")
    func undo() async throws {
        let h = try await Harness()
        h.online.set(false)
        try await h.tick()
        try h.drop("IMG_1.HEIC", "one")
        try await h.run(40)
        h.online.set(true)
        try await h.tick() // deferred rename of original + copies
        try h.drop("IMG_2.png", "two")
        try await h.run(40)
        #expect(h.names() == ["content-img-1.heic", "content-img-1.jpg", "content-img-1.png", "content-img-2.jpg", "content-img-2.png"])
        let client = try ControlClient(config: h.config)
        _ = try client.send(.undo, timeout: 0)
        try await h.tick()
        #expect(h.names() == ["IMG_2.jpg", "IMG_2.png", "content-img-1.heic", "content-img-1.jpg", "content-img-1.png"])
        _ = try client.send(.undo, arg: "content-img-1.jpg", timeout: 0)
        try await h.tick()
        #expect(h.names() == ["IMG_1.HEIC", "IMG_1.jpg", "IMG_1.png", "IMG_2.jpg", "IMG_2.png"])
        try await h.run(3_600, step: 300)
        #expect(h.names() == ["IMG_1.HEIC", "IMG_1.jpg", "IMG_1.png", "IMG_2.jpg", "IMG_2.png"])
        #expect(try client.recentActions(limit: 3).contains("undo"))
    }

    @Test("status reports caps, breaker, pending and incidents")
    func status() async throws {
        let h = try await Harness()
        try await h.tick()
        try h.drop("IMG_1.HEIC", "one")
        try await h.run(40)
        let s = try ControlClient(config: h.config).status(now: h.clock.now())
        #expect(s.contains("today 1/300"))
        #expect(s.contains("breaker:    closed"))
        #expect(s.contains("0 arriving, 0 in progress"))
    }

    @Test("health: a missing tool raises one notice, cleared when it resolves; never blocks scanning")
    func health() async throws {
        let present = Locked(false)
        let h = try await Harness()
        var env = h.environment
        env.requiredTools = ["ffmpeg"]
        env.resolveTool = { present.get ? "/opt/homebrew/bin/\($0)" : nil }
        h.engine = try await Engine(config: h.config, environment: env)
        var results = await h.engine.runHealth()
        #expect(results.first { $0.name == "tools" }?.ok == false)
        #expect(results.first { $0.name == "staging" }?.ok == true)
        #expect(results.first { $0.name == "ledger" }?.ok == true)
        await h.engine.runHealth()
        #expect(h.notifier.count == 1)
        present.set(true)
        results = await h.engine.runHealth()
        #expect(results.allSatisfy { $0.ok })
        #expect(try h.count("SELECT COUNT(*) FROM notices WHERE active = 1") == 0)
        #expect(try h.meta("health_report")?.contains("ok   tools") == true)
    }

    @Test("health: a missing ImageMagick policy is reported and raises one notice, cleared when it returns")
    func healthMagickPolicy() async throws {
        let problem = Locked<String?>("cannot read policy.xml")
        let h = try await Harness()
        var env = h.environment
        env.magickPolicyProblem = { problem.get }
        h.engine = try await Engine(config: h.config, environment: env)
        var results = await h.engine.runHealth()
        #expect(results.first { $0.name == "magick-policy" }?.ok == false)
        #expect(results.first { $0.name == "magick-policy" }?.detail == "cannot read policy.xml")
        await h.engine.runHealth()
        #expect(h.notifier.count == 1)
        problem.set(nil)
        results = await h.engine.runHealth()
        #expect(results.allSatisfy { $0.ok })
        #expect(try h.meta("health_report")?.contains("ok   magick-policy") == true)
    }

    @Test("a missing tool during conversion: item waits with one notice, resumes when the tool returns")
    func toolMissingWaits() async throws {
        let h = try await Harness()
        try await h.tick()
        h.media.missingTool.set("ffmpeg")
        try h.drop("Cat Video.mov", "clip dur=3")
        try await h.run(1_200, step: 30)
        #expect(h.actionCount == 0)
        #expect(h.notifier.count == 1)
        let item = try #require(try h.items("role = 'original'").first)
        #expect(item.state == .probe)
        h.media.missingTool.set(nil)
        try await h.run(600, step: 30)
        #expect(h.names() == ["Cat Video.gif", "Cat Video.mov", "Cat Video.mp4"])
        #expect(try h.count("SELECT COUNT(*) FROM notices WHERE active = 1") == 0)
    }

    @Test("low disk space defers conversions with one notice")
    func diskSpace() async throws {
        let h = try await Harness()
        try await h.tick()
        h.free.set(1 << 30)
        try h.drop("Desk Photo.jpg", "desk")
        try await h.run(600, step: 30)
        #expect(h.actionCount == 0)
        #expect(h.notifier.count == 1)
        h.free.set(100 << 30)
        try await h.run(900, step: 30)
        #expect(h.names() == ["Desk Photo.jpg", "Desk Photo.png"])
    }

    @Test("on battery a long encode waits for AC")
    func power() async throws {
        let h = try await Harness()
        let deferring = DeferringMedia(base: h.media, power: h.power)
        var env = h.environment
        env.media = deferring
        h.engine = try await Engine(config: h.config, environment: env)
        try await h.tick()
        h.power.onAC.set(false)
        try h.drop("Long Talk.mov", "talk dur=120")
        try await h.run(1_200, step: 30)
        #expect(h.actionCount == 0)
        h.power.onAC.set(true)
        try await h.run(900, step: 30)
        #expect(h.names() == ["Long Talk.mov", "Long Talk.mp4"])
    }
}

/// Throws `.deferred` from `convert` when long encodes are not allowed.
struct DeferringMedia: MediaProcessing {
    let base: FakeMedia
    let power: FakePower
    func probe(_ file: URL, sourceExtension: String) async throws -> MediaInfo { try await base.probe(file, sourceExtension: sourceExtension) }
    func plannedOutputs(info: MediaInfo, sourceExtension: String, isLivePhotoVideo: Bool) -> [OutputFormat] {
        base.plannedOutputs(info: info, sourceExtension: sourceExtension, isLivePhotoVideo: isLivePhotoVideo)
    }
    func convert(input: URL, info: MediaInfo, to format: OutputFormat, output: URL, workDir: URL, allowLongEncode: Bool) async throws {
        if !allowLongEncode { throw MediaError.deferred("on battery") }
        try await base.convert(input: input, info: info, to: format, output: output, workDir: workDir, allowLongEncode: allowLongEncode)
    }
}
