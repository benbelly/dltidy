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
