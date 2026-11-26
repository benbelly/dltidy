import Foundation

// Contracts between DLTidyCore (orchestration) and the two leaf modules, DLTidyMedia and
// DLTidyNaming. Core depends only on these protocols; the executable wires the implementations.
// Leaf modules never touch ~/Downloads: they read a staged clone and write into staging.

// MARK: - Infrastructure

public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

public protocol Notifier: Sendable {
    func post(title: String, body: String)
}

// MARK: - Media

public enum MediaKind: String, Sendable, Codable, Equatable {
    case stillImage
    case animatedImage   // animated GIF/WebP; handled as video (gets mp4, gif if short)
    case video
}

public struct MediaInfo: Sendable, Equatable {
    public var kind: MediaKind
    public var durationSeconds: Double?
    public var isHDR: Bool
    public var width: Int?
    public var height: Int?

    public init(kind: MediaKind, durationSeconds: Double? = nil, isHDR: Bool = false, width: Int? = nil, height: Int? = nil) {
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.isHDR = isHDR
        self.width = width
        self.height = height
    }
}

public enum OutputFormat: String, Sendable, Codable, CaseIterable, Equatable {
    case png, jpg, mp4, gif
}

public enum MediaError: Error, Sendable, Equatable {
    /// The file is not an image or video this app handles. Not an error for the item.
    case notMedia
    /// The file looks like media but does not decode (readiness rule 8: retry later).
    case unreadable(String)
    /// The file declares dimensions above the decode cap. Final: no retry.
    case tooLarge(String)
    /// A required external tool is not on PATH.
    case toolMissing(String)
    case timeout(String)
    case failed(String)
    /// GIF output above 25 MB; discarded.
    case outputTooLarge
    /// Work needs a long re-encode and `allowLongEncode` was false (battery / thermal).
    case deferred(String)
}

public protocol MediaProcessing: Sendable {
    /// Inspects the staged clone. Throws `.notMedia` for non-media files, `.unreadable` for media
    /// that fails to decode, `.tooLarge` for images above the pixel cap.
    func probe(_ file: URL, sourceExtension: String) async throws -> MediaInfo

    /// Outputs to create, in the order `convert` must be called. Pure.
    /// Rules: still image → png unless source is png, jpg unless source is jpg/jpeg.
    /// video/animatedImage → mp4 unless source is mp4; gif if duration ≤ 10.0 s and source is
    /// not itself a gif. `isLivePhotoVideo` → [].
    func plannedOutputs(info: MediaInfo, sourceExtension: String, isLivePhotoVideo: Bool) -> [OutputFormat]

    /// Writes `output` (a path inside staging). Temporary files go in `workDir`; calls for one
    /// item share a `workDir` and may reuse intermediates there (e.g. an SDR mp4 for the gif).
    func convert(input: URL, info: MediaInfo, to format: OutputFormat, output: URL,
                 workDir: URL, allowLongEncode: Bool) async throws
}

// MARK: - Naming

public enum NameClass: Sendable, Equatable {
    case generic      // rename from content
    case meaningful   // keep
    case unclear      // ask the model about the name alone
}

public protocol NameRuling: Sendable {
    /// Classifies a filename (with extension). Strips duplicate markers like " (1)" / " copy 2" first.
    func classify(filename: String) -> NameClass
    /// Stem with extension and duplicate markers removed; used for stem grouping.
    func baseStem(of filename: String) -> String
    /// Turns model output into a kebab-case slug, or nil if it fails the slug rules.
    func slug(from raw: String) -> String?
}

public enum NamingPayload: Sendable, Equatable {
    case image(jpeg: Data)   // ≤ 768 px long edge, ≤ 300 KB
    case text(String)        // ≤ 2,048 bytes UTF-8
}

public protocol ContentExtracting: Sendable {
    /// Returns nil when the type is not nameable from content or extraction fails.
    func extract(from file: URL, sourceExtension: String) async -> NamingPayload?
}

public enum Confidence: String, Sendable, Codable, Equatable {
    case high, medium, low
}

public struct NameSuggestion: Sendable, Equatable {
    public var name: String
    public var confidence: Confidence
    public init(name: String, confidence: Confidence) {
        self.name = name
        self.confidence = confidence
    }
}

public struct APIUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Outcome of exactly one HTTP request. Implementations never retry.
public enum APIResult<T: Sendable & Equatable>: Sendable, Equatable {
    case ok(T, APIUsage)
    /// 400/404/413/422, refusal, max_tokens stop, unparseable output. Do not retry.
    case final(reason: String, usage: APIUsage?)
    /// 5xx, 529, network error, timeout.
    case transient(reason: String)
    /// 429.
    case rateLimited(retryAfter: TimeInterval?)
    /// 401/402/403.
    case authFailure(status: Int)
}

public protocol NamingService: Sendable {
    /// One request: is this filename stem generic (true) or meaningful (false)?
    func classifyStem(_ stem: String, apiKey: String) async -> APIResult<Bool>
    /// One request: suggest a descriptive name for the content.
    func suggestName(for payload: NamingPayload, originalName: String, apiKey: String) async -> APIResult<NameSuggestion>
}
