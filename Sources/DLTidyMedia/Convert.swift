import DLTidyKit
import Foundation

extension MediaProcessor {
    public func convert(input: URL, info: MediaInfo, to format: OutputFormat, output: URL,
                        workDir: URL, allowLongEncode: Bool) async throws {
        let fm = FileManager.default
        do {
            switch format {
            case .png, .jpg:
                guard info.kind == .stillImage else { throw MediaError.failed("\(format.rawValue) output needs a still image") }
                try await convertStill(input: input, to: format, output: output, workDir: workDir)
            case .mp4:
                guard info.kind != .stillImage else { throw MediaError.failed("mp4 output needs a video") }
                try await convertMP4(input: input, info: info, output: output, workDir: workDir, allowLongEncode: allowLongEncode)
            case .gif:
                guard info.kind != .stillImage else { throw MediaError.failed("gif output needs a video") }
                try await convertGIF(input: input, info: info, output: output, workDir: workDir, allowLongEncode: allowLongEncode)
            }
        } catch {
            try? fm.removeItem(at: output)
            throw error
        }
    }

    // MARK: - Stills

    private func convertStill(input: URL, to format: OutputFormat, output: URL, workDir: URL) async throws {
        // Relative name with a frame selector; the staging directory never contains brackets in the name.
        var args = [input.lastPathComponent + "[0]", "-define", "registry:temporary-path=\(workDir.path)", "-auto-orient"]
        if format == .jpg {
            args += ["-background", "white", "-alpha", "remove", "-alpha", "off", "-quality", "90"]
        } else {
            args += ["-define", "png:compression-level=6"]
        }
        args.append(output.path)
        let r = try await run("magick", args, cwd: input.deletingLastPathComponent(), timeout: Self.imageTimeout)
        guard r.status == 0 else { throw MediaError.failed("magick: \(Self.tail(r.stderr))") }
        try requireOutput(output)
    }

    // MARK: - mp4

    private func convertMP4(input: URL, info: MediaInfo, output: URL, workDir: URL, allowLongEncode: Bool) async throws {
        let producedSDR = try await produceMP4(input: input, info: info, dest: output, workDir: workDir,
                                               allowLongEncode: allowLongEncode)
        if producedSDR && (info.isHDR || info.kind == .animatedImage) {
            // Keep an SDR intermediate for the gif.
            let keep = Self.intermediate(workDir)
            try? FileManager.default.removeItem(at: keep)
            try? FileManager.default.copyItem(at: output, to: keep)
        }
    }

    static func intermediate(_ workDir: URL) -> URL { workDir.appendingPathComponent("sdr.mp4") }

    /// Writes an mp4 to `dest`. Returns true when the result is an SDR re-encode (usable for the gif).
    func produceMP4(input: URL, info: MediaInfo, dest: URL, workDir: URL, allowLongEncode: Bool) async throws -> Bool {
        if info.kind == .animatedImage {
            try guardEncode(input: input, info: info, allowLongEncode: allowLongEncode)
            try await animatedToMP4(input: input, info: info, dest: dest, workDir: workDir)
            return true
        }
        let probed = try await ffprobe(input)
        if info.isHDR {
            try guardEncode(input: input, info: info, allowLongEncode: allowLongEncode)
            do {
                try await exportHDRToSDR(input: input, dest: dest, info: info)
                let check = try await ffprobe(dest)
                if check.isHDR { throw MediaError.failed("export kept HDR transfer") }
                return true
            } catch MediaError.timeout(let m) {
                throw MediaError.timeout(m)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                try await hevcRemux(input: input, dest: dest)
                return false
            }
        }
        if Self.canRemux(probed) {
            try await ffmpeg(["-i", input.path, "-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-map_metadata", "0",
                              "-movflags", "+faststart", dest.path], timeout: Self.remuxTimeout, dest: dest)
            return false
        }
        try guardEncode(input: input, info: info, allowLongEncode: allowLongEncode)
        try await ffmpeg(["-i", input.path, "-map", "0:v:0", "-map", "0:a?",
                          "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                          "-vf", Self.evenScale, "-c:a", "aac", "-b:a", "160k", "-map_metadata", "0",
                          "-movflags", "+faststart", dest.path],
                         timeout: Self.encodeTimeout(duration: info.durationSeconds), dest: dest)
        return true
    }

    static let evenScale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    static func canRemux(_ p: FFProbeOutput) -> Bool {
        guard let v = p.videoStream, v.codec_name == "h264", v.pix_fmt == "yuv420p" || v.pix_fmt == "yuvj420p" else { return false }
        return p.audioStreams.allSatisfy { $0.codec_name == "aac" }
    }

    private func hevcRemux(input: URL, dest: URL) async throws {
        try await ffmpeg(["-i", input.path, "-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-tag:v", "hvc1",
                          "-map_metadata", "0", "-movflags", "+faststart", dest.path],
                         timeout: Self.remuxTimeout, dest: dest)
    }

    /// Source over 20 GB or 2 h: refuse. Clip over 60 s without permission: defer.
    private func guardEncode(input: URL, info: MediaInfo, allowLongEncode: Bool) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? NSNumber)??.int64Value ?? 0
        if size > Self.maxSourceBytes || (info.durationSeconds ?? 0) > Self.maxSourceSeconds {
            throw MediaError.failed("too large")
        }
        if !allowLongEncode, (info.durationSeconds ?? 0) > Self.longEncodeSeconds {
            throw MediaError.deferred("re-encode of a clip over 60 s waits for AC power")
        }
    }

    // MARK: - Animated GIF / WebP

    private func animatedToMP4(input: URL, info: MediaInfo, dest: URL, workDir: URL) async throws {
        let encodeArgs = ["-an", "-r", "30", "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                          "-vf", Self.evenScale, "-movflags", "+faststart", dest.path]
        let timeout = Self.encodeTimeout(duration: info.durationSeconds)
        do {
            try await ffmpeg(["-i", input.path] + encodeArgs, timeout: timeout, dest: dest)
            return
        } catch MediaError.failed {
            // Older ffmpeg builds cannot decode animated WebP; fall through to the frame route.
        }
        let fm = FileManager.default
        let frames = workDir.appendingPathComponent("frames-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: frames, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: frames) }
        let r = try await run("magick", [input.lastPathComponent, "-define", "registry:temporary-path=\(workDir.path)",
                                         "-coalesce", "-background", "white", "-alpha", "remove", "-alpha", "off",
                                         frames.appendingPathComponent("f-%05d.png").path],
                              cwd: input.deletingLastPathComponent(), timeout: Self.imageTimeout)
        guard r.status == 0 else { throw MediaError.failed("magick coalesce: \(Self.tail(r.stderr))") }
        let count = (try? fm.contentsOfDirectory(atPath: frames.path).count) ?? 0
        guard count > 0 else { throw MediaError.failed("magick coalesce produced no frames") }
        var fps = 10.0
        if let d = info.durationSeconds, d > 0 { fps = min(max(Double(count) / d, 1), 60) }
        try await ffmpeg(["-framerate", String(format: "%.3f", fps), "-i", frames.appendingPathComponent("f-%05d.png").path]
                         + encodeArgs, timeout: timeout, dest: dest)
    }

    // MARK: - gif

    private func convertGIF(input: URL, info: MediaInfo, output: URL, workDir: URL, allowLongEncode: Bool) async throws {
        var source = input
        if info.isHDR || info.kind == .animatedImage {
            let sdr = Self.intermediate(workDir)
            if !FileManager.default.fileExists(atPath: sdr.path) {
                let ok = try await produceMP4(input: input, info: info, dest: sdr, workDir: workDir,
                                              allowLongEncode: allowLongEncode)
                if !ok { try? FileManager.default.removeItem(at: sdr) }
            }
            if FileManager.default.fileExists(atPath: sdr.path) { source = sdr }
        }
        let filter = "fps=12,scale='min(480,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5"
        try await ffmpeg(["-i", source.path, "-an", "-vf", filter, "-loop", "0", output.path],
                         timeout: Self.encodeTimeout(duration: info.durationSeconds), dest: output)
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size > maxGIFBytes {
            try? FileManager.default.removeItem(at: output)
            throw MediaError.outputTooLarge
        }
    }

    // MARK: - Shared

    func ffmpeg(_ args: [String], timeout: Duration, dest: URL) async throws {
        let r = try await run("ffmpeg", ["-nostdin", "-y", "-v", "error"] + args, timeout: timeout)
        guard r.status == 0 else { throw MediaError.failed("ffmpeg: \(Self.tail(r.stderr))") }
        try requireOutput(dest)
    }

    private func requireOutput(_ url: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
        guard size > 0 else { throw MediaError.failed("tool produced no output") }
    }
}
