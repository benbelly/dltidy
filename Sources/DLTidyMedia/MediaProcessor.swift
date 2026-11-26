import DLTidyKit
import Foundation

/// Probing and conversion of images and video through `magick`, `ffmpeg`, `ffprobe` and
/// AVFoundation (HDR export). Every external process goes through `ToolRunning`.
public struct MediaProcessor: MediaProcessing {
    public static let requiredTools = ["magick", "ffmpeg", "ffprobe"]

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp", "gif", "avif", "jp2", "dng",
    ]
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "mts", "m2ts",
    ]

    /// `ext` is lowercased and has no leading dot.
    public static func isMediaExtension(_ ext: String) -> Bool {
        imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    // Timeouts (suspending clock, enforced by the tool runner).
    static let probeTimeout: Duration = .seconds(30)
    static let imageTimeout: Duration = .seconds(120)
    static let remuxTimeout: Duration = .seconds(15 * 60)
    static let maxEncodeSeconds = 3.0 * 3600
    static let maxSourceBytes: Int64 = 20 << 30
    static let maxSourceSeconds = 2.0 * 3600
    static let longEncodeSeconds = 60.0
    static let gifMaxDuration = 10.0
    let tools: any ToolRunning
    let maxGIFBytes: Int64
    /// Directory holding the ImageMagick `policy.xml`; default `<app>/Contents/Resources/magick`.
    let policyDirectory: URL

    public init(tools: any ToolRunning = ToolRunner(), policyDirectory: URL? = nil) {
        self.init(tools: tools, maxGIFBytes: 25 << 20, policyDirectory: policyDirectory)
    }

    init(tools: any ToolRunning, maxGIFBytes: Int64, policyDirectory: URL? = nil) {
        self.tools = tools
        self.maxGIFBytes = maxGIFBytes
        self.policyDirectory = policyDirectory ?? MagickPolicy.defaultDirectory
    }

    /// nil when the ImageMagick policy is present; otherwise why not. Health and `doctor` report it.
    public func policyProblem() -> String? { MagickPolicy.problem(in: policyDirectory) }

    static func encodeTimeout(duration: Double?) -> Duration {
        let seconds = min(max(15.0 * 60, 6 * (duration ?? 0)), maxEncodeSeconds)
        return .seconds(seconds)
    }

    // MARK: - Planning

    public func plannedOutputs(info: MediaInfo, sourceExtension: String, isLivePhotoVideo: Bool) -> [OutputFormat] {
        if isLivePhotoVideo { return [] }
        let ext = sourceExtension.lowercased()
        switch info.kind {
        case .stillImage:
            var out: [OutputFormat] = []
            if ext != "png" { out.append(.png) }
            if ext != "jpg" && ext != "jpeg" { out.append(.jpg) }
            return out
        case .video, .animatedImage:
            var out: [OutputFormat] = []
            if ext != "mp4" { out.append(.mp4) }
            if let d = info.durationSeconds, d <= Self.gifMaxDuration, ext != "gif" { out.append(.gif) }
            return out
        }
    }

    // MARK: - Tool helper

    /// Runs a tool. Every `magick` call runs under the policy in `policyDirectory` and throws `.toolMissing("magick policy")` without it. Maps a missing tool to
    /// `.toolMissing` and a timeout to `.timeout`.
    func run(_ tool: String, _ args: [String], cwd: URL? = nil, timeout: Duration, outputLimit: Int = 1 << 20) async throws -> ToolResult {
        let environment = tool == "magick" ? try MagickPolicy.environment(directory: policyDirectory) : [:]
        let result: ToolResult
        do {
            result = try await tools.run(tool, args, cwd: cwd, environment: environment, timeout: timeout, outputLimit: outputLimit)
        } catch let ToolError.notFound(name) {
            throw MediaError.toolMissing(name)
        } catch let ToolError.spawnFailed(name, code) {
            throw MediaError.failed("cannot start \(name): errno \(code)")
        } catch let ToolError.environmentUnsupported(name) {
            throw MediaError.failed("tool runner cannot apply the environment for \(name)")
        }
        if result.timedOut { throw MediaError.timeout("\(tool) exceeded its time limit") }
        return result
    }

    static func tail(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.suffix(400))
    }
}
