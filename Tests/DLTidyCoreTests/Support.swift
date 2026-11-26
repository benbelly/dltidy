import DLTidyKit
import Foundation
import Testing
@testable import DLTidyCore

// MARK: - Small thread-safe box

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    var get: T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
    func mutate<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&value) } }
}

// MARK: - Clock

final class TestClock: Clock, @unchecked Sendable {
    private let t: Locked<Date>
    init(_ start: Date) { t = Locked(start) }
    func now() -> Date { t.get }
    func advance(_ seconds: TimeInterval) { t.mutate { $0 = $0.addingTimeInterval(seconds) } }
}

// MARK: - Fakes

/// Media by extension. Content starting with "CORRUPT" does not decode. "dur=N" sets video length.
final class FakeMedia: MediaProcessing, @unchecked Sendable {
    let converts = Locked<[(format: OutputFormat, input: String)]>([])
    let missingTool = Locked<String?>(nil)
    let failFormats = Locked<Set<OutputFormat>>([])

    static let stills: Set<String> = ["heic", "jpg", "jpeg", "png", "tiff", "webp"]
    static let videos: Set<String> = ["mov", "mp4", "mkv"]

    func probe(_ file: URL, sourceExtension: String) async throws -> MediaInfo {
        let text = String(decoding: (try Data(contentsOf: file)).prefix(200), as: UTF8.self)
        if text.hasPrefix("CORRUPT") { throw MediaError.unreadable("fake corrupt") }
        if let tool = missingTool.get { throw MediaError.toolMissing(tool) }
        if Self.stills.contains(sourceExtension) { return MediaInfo(kind: .stillImage, width: 100, height: 80) }
        if Self.videos.contains(sourceExtension) {
            var duration = 5.0
            if let r = text.range(of: "dur=") {
                duration = Double(text[r.upperBound...].prefix { $0.isNumber || $0 == "." }) ?? 5
            }
            return MediaInfo(kind: .video, durationSeconds: duration, width: 640, height: 360)
        }
        if sourceExtension == "gif" { return MediaInfo(kind: .animatedImage, durationSeconds: 2) }
        throw MediaError.notMedia
    }

    func plannedOutputs(info: MediaInfo, sourceExtension: String, isLivePhotoVideo: Bool) -> [OutputFormat] {
        let ext = sourceExtension.lowercased()
        switch info.kind {
        case .stillImage:
            var out: [OutputFormat] = []
            if ext != "png" { out.append(.png) }
            if ext != "jpg" && ext != "jpeg" { out.append(.jpg) }
            return out
        case .video, .animatedImage:
            if isLivePhotoVideo { return [] }
            var out: [OutputFormat] = []
            if ext != "mp4" { out.append(.mp4) }
            if (info.durationSeconds ?? 99) <= 10 && ext != "gif" { out.append(.gif) }
            return out
        }
    }

    func convert(input: URL, info: MediaInfo, to format: OutputFormat, output: URL, workDir: URL, allowLongEncode: Bool) async throws {
        if let tool = missingTool.get { throw MediaError.toolMissing(tool) }
        if failFormats.get.contains(format) { throw MediaError.failed("fake failure") }
        let content = try Data(contentsOf: input)
        converts.mutate { $0.append((format, input.path)) }
        var data = Data("OUT:\(format.rawValue):".utf8)
        data.append(content)
        try data.write(to: output)
    }
}

/// IMG_/DSC_/PXL_/VID_ + digits and UUIDs are generic; stems starting "maybe" are unclear.
struct FakeRules: NameRuling {
    func classify(filename: String) -> NameClass {
        let stem = baseStem(of: filename)
        if stem.range(of: #"^(IMG|DSC|PXL|VID)_?\d+$"#, options: .regularExpression) != nil { return .generic }
        if stem.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#, options: .regularExpression) != nil { return .generic }
        if stem.lowercased().hasPrefix("maybe") { return .unclear }
        return .meaningful
    }

    func baseStem(of filename: String) -> String {
        var stem = filename.fileStem
        if let r = stem.range(of: #"( \(\d+\)| copy( \d+)?)$"#, options: .regularExpression) { stem.removeSubrange(r) }
        return stem
    }

    func slug(from raw: String) -> String? {
        let parts = raw.lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }.prefix(6)
        let s = parts.joined(separator: "-")
        return s.count >= 3 ? String(s.prefix(60)) : nil
    }
}

struct FakeExtractor: ContentExtracting {
    func extract(from file: URL, sourceExtension: String) async -> NamingPayload? {
        let nameable: Set<String> = FakeMedia.stills.union(FakeMedia.videos).union(["pdf", "txt", "gif"])
        guard nameable.contains(sourceExtension) else { return nil }
        guard let data = try? Data(contentsOf: file) else { return nil }
        if FakeMedia.stills.contains(sourceExtension) { return .image(jpeg: data.prefix(64)) }
        return .text(String(decoding: data.prefix(64), as: UTF8.self))
    }
}

final class FakeNaming: NamingService, @unchecked Sendable {
    struct Call: Equatable { var kind: String; var name: String }
    let calls = Locked<[Call]>([])
    /// (call index among name calls, original name) → result
    let nameResponder = Locked<@Sendable (Int, String) -> APIResult<NameSuggestion>>({ _, name in
        .ok(NameSuggestion(name: "content \(name.fileStem)", confidence: .high), APIUsage(inputTokens: 900, outputTokens: 20))
    })
    let classifyResponder = Locked<@Sendable (Int, String) -> APIResult<Bool>>({ _, _ in
        .ok(true, APIUsage(inputTokens: 100, outputTokens: 5))
    })

    var count: Int { calls.get.count }
    var nameCount: Int { calls.get.filter { $0.kind == "name" }.count }

    func classifyStem(_ stem: String, apiKey: String) async -> APIResult<Bool> {
        let i = calls.mutate { c -> Int in
            c.append(Call(kind: "classify", name: stem))
            return c.filter { $0.kind == "classify" }.count - 1
        }
        return classifyResponder.get(i, stem)
    }

    func suggestName(for payload: NamingPayload, originalName: String, apiKey: String) async -> APIResult<NameSuggestion> {
        let i = calls.mutate { c -> Int in
            c.append(Call(kind: "name", name: originalName))
            return c.filter { $0.kind == "name" }.count - 1
        }
        return nameResponder.get(i, originalName)
    }
}

final class RecordingNotifier: Notifier, @unchecked Sendable {
    let posts = Locked<[(title: String, body: String)]>([])
    func post(title: String, body: String) { posts.mutate { $0.append((title, body)) } }
    var count: Int { posts.get.count }
}

final class FakePower: PowerState, @unchecked Sendable {
    let onAC = Locked(true)
    func allowLongEncode() -> Bool { onAC.get }
}

// MARK: - Harness

/// Temp watch/state dirs, an injected clock and fakes. Drives the Engine by direct `tick()` calls.
final class Harness {
    let root: URL
    let watch: URL
    let state: URL
    let logs: URL
    let clock: TestClock
    let media = FakeMedia()
    let naming = FakeNaming()
    let notifier = RecordingNotifier()
    let power = FakePower()
    let failpoints = Failpoints()
    let key = Locked<String?>("sk-test")
    let online = Locked(true)
    let free = Locked<Int64>(100 << 30)
    let actions = Locked<[ActionEvent]>([])
    let observer = Locked<(@Sendable (ActionEvent) -> Void)?>(nil)
    var config: Config
    var engine: Engine!
    let log: Log
    private(set) var inputInodes = Set<Int64>()
    var starts = 0

    init(tweak: (inout Config) -> Void = { _ in }) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dltidy-core-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        watch = root.appendingPathComponent("Downloads", isDirectory: true)
        state = root.appendingPathComponent("state", isDirectory: true)
        logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        // A fixed local noon keeps day/month boundaries predictable.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 10; comps.hour = 12
        clock = TestClock(Calendar.current.date(from: comps)!)
        config = Config(watchDir: watch, stateDir: state, logDir: logs, label: "local.dltidy.test")
        tweak(&config)
        log = Log(url: logs.appendingPathComponent("dltidy.log"), clock: clock)
        try await start()
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: watch.path)
        try? FileManager.default.removeItem(at: root)
    }

    var environment: EngineEnvironment {
        let key = self.key, online = self.online, free = self.free, actions = self.actions, observer = self.observer
        return EngineEnvironment(
            clock: clock, media: media, rules: FakeRules(), extractor: FakeExtractor(), naming: naming,
            notifier: notifier, power: power,
            apiKey: { key.get },
            isOnline: { online.get },
            freeSpace: { _ in free.get },
            requiredTools: ["magick"],
            resolveTool: { "/fake/\($0)" },
            isProcessableExtension: { ext in
                FakeMedia.stills.union(FakeMedia.videos).union(["pdf", "txt", "gif"]).contains(ext)
            },
            failpoints: failpoints,
            onAction: { event in
                actions.mutate { $0.append(event) }
                observer.get?(event)
            },
            log: log
        )
    }

    /// A (re)start of the daemon: a fresh Engine on the same state dir.
    func start() async throws {
        engine = nil
        engine = try await Engine(config: config, environment: environment)
        starts += 1
    }

    /// Simulated crash + restart `gap` seconds later.
    func restart(after gap: TimeInterval = 180) async throws {
        clock.advance(gap)
        try await start()
    }

    func tick() async throws { try await engine.tick() }

    /// Ticks every `step` seconds of injected time for `seconds`.
    func run(_ seconds: TimeInterval, step: TimeInterval = 2) async throws {
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            try await engine.tick()
            clock.advance(step)
            elapsed += step
        }
        try await engine.tick()
    }

    @discardableResult
    func drop(_ name: String, _ content: String) throws -> URL {
        let url = watch.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        if let e = try FS.lstatEntry(url) { inputInodes.insert(e.inode) }
        return url
    }

    func names() -> [String] {
        ((try? FS.listNames(watch)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    func content(_ name: String) -> String {
        String(decoding: (try? Data(contentsOf: watch.appendingPathComponent(name))) ?? Data(), as: UTF8.self)
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: watch.appendingPathComponent(name).path) }

    // MARK: ledger inspection (separate read connection)

    func db() throws -> Database { try Database(path: config.ledgerURL.path) }

    func count(_ sql: String, _ args: [any SQLBindable] = []) throws -> Int {
        Int(try db().query(sql, args) { $0.int(0) }.first ?? 0)
    }

    func items(_ clause: String, _ args: [any SQLBindable] = []) throws -> [Item] {
        try db().query("SELECT \(Item.columns) FROM items WHERE \(clause)", args, Item.init)
    }

    func meta(_ key: String) throws -> String? {
        try db().query("SELECT value FROM meta WHERE key = ?", [key]) { $0.optText(0) }.first ?? nil
    }

    func sql(_ statement: String, _ args: [any SQLBindable] = []) throws {
        try db().runArgs(statement, args)
    }

    var apiCalls: Int { (try? count("SELECT COUNT(*) FROM api_calls")) ?? -1 }
    var actionCount: Int { actions.get.count }

    func stagingLeftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: config.stagingDir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// Ledger consistency: every placed output and every present original exists on disk with its
    /// inode; every non-input file on disk is a placed output.
    func assertConsistent(sourceLocation: SourceLocation = #_sourceLocation) throws {
        for o in try items("role = 'output' AND state = 'placed' AND missing_since IS NULL") {
            let e = try FS.lstatEntry(watch.appendingPathComponent(o.path))
            #expect(e?.inode == o.inode, "output \(o.path) missing or wrong inode", sourceLocation: sourceLocation)
        }
        for o in try items("role = 'output' AND state = 'placing'") {
            Issue.record("output row left in placing: \(o.path)", sourceLocation: sourceLocation)
        }
        #expect(try count("SELECT COUNT(*) FROM actions WHERE status = 'intent'") == 0, sourceLocation: sourceLocation)
        for name in names() {
            guard let e = try FS.lstatEntry(watch.appendingPathComponent(name)) else { continue }
            if inputInodes.contains(e.inode) { continue }
            let row = try items("inode = ? AND role = 'output' AND state = 'placed'", [e.inode])
            #expect(!row.isEmpty, "file \(name) is neither an input nor a placed output", sourceLocation: sourceLocation)
        }
    }

    /// No two files on disk for the same (original, format).
    func assertNoDuplicateOutputs(sourceLocation: SourceLocation = #_sourceLocation) throws {
        var seen = Set<String>()
        for name in names() {
            let url = watch.appendingPathComponent(name)
            guard FS.getXattr(url, name: FS.roleXattr) == "output", let parent = FS.getXattr(url, name: FS.itemXattr) else { continue }
            let key = "\(parent):\(name.fileExtension.lowercased())"
            #expect(!seen.contains(key), "duplicate output \(key) (\(name))", sourceLocation: sourceLocation)
            seen.insert(key)
        }
    }
}
