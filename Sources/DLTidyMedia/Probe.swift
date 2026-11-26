import DLTidyKit
import Foundation

struct FFProbeOutput: Decodable {
    struct SideData: Decodable { var rotation: Double? }
    struct Stream: Decodable {
        var codec_type: String?
        var codec_name: String?
        var pix_fmt: String?
        var color_transfer: String?
        var width: Int?
        var height: Int?
        var duration: String?
        var tags: [String: String]?
        var side_data_list: [SideData]?
        var disposition: [String: Int]?
    }
    struct Format: Decodable { var duration: String? }
    var streams: [Stream]?
    var format: Format?

    var videoStream: Stream? {
        streams?.first { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }
    }
    var audioStreams: [Stream] { streams?.filter { $0.codec_type == "audio" } ?? [] }

    var duration: Double? {
        if let s = format?.duration, let d = Double(s), d.isFinite, d >= 0 { return d }
        if let s = videoStream?.duration, let d = Double(s), d.isFinite, d >= 0 { return d }
        return nil
    }

    var isHDR: Bool {
        let t = videoStream?.color_transfer
        return t == "arib-std-b67" || t == "smpte2084"
    }

    /// Display dimensions: width and height swap for a quarter-turn rotation tag.
    var displaySize: (Int, Int)? {
        guard let v = videoStream, let w = v.width, let h = v.height else { return nil }
        var rotation = v.side_data_list?.compactMap(\.rotation).first
        if rotation == nil, let tag = v.tags?["rotate"] { rotation = Double(tag) }
        if let r = rotation, Int(abs(r).rounded()) % 180 == 90 { return (h, w) }
        return (w, h)
    }
}

extension MediaProcessor {
    public func probe(_ file: URL, sourceExtension: String) async throws -> MediaInfo {
        let ext = sourceExtension.lowercased()
        if Self.imageExtensions.contains(ext) { return try await probeImage(file, ext: ext) }
        if Self.videoExtensions.contains(ext) { return try await probeVideo(file) }
        throw MediaError.notMedia
    }

    func ffprobe(_ file: URL) async throws -> FFProbeOutput {
        let r = try await run("ffprobe", ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", file.path],
                              timeout: Self.probeTimeout)
        guard r.status == 0 else { throw MediaError.unreadable("ffprobe: \(Self.tail(r.stderr))") }
        guard let out = try? JSONDecoder().decode(FFProbeOutput.self, from: r.stdout) else {
            throw MediaError.unreadable("ffprobe output not parseable")
        }
        return out
    }

    private func probeVideo(_ file: URL) async throws -> MediaInfo {
        let out = try await ffprobe(file)
        guard out.videoStream != nil else { throw MediaError.unreadable("no video stream") }
        let size = out.displaySize
        return MediaInfo(kind: .video, durationSeconds: out.duration, isHDR: out.isHDR, width: size?.0, height: size?.1)
    }

    /// One `identify` line per frame: "<frames> <w> <h> <delay in 1/100 s>".
    private func probeImage(_ file: URL, ext: String) async throws -> MediaInfo {
        let r = try await run("magick", ["identify", "-format", "%n %w %h %T\n", file.lastPathComponent],
                              cwd: file.deletingLastPathComponent(), timeout: Self.probeTimeout)
        guard r.status == 0 else {
            // The policy's width/height limits refuse an oversized canvas before identify prints it.
            let text = String(decoding: r.stderr, as: UTF8.self).lowercased()
            if text.contains("exceeds limit") || text.contains("exceeds user limit") {
                throw MediaError.tooLarge("identify: \(Self.tail(r.stderr))")
            }
            throw MediaError.unreadable("identify: \(Self.tail(r.stderr))")
        }
        let lines = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n")
        let rows = lines.map { $0.split(separator: " ").compactMap { Int($0) } }
        guard let first = rows.first, first.count == 4, first[1] > 0, first[2] > 0 else {
            throw MediaError.unreadable("identify output not parseable")
        }
        let (pixels, overflow) = first[1].multipliedReportingOverflow(by: first[2])
        if overflow || pixels > Self.maxImagePixels {
            throw MediaError.tooLarge("\(first[1])x\(first[2]) exceeds \(Self.maxImagePixels / 1_000_000) MP")
        }
        let animatable = ext == "gif" || ext == "webp"
        guard animatable, first[0] > 1 else {
            // identify reads headers only; a full decode catches a truncated file (readiness rule 8).
            let decode = try await run("magick", ["-regard-warnings", "\(file.lastPathComponent)[0]", "null:"],
                                       cwd: file.deletingLastPathComponent(), timeout: Self.probeTimeout)
            // ImageMagick exits 0 on a truncated JPEG and reports it as a warning; match those texts.
            let warnings = String(decoding: decode.stderr, as: UTF8.self).lowercased()
            let truncated = ["premature end", "corrupt", "truncat", "unexpected end", "insufficient image data"]
                .contains { warnings.contains($0) }
            guard decode.status == 0, !truncated else { throw MediaError.unreadable("decode: \(Self.tail(decode.stderr))") }
            return MediaInfo(kind: .stillImage, width: first[1], height: first[2])
        }
        // A delay of 0 plays at 10 cs in browsers.
        let centis = rows.filter { $0.count == 4 }.reduce(0) { $0 + ($1[3] > 0 ? $1[3] : 10) }
        return MediaInfo(kind: .animatedImage, durationSeconds: Double(centis) / 100, width: first[1], height: first[2])
    }
}
