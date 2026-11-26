import DLTidyKit
import Foundation
import Testing
@testable import DLTidyMedia

@Suite struct PlanningTests {
    let p = MediaProcessor()
    func plan(_ kind: MediaKind, _ dur: Double? = nil, _ ext: String, live: Bool = false) -> [OutputFormat] {
        p.plannedOutputs(info: MediaInfo(kind: kind, durationSeconds: dur), sourceExtension: ext, isLivePhotoVideo: live)
    }

    @Test func stills() {
        #expect(plan(.stillImage, nil, "heic") == [.png, .jpg])
        #expect(plan(.stillImage, nil, "PNG") == [.jpg])
        #expect(plan(.stillImage, nil, "jpg") == [.png])
        #expect(plan(.stillImage, nil, "jpeg") == [.png])
        #expect(plan(.stillImage, nil, "gif") == [.png, .jpg])
    }

    @Test func videos() {
        #expect(plan(.video, 3, "mov") == [.mp4, .gif])
        #expect(plan(.video, 10.0, "mov") == [.mp4, .gif])
        #expect(plan(.video, 10.01, "mov") == [.mp4])
        #expect(plan(.video, nil, "mkv") == [.mp4])
        #expect(plan(.video, 3, "mp4") == [.gif])
        #expect(plan(.video, 30, "mp4") == [])
        #expect(plan(.animatedImage, 0.3, "gif") == [.mp4])
        #expect(plan(.animatedImage, 0.3, "webp") == [.mp4, .gif])
    }

    @Test func livePhotoVideoGetsNothing() {
        #expect(plan(.video, 3, "mov", live: true) == [])
    }

    @Test func extensions() {
        #expect(MediaProcessor.isMediaExtension("heic"))
        #expect(MediaProcessor.isMediaExtension("mkv"))
        #expect(!MediaProcessor.isMediaExtension("pdf"))
        #expect(!MediaProcessor.isMediaExtension("ts"))
        #expect(MediaProcessor.requiredTools == ["magick", "ffmpeg", "ffprobe"])
    }

    @Test func encodeTimeoutRule() {
        #expect(MediaProcessor.encodeTimeout(duration: 10) == .seconds(900))
        #expect(MediaProcessor.encodeTimeout(duration: 600) == .seconds(3600))
        #expect(MediaProcessor.encodeTimeout(duration: 7200) == .seconds(10800))
    }
}

@Suite struct ErrorTests {
    @Test func notMediaRunsNoTools() async throws {
        let f = try await FixtureStore.shared.get()
        let rec = RecordingRunner()
        let p = MediaProcessor(tools: rec)
        for (url, ext) in [(f.pdf, "pdf"), (f.txt, "txt")] {
            await #expect(throws: MediaError.notMedia) { _ = try await p.probe(url, sourceExtension: ext) }
        }
        #expect(rec.calls.isEmpty)
    }

    @Test func corruptFilesAreUnreadable() async throws {
        let f = try await FixtureStore.shared.get()
        let p = MediaProcessor()
        do { _ = try await p.probe(f.corruptJPG, sourceExtension: "jpg"); Issue.record("no throw") }
        catch MediaError.unreadable {}
        do { _ = try await p.probe(f.corruptMP4, sourceExtension: "mp4"); Issue.record("no throw") }
        catch MediaError.unreadable {}
    }

    @Test func truncatedJPEGIsUnreadable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trunc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let full = dir.appendingPathComponent("full.jpg")
        let r = try await ToolRunner().run("magick", ["-size", "640x480", "plasma:", "-quality", "90", full.path], timeout: .seconds(60))
        #expect(r.succeeded)
        let data = try Data(contentsOf: full)
        let cut = dir.appendingPathComponent("in.jpg")
        try data.prefix(data.count / 2).write(to: cut)
        let p = MediaProcessor()
        _ = try await p.probe(full, sourceExtension: "jpg")
        do { _ = try await p.probe(cut, sourceExtension: "jpg"); Issue.record("truncated jpg passed probe") }
        catch MediaError.unreadable {}
    }

    @Test func missingToolMapsToToolMissing() async throws {
        let f = try await FixtureStore.shared.get()
        let p = MediaProcessor(tools: MissingToolRunner())
        await #expect(throws: MediaError.toolMissing("ffprobe")) { _ = try await p.probe(f.h264MOV, sourceExtension: "mov") }
        await #expect(throws: MediaError.toolMissing("magick")) { _ = try await p.probe(f.photoJPG, sourceExtension: "jpg") }
    }

    @Test func timeoutMapsToTimeout() async throws {
        let f = try await FixtureStore.shared.get()
        let p = MediaProcessor(tools: TimedOutRunner())
        do { _ = try await p.probe(f.h264MOV, sourceExtension: "mov"); Issue.record("no throw") }
        catch MediaError.timeout(_) {}
        let dir = try scratch()
        let input = try stage(f.photoJPG, in: dir)
        do {
            try await p.convert(input: input, info: MediaInfo(kind: .stillImage, width: 120, height: 80), to: .png,
                                output: dir.appendingPathComponent("o.png"), workDir: dir, allowLongEncode: true)
            Issue.record("no throw")
        } catch MediaError.timeout(_) {}
    }

    @Test func probeAndConvertTimeoutsFollowTheRules() async throws {
        let f = try await FixtureStore.shared.get()
        let rec = RecordingRunner()
        let p = MediaProcessor(tools: rec)
        let dir = try scratch()
        let input = try stage(f.h264MOV, in: dir)
        let info = try await p.probe(input, sourceExtension: "mov")
        try await p.convert(input: input, info: info, to: .mp4, output: dir.appendingPathComponent("o.mp4"),
                            workDir: dir, allowLongEncode: false)
        let ffmpegCall = try #require(rec.calls.first { $0.tool == "ffmpeg" })
        #expect(rec.calls.first?.timeout == .seconds(30))
        #expect(ffmpegCall.timeout == .seconds(15 * 60))
    }

    @Test func longReencodeIsDeferredAndHugeIsRefused() async throws {
        let f = try await FixtureStore.shared.get()
        let p = MediaProcessor()
        let dir = try scratch()
        let input = try stage(f.hevcMOV, in: dir)   // HEVC forces the re-encode path
        let out = dir.appendingPathComponent("o.mp4")
        var info = try await p.probe(input, sourceExtension: "mov")
        info.durationSeconds = 120
        do {
            try await p.convert(input: input, info: info, to: .mp4, output: out, workDir: dir, allowLongEncode: false)
            Issue.record("no throw")
        } catch MediaError.deferred(_) {}
        info.durationSeconds = 7300
        await #expect(throws: MediaError.failed("too large")) {
            try await p.convert(input: input, info: info, to: .mp4, output: out, workDir: dir, allowLongEncode: true)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func oversizedGifIsDiscarded() async throws {
        let f = try await FixtureStore.shared.get()
        let p = MediaProcessor(tools: ToolRunner(), maxGIFBytes: 1000)
        let dir = try scratch()
        let input = try stage(f.h264MOV, in: dir)
        let info = try await p.probe(input, sourceExtension: "mov")
        let out = dir.appendingPathComponent("o.gif")
        await #expect(throws: MediaError.outputTooLarge) {
            try await p.convert(input: input, info: info, to: .gif, output: out, workDir: dir, allowLongEncode: true)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}

@Suite struct ProbeTests {
    let p = MediaProcessor()

    @Test func stillsAndHEIC() async throws {
        let f = try await FixtureStore.shared.get()
        let jpg = try await p.probe(f.photoJPG, sourceExtension: "jpg")
        #expect(jpg.kind == .stillImage)
        let heic = try await p.probe(f.photoHEIC, sourceExtension: "heic")
        #expect(heic.kind == .stillImage)
        #expect(heic.width != nil && heic.height != nil)
    }

    @Test func animated() async throws {
        let f = try await FixtureStore.shared.get()
        for (url, ext) in [(f.animGIF, "gif"), (f.animWEBP, "webp")] {
            let info = try await p.probe(url, sourceExtension: ext)
            #expect(info.kind == .animatedImage)
            #expect(abs((info.durationSeconds ?? 0) - 0.3) < 0.05)
            #expect(info.width == 100 && info.height == 60)
        }
    }

    @Test func videos() async throws {
        let f = try await FixtureStore.shared.get()
        let h264 = try await p.probe(f.h264MOV, sourceExtension: "mov")
        #expect(h264.kind == .video && !h264.isHDR)
        #expect(abs((h264.durationSeconds ?? 0) - 3) < 0.3)
        #expect(h264.width == 320 && h264.height == 240)
        #expect(try await p.probe(f.hevcMOV, sourceExtension: "mov").isHDR == false)
        let hdr = try await p.probe(f.hdrMOV, sourceExtension: "mov")
        #expect(hdr.isHDR)
        let mkv = try await p.probe(f.mkv, sourceExtension: "mkv")
        #expect((mkv.durationSeconds ?? 0) > 11)
    }
}

@Suite struct StillConversionTests {
    let p = MediaProcessor()

    func convert(_ src: URL, ext: String, to format: OutputFormat) async throws -> URL {
        let dir = try scratch()
        let input = try stage(src, in: dir)
        let info = try await p.probe(input, sourceExtension: ext)
        let out = dir.appendingPathComponent("out." + format.rawValue)
        try await p.convert(input: input, info: info, to: format, output: out, workDir: dir, allowLongEncode: true)
        return out
    }

    @Test func heicToPngAndJpg() async throws {
        let f = try await FixtureStore.shared.get()
        let png = try await convert(f.photoHEIC, ext: "heic", to: .png)
        let jpg = try await convert(f.photoHEIC, ext: "heic", to: .jpg)
        #expect(try await identify(png, "%m") == "PNG")
        #expect(try await identify(jpg, "%m") == "JPEG")
        #expect(try await identify(png, "%w") == (try await identify(jpg, "%w")))
    }

    @Test func orientationApplied() async throws {
        let f = try await FixtureStore.shared.get()
        // Stored 120x80 with orientation right-top: displayed 80x120.
        let png = try await convert(f.photoJPG, ext: "jpg", to: .png)
        #expect(try await identify(png, "%wx%h") == "80x120")
    }

    @Test func gpsKeptOnJpgFromHEIC() async throws {
        let f = try await FixtureStore.shared.get()
        let src = try await identify(f.photoJPG, "%[exif:GPSLatitude]")
        try #require(!src.isEmpty, "fixture lacks GPS")
        let heic = try await identify(f.photoHEIC, "%[exif:GPSLatitude]")
        try #require(!heic.isEmpty, "sips dropped GPS in the fixture")
        let jpg = try await convert(f.photoHEIC, ext: "heic", to: .jpg)
        #expect(try await identify(jpg, "%[exif:GPSLatitude]") == heic)
    }

    @Test func alphaFlattenedToWhiteOnJpg() async throws {
        let f = try await FixtureStore.shared.get()
        let jpg = try await convert(f.alphaPNG, ext: "png", to: .jpg)
        let px = try await pixel(jpg, x: 2, y: 2)
        #expect(px.count == 3 && px.allSatisfy { $0 >= 250 }, "corner pixel \(px)")
        #expect(try await identify(jpg, "%A") != "Blend")
    }

    @Test func alphaKeptOnPng() async throws {
        let f = try await FixtureStore.shared.get()
        let png = try await convert(f.photoHEIC, ext: "heic", to: .png)
        #expect(size(of: png) > 0)
    }

    @Test func animatedGifFirstFrameForStillOutputIsRejected() async throws {
        let f = try await FixtureStore.shared.get()
        let dir = try scratch()
        let input = try stage(f.animGIF, in: dir)
        let info = try await p.probe(input, sourceExtension: "gif")
        await #expect(throws: MediaError.failed("png output needs a still image")) {
            try await p.convert(input: input, info: info, to: .png, output: dir.appendingPathComponent("o.png"),
                                workDir: dir, allowLongEncode: true)
        }
    }
}

@Suite struct VideoConversionTests {
    func run(_ src: URL, ext: String, formats: [OutputFormat], tools: any ToolRunning = ToolRunner()) async throws
        -> (dir: URL, outs: [OutputFormat: URL]) {
        let p = MediaProcessor(tools: tools)
        let dir = try scratch()
        let input = try stage(src, in: dir)
        let info = try await p.probe(input, sourceExtension: ext)
        var outs: [OutputFormat: URL] = [:]
        for fmt in formats {
            let out = dir.appendingPathComponent("out." + fmt.rawValue)
            try await p.convert(input: input, info: info, to: fmt, output: out, workDir: dir, allowLongEncode: true)
            outs[fmt] = out
        }
        return (dir, outs)
    }

    @Test func h264RemuxKeepsStreamsAndMetadata() async throws {
        let f = try await FixtureStore.shared.get()
        let rec = RecordingRunner()
        let (_, outs) = try await run(f.h264MOV, ext: "mov", formats: [.mp4, .gif], tools: rec)
        let mp4 = try await ffprobeJSON(try #require(outs[.mp4]))
        #expect(mp4.videoStream?.codec_name == "h264")
        #expect(mp4.audioStreams.first?.codec_name == "aac")
        #expect(abs((mp4.duration ?? 0) - 3) < 0.3)
        let ff = try #require(rec.calls.first { $0.tool == "ffmpeg" })
        #expect(ff.args.contains("copy") && ff.args.contains("+faststart") && ff.args.contains("-map_metadata"))
        // faststart: moov before mdat
        let head = try Data(contentsOf: try #require(outs[.mp4])).prefix(4096)
        #expect(head.range(of: Data("moov".utf8)) != nil)
        // gif
        let gif = try #require(outs[.gif])
        let frames = Int(try await exec("magick", ["identify", "-format", "%n\n", gif.path]).split(separator: "\n").first ?? "0") ?? 0
        #expect(frames > 10)
        #expect(try await identify(gif, "%w") == "320")
    }

    @Test func hevcIsReencodedToH264Yuv420p() async throws {
        let f = try await FixtureStore.shared.get()
        let rec = RecordingRunner()
        let (_, outs) = try await run(f.hevcMOV, ext: "mov", formats: [.mp4], tools: rec)
        let v = try await ffprobeJSON(try #require(outs[.mp4]))
        #expect(v.videoStream?.codec_name == "h264")
        #expect(v.videoStream?.pix_fmt == "yuv420p")
        #expect((v.videoStream?.width ?? 1) % 2 == 0 && (v.videoStream?.height ?? 1) % 2 == 0)
        #expect(v.audioStreams.first?.codec_name == "aac")
        #expect(rec.calls.contains { $0.args.contains("libx264") && $0.args.contains("20") })
    }

    @Test func mkvLongClipGetsMp4Only() async throws {
        let f = try await FixtureStore.shared.get()
        let p = MediaProcessor()
        let dir = try scratch()
        let input = try stage(f.mkv, in: dir)
        let info = try await p.probe(input, sourceExtension: "mkv")
        let planned = p.plannedOutputs(info: info, sourceExtension: "mkv", isLivePhotoVideo: false)
        #expect(planned == [.mp4])
        let out = dir.appendingPathComponent("o.mp4")
        try await p.convert(input: input, info: info, to: .mp4, output: out, workDir: dir, allowLongEncode: false)
        let v = try await ffprobeJSON(out)
        #expect(v.videoStream?.codec_name == "h264")
        #expect(abs((v.duration ?? 0) - 12) < 0.5)
    }

    @Test func hdrBecomesSdr() async throws {
        let f = try await FixtureStore.shared.get()
        let (dir, outs) = try await run(f.hdrMOV, ext: "mov", formats: [.mp4, .gif])
        let mp4 = try await ffprobeJSON(try #require(outs[.mp4]))
        #expect(mp4.videoStream?.codec_name == "h264")
        #expect(!mp4.isHDR, "transfer \(mp4.videoStream?.color_transfer ?? "nil")")
        #expect(mp4.videoStream?.color_transfer != "arib-std-b67" && mp4.videoStream?.color_transfer != "smpte2084")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sdr.mp4").path))
        #expect(size(of: try #require(outs[.gif])) > 0)
        #expect(abs((mp4.duration ?? 0) - 3) < 0.3)
    }

    @Test func hdrGifAloneBuildsItsOwnSdrSource() async throws {
        let f = try await FixtureStore.shared.get()
        let (dir, outs) = try await run(f.hdrMOV, ext: "mov", formats: [.gif])
        #expect(size(of: try #require(outs[.gif])) > 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sdr.mp4").path))
    }

    @Test func animatedGifAndWebpToMp4() async throws {
        let f = try await FixtureStore.shared.get()
        let (_, g) = try await run(f.animGIF, ext: "gif", formats: [.mp4])
        let gv = try await ffprobeJSON(try #require(g[.mp4]))
        #expect(gv.videoStream?.codec_name == "h264")
        #expect(gv.audioStreams.isEmpty)
        let (_, w) = try await run(f.animWEBP, ext: "webp", formats: [.mp4, .gif])
        let wv = try await ffprobeJSON(try #require(w[.mp4]))
        #expect(wv.videoStream?.codec_name == "h264")
        #expect(wv.audioStreams.isEmpty)
        #expect(try await identify(try #require(w[.gif]), "%m") == "GIF")
    }

    @Test func framePipeFallbackWhenFfmpegCannotDecode() async throws {
        // Simulate an ffmpeg that fails on the image input; the magick route must still produce an mp4.
        struct FailFirstFfmpeg: ToolRunning {
            let inner = ToolRunner()
            func run(_ tool: String, _ args: [String], cwd: URL?, timeout: Duration, outputLimit: Int) async throws -> ToolResult {
                if tool == "ffmpeg", args.contains(where: { $0.hasSuffix("in.webp") }) {
                    return try await inner.run("/bin/sh", ["-c", "echo decode failure >&2; exit 1"], cwd: nil, timeout: .seconds(10), outputLimit: 1000)
                }
                return try await inner.run(tool, args, cwd: cwd, timeout: timeout, outputLimit: outputLimit)
            }
            func run(_ tool: String, _ args: [String], cwd: URL?, environment: [String: String], timeout: Duration,
                     outputLimit: Int) async throws -> ToolResult {
                if !environment.isEmpty {
                    return try await inner.run(tool, args, cwd: cwd, environment: environment, timeout: timeout, outputLimit: outputLimit)
                }
                return try await run(tool, args, cwd: cwd, timeout: timeout, outputLimit: outputLimit)
            }
        }
        let f = try await FixtureStore.shared.get()
        let (dir, outs) = try await run(f.animWEBP, ext: "webp", formats: [.mp4], tools: FailFirstFfmpeg())
        let v = try await ffprobeJSON(try #require(outs[.mp4]))
        #expect(v.videoStream?.codec_name == "h264")
        #expect(abs((v.duration ?? 0) - 0.3) < 0.2)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("frames-") }
        #expect(left.isEmpty)
    }
}

@Suite struct HDRMetadataTests {
    @Test func locationTagSurvivesHDRExport() async throws {
        let f = try await FixtureStore.shared.get()
        let p = MediaProcessor()
        let dir = try scratch()
        let input = try stage(f.hdrMOV, in: dir)
        let info = try await p.probe(input, sourceExtension: "mov")
        let out = dir.appendingPathComponent("o.mp4")
        try await p.convert(input: input, info: info, to: .mp4, output: out, workDir: dir, allowLongEncode: true)
        let tags = try await exec("ffprobe", ["-v", "error", "-show_entries", "format_tags", out.path])
        #expect(tags.contains("37.3349"), "format tags: \(tags)")
    }
}

@Suite struct ImageMagickPolicyTests {
    /// Probe, then convert to every planned still output; returns the outputs' identify formats.
    func probeAndConvert(_ input: URL, ext: String, tools: any ToolRunning) async throws -> [String] {
        let p = MediaProcessor(tools: tools)
        let info = try await p.probe(input, sourceExtension: ext)
        #expect(info.kind == .stillImage)
        var formats: [String] = []
        for format in p.plannedOutputs(info: info, sourceExtension: ext, isLivePhotoVideo: false) {
            let out = input.deletingLastPathComponent().appendingPathComponent("out.\(format.rawValue)")
            try await p.convert(input: input, info: info, to: format, output: out,
                                workDir: input.deletingLastPathComponent(), allowLongEncode: true)
            formats.append(try await identify(out, "%m"))
        }
        return formats
    }

    @Test("SVG and PostScript named .jpg are rejected; no output copies a local image")
    func svgAndPostScriptAsJpgRejected() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appendingPathComponent("private.png")
        try await exec("magick", ["-size", "64x32", "xc:red", secret.path])
        let payloads = [
            "svg-relative": """
                <?xml version="1.0"?><svg width="64" height="32" xmlns="http://www.w3.org/2000/svg" \
                xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="private.png" width="64" height="32"/></svg>
                """,
            "svg-absolute": """
                <?xml version="1.0"?><svg width="64" height="32" xmlns="http://www.w3.org/2000/svg" \
                xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="\(secret.path)" width="64" height="32"/></svg>
                """,
            "postscript": "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 100 100\nnewpath 0 0 moveto 100 0 lineto 100 100 lineto closepath fill\nshowpage\n",
        ]
        let p = MediaProcessor()
        for (name, body) in payloads {
            let stage = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: secret, to: stage.appendingPathComponent("private.png"))
            let input = stage.appendingPathComponent("in.jpg")
            try Data(body.utf8).write(to: input)
            do {
                _ = try await p.probe(input, sourceExtension: "jpg")
                Issue.record("\(name): probe accepted it")
            } catch MediaError.unreadable {
            } catch MediaError.notMedia {
            }
            // Even without the probe, conversion must not decode it.
            let out = stage.appendingPathComponent("out.png")
            await #expect(throws: (any Error).self, "\(name): converted") {
                try await p.convert(input: input, info: MediaInfo(kind: .stillImage, width: 64, height: 32), to: .png,
                                    output: out, workDir: stage, allowLongEncode: true)
            }
            #expect(!FileManager.default.fileExists(atPath: out.path), "\(name): output written")
        }
    }

    @Test("every raster format in the image extension list still converts under the policy")
    func everyListedFormatConverts() async throws {
        let f = try await FixtureStore.shared.get()
        let rec = RecordingRunner()
        var failures: [String] = []
        let required = ["png", "jpg", "jpeg", "tif", "tiff", "bmp", "webp", "gif", "avif", "heic", "heif"]
        for ext in required {
            let dir = try scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let input = dir.appendingPathComponent("in.\(ext)")
            try await exec("magick", [f.photoJPG.path, input.path])   // built without the policy
            do {
                let formats = try await probeAndConvert(input, ext: ext, tools: rec)
                let expected = [ext == "png" ? nil : "PNG", (ext == "jpg" || ext == "jpeg") ? nil : "JPEG"].compactMap { $0 }
                if formats != expected { failures.append("\(ext): \(formats)") }
            } catch {
                failures.append("\(ext): \(error)")
            }
        }
        #expect(failures.isEmpty, "\(failures)")
        // JP2 and DNG are listed but need openjpeg / a raw library, which this ImageMagick may lack:
        // when the tool decodes jp2 without the policy, it must still convert with it.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jp2 = dir.appendingPathComponent("in.jp2")
        _ = try? await exec("sips", ["-s", "format", "jp2", f.alphaPNG.path, "--out", jp2.path])
        if FileManager.default.fileExists(atPath: jp2.path), (try? await exec("magick", ["identify", jp2.path])) != nil {
            let formats = try await probeAndConvert(jp2, ext: "jp2", tools: rec)
            #expect(formats == ["PNG", "JPEG"])
        }
        let magickCalls = rec.calls.filter { $0.tool == "magick" }
        #expect(!magickCalls.isEmpty)
        #expect(magickCalls.allSatisfy { $0.environment["MAGICK_CONFIGURE_PATH"] != nil })
    }

    @Test("the policy refuses @file indirection, generators and delegates")
    func policyRefusesIndirection() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png")
        try await exec("magick", ["-size", "8x8", "xc:blue", png.path])
        let env = try MagickPolicy.environment()
        let policy = try String(contentsOf: URL(fileURLWithPath: env["MAGICK_CONFIGURE_PATH"]!).appendingPathComponent("policy.xml"),
                                encoding: .utf8)
        #expect(policy == MagickPolicy.xml)
        for args in [["@" + png.path, "null:"], ["xc:red", "null:"], ["-size", "8x8", "gradient:", "null:"],
                     ["text:" + png.path, "null:"], [png.path, "ps:" + dir.appendingPathComponent("o.ps").path]] {
            let r = try await ToolRunner().run("magick", args, cwd: dir, environment: env, timeout: .seconds(30), outputLimit: 1 << 16)
            #expect(!r.succeeded, "\(args) succeeded")
        }
        let ok = try await ToolRunner().run("magick", [png.path, "null:"], cwd: dir, environment: env, timeout: .seconds(30), outputLimit: 1 << 16)
        #expect(ok.succeeded, "\(String(decoding: ok.stderr, as: UTF8.self))")
    }

    @Test("a policy file changed on disk is replaced before the next magick call")
    func tamperedPolicyIsReplaced() throws {
        let first = URL(fileURLWithPath: try MagickPolicy.environment()["MAGICK_CONFIGURE_PATH"]!)
        let file = first.appendingPathComponent("policy.xml")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("<policymap/>".utf8).write(to: file)
        let second = URL(fileURLWithPath: try MagickPolicy.environment()["MAGICK_CONFIGURE_PATH"]!)
        #expect(try Data(contentsOf: second.appendingPathComponent("policy.xml")) == Data(MagickPolicy.xml.utf8))
    }

    @Test("images over 100 MP fail probe as tooLarge, from identify output or the 16 KP limit")
    func oversizeImagesAreTooLarge() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = MediaProcessor()
        // 110 MP: inside the policy's 16 KP width/height, above the 100 MP cap.
        let big = dir.appendingPathComponent("in.png")
        try bilevelPNG(width: 11_000, height: 10_000).write(to: big)
        do { _ = try await p.probe(big, sourceExtension: "png"); Issue.record("110 MP accepted") }
        catch MediaError.tooLarge {}
        // 900 MP (the review's bomb): ImageMagick refuses the 30000 px width.
        let bomb = dir.appendingPathComponent("bomb", isDirectory: true)
        try FileManager.default.createDirectory(at: bomb, withIntermediateDirectories: true)
        let bombFile = bomb.appendingPathComponent("in.png")
        try bilevelPNG(width: 30_000, height: 30_000).write(to: bombFile)
        let start = ContinuousClock.now
        do { _ = try await p.probe(bombFile, sourceExtension: "png"); Issue.record("900 MP accepted") }
        catch MediaError.tooLarge {}
        #expect(ContinuousClock.now - start < .seconds(10))
        // 99 MP passes the cap.
        let ok = dir.appendingPathComponent("ok", isDirectory: true)
        try FileManager.default.createDirectory(at: ok, withIntermediateDirectories: true)
        let okFile = ok.appendingPathComponent("in.png")
        try bilevelPNG(width: 9_900, height: 10_000).write(to: okFile)
        let info = try await p.probe(okFile, sourceExtension: "png")
        #expect(info.width == 9_900 && info.height == 10_000)
    }
}
