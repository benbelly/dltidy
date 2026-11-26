import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DLTidyNaming
import DLTidyKit

private enum Fixtures {
    static func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dltidy-naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// RGBA bitmap; `noise` fills with random pixels, otherwise a gradient.
    static func bitmap(width: Int, height: Int, noise: Bool) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var rng = SystemRandomNumberGenerator()
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if noise {
                    pixels[i] = .random(in: 0...255, using: &rng)
                    pixels[i + 1] = .random(in: 0...255, using: &rng)
                    pixels[i + 2] = .random(in: 0...255, using: &rng)
                } else {
                    pixels[i] = UInt8(x * 255 / max(1, width - 1))
                    pixels[i + 1] = UInt8(y * 255 / max(1, height - 1))
                    pixels[i + 2] = 128
                }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func writeImage(_ image: CGImage, to url: URL, type: UTType, orientation: Int? = nil) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    static func dimensions(of jpeg: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func isJPEG(_ d: Data) -> Bool { d.starts(with: [0xFF, 0xD8, 0xFF]) }

    static func textPDF(_ text: String, at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    static func imagePDF(at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.draw(bitmap(width: 200, height: 260, noise: false), in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    static func video(at url: URL) async throws {
        let w = 320, h = 240
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            memset(CVPixelBufferGetBaseAddress(buf), Int32(i * 8), CVPixelBufferGetBytesPerRow(buf) * h)
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    static func zip(_ files: [String: String], at url: URL, in dir: URL) async throws {
        let staging = dir.appendingPathComponent("zipsrc-\(UUID().uuidString)")
        for (name, content) in files {
            let f = staging.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: f, atomically: true, encoding: .utf8)
        }
        let r = try await ToolRunner().run("/usr/bin/zip", ["-qr", url.path, "."], cwd: staging, timeout: .seconds(20), outputLimit: 1 << 16)
        #expect(r.succeeded)
    }
}

struct ExtractorTests {
    let extractor = ContentExtractor()

    private func text(_ p: NamingPayload?) -> String? {
        if case .text(let s)? = p { return s }
        return nil
    }
    private func jpeg(_ p: NamingPayload?) -> Data? {
        if case .image(let d)? = p { return d }
        return nil
    }

    // MARK: Extensions

    @Test func nameableExtensions() {
        for e in ["jpg", "heic", "png", "tiff", "webp", "gif", "bmp", "mp4", "mov", "pdf", "txt", "md", "json",
                  "csv", "tsv", "docx", "rtf", "odt", "xlsx", "ods", "pptx", "odp", "JPG"] {
            #expect(ContentExtractor.isNameableExtension(e), "\(e)")
        }
        for e in ["zip", "dmg", "pkg", "3mf", "stl", "exe", "7z", "", "iso"] {
            #expect(!ContentExtractor.isNameableExtension(e), "\(e)")
        }
    }

    @Test func unknownExtensionIsNil() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("a.zip")
        try Data([1, 2, 3]).write(to: f)
        #expect(await extractor.extract(from: f, sourceExtension: "zip") == nil)
        #expect(await extractor.extract(from: f, sourceExtension: "stl") == nil)
    }

    // MARK: Images

    @Test func largeImageIsDownscaledToJPEG() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("big.png")
        try Fixtures.writeImage(Fixtures.bitmap(width: 2000, height: 1000, noise: false), to: f, type: .png)
        let data = try #require(jpeg(await extractor.extract(from: f, sourceExtension: "png")))
        #expect(Fixtures.isJPEG(data))
        #expect(data.count <= 300 * 1024)
        let (w, h) = try #require(Fixtures.dimensions(of: data))
        #expect(max(w, h) == 768)
        #expect(w > h)
    }

    @Test func exifOrientationIsApplied() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("rot.jpg")
        // 400x200 stored, orientation 6 (rotate 90 CW): displays as 200x400.
        try Fixtures.writeImage(Fixtures.bitmap(width: 400, height: 200, noise: false), to: f, type: .jpeg, orientation: 6)
        let data = try #require(jpeg(await extractor.extract(from: f, sourceExtension: "jpg")))
        let (w, h) = try #require(Fixtures.dimensions(of: data))
        #expect(w == 200 && h == 400)
    }

    @Test func noiseImageStaysUnderCap() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("noise.png")
        try Fixtures.writeImage(Fixtures.bitmap(width: 800, height: 800, noise: true), to: f, type: .png)
        // Full-entropy content either fits after the quality ladder or is refused; never above the cap.
        if let data = jpeg(await extractor.extract(from: f, sourceExtension: "png")) {
            #expect(data.count <= 300 * 1024)
        }
    }

    @Test func encodeJPEGRefusesWhenLadderCannotMeetCap() throws {
        let noise = Fixtures.bitmap(width: 400, height: 400, noise: true)
        #expect(ContentExtractor.encodeJPEG(noise, maxBytes: 5_000) == nil)
        let smooth = Fixtures.bitmap(width: 768, height: 768, noise: false)
        let data = try #require(ContentExtractor.encodeJPEG(smooth))
        #expect(data.count <= 300 * 1024)
        // A tight cap forces a lower-quality retry that is smaller than the q80 result.
        let q80 = try #require(ContentExtractor.encodeJPEG(smooth, maxBytes: .max))
        let tight = ContentExtractor.encodeJPEG(smooth, maxBytes: q80.count - 1)
        if let tight { #expect(tight.count < q80.count) }
    }

    @Test func corruptImageIsNil() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("bad.jpg")
        try Data("not an image".utf8).write(to: f)
        #expect(await extractor.extract(from: f, sourceExtension: "jpg") == nil)
    }

    @Test func missingFileIsNil() async {
        let f = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).txt")
        #expect(await extractor.extract(from: f, sourceExtension: "txt") == nil)
        #expect(await extractor.extract(from: f, sourceExtension: "png") == nil)
        #expect(await extractor.extract(from: f, sourceExtension: "pdf") == nil)
        #expect(await extractor.extract(from: f, sourceExtension: "docx") == nil)
    }

    // MARK: Video

    @Test func videoMiddleFrame() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("clip.mp4")
        try await Fixtures.video(at: f)
        let data = try #require(jpeg(await extractor.extract(from: f, sourceExtension: "mp4")))
        #expect(Fixtures.isJPEG(data))
        let (w, h) = try #require(Fixtures.dimensions(of: data))
        #expect(w == 320 && h == 240)
    }

    // MARK: PDF

    @Test func pdfWithTextLayer() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("t.pdf")
        Fixtures.textPDF("Quarterly budget report for Acme Corporation", at: f)
        let s = try #require(text(await extractor.extract(from: f, sourceExtension: "pdf")))
        #expect(s.contains("Quarterly budget report"))
        #expect(s.utf8.count <= 2048)
    }

    @Test func pdfWithoutTextFallsBackToThumbnail() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("scan.pdf")
        Fixtures.imagePDF(at: f)
        let data = try #require(jpeg(await extractor.extract(from: f, sourceExtension: "pdf")))
        #expect(Fixtures.isJPEG(data))
        let (w, h) = try #require(Fixtures.dimensions(of: data))
        #expect(max(w, h) <= 768 && h > w)
    }

    // MARK: Plain text

    @Test func plainTextIsCappedAtCharacterBoundary() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("long.txt")
        // 3-byte characters: 2048 is not a multiple of 3, so a cut mid-character would show.
        try String(repeating: "日", count: 5000).write(to: f, atomically: true, encoding: .utf8)
        let s = try #require(text(await extractor.extract(from: f, sourceExtension: "txt")))
        #expect(s.utf8.count == 2046)
        #expect(!s.contains("\u{FFFD}"))
    }

    @Test func jsonAndMarkdown() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let j = d.appendingPathComponent("a.json")
        try #"{"project":"alpha"}"#.write(to: j, atomically: true, encoding: .utf8)
        #expect(text(await extractor.extract(from: j, sourceExtension: "json")) == #"{"project":"alpha"}"#)
        let m = d.appendingPathComponent("a.md")
        try "# Title\n\nbody".write(to: m, atomically: true, encoding: .utf8)
        #expect(text(await extractor.extract(from: m, sourceExtension: "md")) == "# Title\n\nbody")
    }

    @Test func emptyAndBinaryTextIsNil() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let e = d.appendingPathComponent("e.txt")
        try "  \n ".write(to: e, atomically: true, encoding: .utf8)
        #expect(await extractor.extract(from: e, sourceExtension: "txt") == nil)
        let b = d.appendingPathComponent("b.txt")
        try Data([0x41, 0x00, 0x42, 0x00]).write(to: b)
        #expect(await extractor.extract(from: b, sourceExtension: "txt") == nil)
    }

    @Test func csvKeepsHeaderAndFiveRows() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("t.csv")
        let rows = (0...20).map { $0 == 0 ? "id,name,amount" : "\($0),item\($0),\($0 * 10)" }
        try rows.joined(separator: "\r\n").write(to: f, atomically: true, encoding: .utf8)
        let s = try #require(text(await extractor.extract(from: f, sourceExtension: "csv")))
        let lines = s.split(separator: "\n")
        #expect(lines.count == 6)
        #expect(lines.first == "id,name,amount")
        #expect(lines.last == "5,item5,50")
    }

    @Test func tsvAndCsvCapBytes() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("wide.tsv")
        let row = (0..<400).map { "col\($0)" }.joined(separator: "\t")
        try Array(repeating: row, count: 10).joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        let s = try #require(text(await extractor.extract(from: f, sourceExtension: "tsv")))
        #expect(s.utf8.count <= 2048)
    }

    // MARK: Office

    @Test func docxViaTextutil() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("src.txt")
        try "Lease agreement between Alice and Bob for the apartment on Main Street.".write(to: src, atomically: true, encoding: .utf8)
        let docx = d.appendingPathComponent("lease.docx")
        let r = try await ToolRunner().run("/usr/bin/textutil", ["-convert", "docx", src.path, "-output", docx.path], timeout: .seconds(20))
        try #require(r.succeeded)
        let s = try #require(text(await extractor.extract(from: docx, sourceExtension: "docx")))
        #expect(s.contains("Lease agreement between Alice and Bob"))
    }

    @Test func rtfViaTextutil() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("a.rtf")
        try #"{\rtf1\ansi Meeting notes for the board.}"#.write(to: f, atomically: true, encoding: .utf8)
        let s = try #require(text(await extractor.extract(from: f, sourceExtension: "rtf")))
        #expect(s.contains("Meeting notes for the board"))
    }

    @Test func xlsxSheetNamesAndStrings() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("b.xlsx")
        try await Fixtures.zip([
            "xl/workbook.xml": #"<workbook><sheets><sheet name="Q1 Budget" sheetId="1" r:id="rId1"/><sheet name="Headcount &amp; Hiring" sheetId="2" r:id="rId2"/></sheets></workbook>"#,
            "xl/sharedStrings.xml": "<sst><si><t>Revenue</t></si><si><t>Marketing spend</t></si></sst>",
        ], at: f, in: d)
        let s = try #require(text(await extractor.extract(from: f, sourceExtension: "xlsx")))
        #expect(s.contains("Q1 Budget"))
        #expect(s.contains("Headcount & Hiring"))
        #expect(s.contains("Marketing spend"))
    }

    @Test func pptxSlideText() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("deck.pptx")
        try await Fixtures.zip([
            "ppt/slides/slide1.xml": "<p:sld><a:p><a:r><a:t>Launch plan</a:t></a:r></a:p></p:sld>",
            "ppt/slides/slide2.xml": "<p:sld><a:p><a:r><a:t>Market sizing</a:t></a:r></a:p></p:sld>",
        ], at: f, in: d)
        let s = try #require(text(await extractor.extract(from: f, sourceExtension: "pptx")))
        #expect(s.contains("Launch plan") && s.contains("Market sizing"))
        #expect(!s.contains("<"))
    }

    @Test func odsAndOdp() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let ods = d.appendingPathComponent("a.ods")
        try await Fixtures.zip(["content.xml": #"<office:document-content><table:table table:name="Inventory"><text:p>Widgets</text:p></table:table></office:document-content>"#], at: ods, in: d)
        let s = try #require(text(await extractor.extract(from: ods, sourceExtension: "ods")))
        #expect(s.contains("Inventory") && s.contains("Widgets"))
        let odp = d.appendingPathComponent("a.odp")
        try await Fixtures.zip(["content.xml": "<office:document-content><text:p>Roadmap review</text:p></office:document-content>"], at: odp, in: d)
        #expect(text(await extractor.extract(from: odp, sourceExtension: "odp"))?.contains("Roadmap review") == true)
    }

    @Test func corruptZipIsNil() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("bad.xlsx")
        try Data("PK garbage".utf8).write(to: f)
        #expect(await extractor.extract(from: f, sourceExtension: "xlsx") == nil)
    }

    // MARK: Helpers

    @Test func truncateRespectsCharacterBoundaries() {
        #expect(ContentExtractor.truncateUTF8("abcdef", maxBytes: 4) == "abcd")
        #expect(ContentExtractor.truncateUTF8("日本語", maxBytes: 7) == "日本")
        #expect(ContentExtractor.truncateUTF8("e\u{301}e\u{301}", maxBytes: 4) == "e\u{301}")
    }

    @Test func timeoutReturnsNilAndDoesNotWaitForBlockedWork() async {
        let start = ContinuousClock.now
        let r: Int? = await ContentExtractor.withTimeout(0.3) {
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        #expect(r == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
        let ok: Int? = await ContentExtractor.withTimeout(5) { 7 }
        #expect(ok == 7)
    }
}

/// A valid 1-bit grayscale PNG of any size, built from compressed zero rows without allocating the
/// pixels (a "decompression bomb": a small file that declares a huge canvas).
private func bilevelPNG(width: Int, height: Int) throws -> Data {
    func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
        }
        return ~c
    }
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let tb = Array(type.utf8) + body
        return be32(UInt32(body.count)) + tb + be32(crc32(tb))
    }
    let raw = Data(count: height * (1 + (width + 7) / 8))
    let deflated = try (raw as NSData).compressed(using: .zlib) as Data
    let adler = UInt32(raw.count % 65_521) << 16 | 1   // Adler-32 of all-zero bytes
    let zlib = [0x78, 0x01] + [UInt8](deflated) + be32(adler)
    let ihdr = be32(UInt32(width)) + be32(UInt32(height)) + [1, 0, 0, 0, 0]
    var png: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    png += chunk("IHDR", ihdr) + chunk("IDAT", zlib) + chunk("IEND", [])
    return Data(png)
}

@Suite struct ExtractorLimitTests {
    let extractor = ContentExtractor()

    @Test func pixelCap() {
        func ok(_ w: Int, _ h: Int, _ bytes: Int64) -> Bool { ContentExtractor.withinPixelCap(width: w, height: h, bytes: bytes) }
        #expect(ok(11_648, 8_736, 40_000_000))     // GFX100
        #expect(ok(16_000, 12_500, 60_000_000))    // 200 MP
        #expect(!ok(30_000, 30_000, 109_000))      // bomb
        #expect(!ok(0, 10, 100))
        #expect(!ok(Int.max, 3, Int64.max))
    }

    @Test("a ~100 KB 900 MP PNG bomb is not thumbnailed; a small flat image is")
    func oversizeImageIsNotDecoded() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let bomb = d.appendingPathComponent("bomb.png")
        try bilevelPNG(width: 30_000, height: 30_000).write(to: bomb)
        let start = ContinuousClock.now
        #expect(await extractor.extract(from: bomb, sourceExtension: "png") == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
        let big = d.appendingPathComponent("big.png")
        try bilevelPNG(width: 11_000, height: 10_000).write(to: big)   // 110 MP in a few KB
        #expect(await extractor.extract(from: big, sourceExtension: "png") == nil)
        let ok = d.appendingPathComponent("ok.png")
        try bilevelPNG(width: 2_000, height: 1_000).write(to: ok)
        guard case .image? = await extractor.extract(from: ok, sourceExtension: "png") else {
            Issue.record("2 MP image not thumbnailed")
            return
        }
    }

    @Test("a 30 MB xlsx member is cut at the read cap and still yields text")
    func hugeZipMemberIsCutAtReadCap() async throws {
        let d = try Fixtures.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let xlsx = d.appendingPathComponent("big.xlsx")
        let strings = "<sst>" + String(repeating: "<si><t>quarterly revenue</t></si>", count: 1_000_000) + "</sst>"
        try await Fixtures.zip(["xl/sharedStrings.xml": strings,
                                "xl/workbook.xml": #"<workbook><sheets><sheet name="Totals"/></sheets></workbook>"#],
                               at: xlsx, in: d)
        let start = ContinuousClock.now
        let payload = await extractor.extract(from: xlsx, sourceExtension: "xlsx")
        #expect(ContinuousClock.now - start < .seconds(5))
        guard case .text(let s)? = payload else {
            Issue.record("no text from a large xlsx")
            return
        }
        #expect(s.hasPrefix("Sheets: Totals"))
        #expect(s.contains("quarterly revenue"))
        #expect(s.utf8.count <= ContentExtractor.maxTextBytes)
    }
}
