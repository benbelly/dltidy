import AppKit
import AVFoundation
import DLTidyKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Builds a small payload (thumbnail or text) from a staged file. Reads are capped; every
/// extractor runs under a 10 s timeout. Returns nil for unsupported or failing files.
public struct ContentExtractor: ContentExtracting {
    static let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp", "gif", "bmp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let plainTextExtensions: Set<String> = ["txt", "md", "json"]
    static let tableTextExtensions: Set<String> = ["csv", "tsv"]
    static let textutilExtensions: Set<String> = ["docx", "rtf", "odt"]
    static let zipExtensions: Set<String> = ["xlsx", "ods", "pptx", "odp"]

    static let maxTextBytes = 2_048
    static let readCap = 256 * 1024
    static let maxImageBytes = 300 * 1024
    static let longEdge = 768
    static let timeoutSeconds: Double = 10

    private let tools: any ToolRunning

    public init(tools: any ToolRunning = ToolRunner()) {
        self.tools = tools
    }

    /// `ext` is lowercased, without the dot.
    public static func isNameableExtension(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return imageExtensions.contains(e) || videoExtensions.contains(e) || e == "pdf"
            || plainTextExtensions.contains(e) || tableTextExtensions.contains(e)
            || textutilExtensions.contains(e) || zipExtensions.contains(e)
    }

    public func extract(from file: URL, sourceExtension: String) async -> NamingPayload? {
        let ext = sourceExtension.lowercased()
        guard Self.isNameableExtension(ext) else { return nil }
        let tools = self.tools
        return await Self.withTimeout(Self.timeoutSeconds) {
            await Self.run(file: file, ext: ext, tools: tools)
        }
    }

    // MARK: Dispatch

    private static func run(file: URL, ext: String, tools: any ToolRunning) async -> NamingPayload? {
        if imageExtensions.contains(ext) {
            return imagePayload(file)
        } else if videoExtensions.contains(ext) {
            return await videoPayload(file)
        } else if ext == "pdf" {
            return pdfPayload(file)
        } else if plainTextExtensions.contains(ext) {
            return textPayload(readPrefix(file)) { $0 }
        } else if tableTextExtensions.contains(ext) {
            return textPayload(readPrefix(file)) { text in
                text.split(whereSeparator: \.isNewline).prefix(6).joined(separator: "\n")
            }
        } else if textutilExtensions.contains(ext) {
            return await textutilPayload(file, tools: tools)
        } else {
            return await zipPayload(file, ext: ext, tools: tools)
        }
    }

    // MARK: Text

    /// Reads at most 256 KB.
    static func readPrefix(_ file: URL) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        return try? h.read(upToCount: readCap)
    }

    /// Decodes UTF-8 (tolerating a cut multi-byte tail), falls back to Latin-1; nil for binary data.
    static func decode(_ data: Data) -> String? {
        if data.contains(0) { return nil }
        var d = data
        for _ in 0..<4 {
            if let s = String(data: d, encoding: .utf8) { return s }
            if d.isEmpty { break }
            d.removeLast()
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Truncates to at most `maxBytes` of UTF-8 at a character boundary.
    static func truncateUTF8(_ s: String, maxBytes: Int = maxTextBytes) -> String {
        var out = ""
        var used = 0
        for ch in s {
            let n = ch.utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    private static func textPayload(_ data: Data?, transform: (String) -> String) -> NamingPayload? {
        guard let data, let decoded = decode(data) else { return nil }
        let text = truncateUTF8(transform(decoded).trimmingCharacters(in: .whitespacesAndNewlines))
        return text.isEmpty ? nil : .text(text)
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func textutilPayload(_ file: URL, tools: any ToolRunning) async -> NamingPayload? {
        guard let r = try? await tools.run("/usr/bin/textutil", ["-convert", "txt", "-stdout", file.path],
                                           cwd: nil, timeout: .seconds(9), outputLimit: readCap),
              r.succeeded || r.outputTruncated, let s = decode(r.stdout) else { return nil }
        let text = truncateUTF8(collapse(s))
        return text.isEmpty ? nil : .text(text)
    }

    // MARK: Zip-based office formats

    private static func unzip(_ file: URL, _ member: String, tools: any ToolRunning) async -> String? {
        guard let r = try? await tools.run("/usr/bin/unzip", ["-p", file.path, member],
                                           cwd: nil, timeout: .seconds(9), outputLimit: readCap),
              r.succeeded || r.outputTruncated else { return nil }
        return decode(r.stdout)
    }

    private static func zipPayload(_ file: URL, ext: String, tools: any ToolRunning) async -> NamingPayload? {
        var text = ""
        switch ext {
        case "xlsx":
            if let wb = await unzip(file, "xl/workbook.xml", tools: tools) {
                let names = matches(#"<sheet\b[^>]*\bname="([^"]*)""#, in: wb).map(unescape)
                if !names.isEmpty { text += "Sheets: " + names.joined(separator: ", ") + "\n" }
            }
            if let ss = await unzip(file, "xl/sharedStrings.xml", tools: tools) {
                text += stripTags(ss)
            }
        case "ods":
            if let c = await unzip(file, "content.xml", tools: tools) {
                let names = matches(#"<table:table\b[^>]*\btable:name="([^"]*)""#, in: c).map(unescape)
                if !names.isEmpty { text += "Sheets: " + names.joined(separator: ", ") + "\n" }
                text += stripTags(c)
            }
        case "pptx":
            if let s = await unzip(file, "ppt/slides/slide*.xml", tools: tools) { text = stripTags(s) }
        default: // odp
            if let c = await unzip(file, "content.xml", tools: tools) { text = stripTags(c) }
        }
        let out = truncateUTF8(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return out.isEmpty ? nil : .text(out)
    }

    static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Removes XML tags (each becomes a space), decodes the common entities, collapses whitespace.
    static func stripTags(_ xml: String) -> String {
        let noTags = xml.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        return collapse(unescape(noTags))
    }

    // MARK: PDF

    private static func pdfPayload(_ file: URL) -> NamingPayload? {
        guard let doc = PDFDocument(url: file), !doc.isLocked, doc.pageCount > 0 else { return nil }
        var text = ""
        for i in 0..<min(doc.pageCount, 5) {
            if let s = doc.page(at: i)?.string { text += " " + s }
            if text.utf8.count >= maxTextBytes * 2 { break }
        }
        let collapsed = collapse(text)
        if !collapsed.isEmpty { return .text(truncateUTF8(collapsed)) }
        guard let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = CGFloat(longEdge) / max(bounds.width, bounds.height)
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let image = page.thumbnail(of: size, for: .mediaBox)
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let jpeg = encodeJPEG(cg) else { return nil }
        return .image(jpeg: jpeg)
    }

    // MARK: Images

    /// The shared decompression-bomb rule (`ImageLimits`), with the file's size.
    static func withinPixelCap(width: Int, height: Int, bytes: Int64) -> Bool {
        ImageLimits.isAcceptable(width: width, height: height, fileBytes: bytes)
    }

    private static func fileBytes(_ file: URL) -> Int64 {
        (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private static func imagePayload(_ file: URL) -> NamingPayload? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(file as CFURL, sourceOptions),
              CGImageSourceGetCount(src) > 0 else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, sourceOptions) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              withinPixelCap(width: w, height: h, bytes: fileBytes(file)) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // applies EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let jpeg = encodeJPEG(thumb) else { return nil }
        return .image(jpeg: jpeg)
    }

    private static func videoPayload(_ file: URL) async -> NamingPayload? {
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        let time = seconds.isFinite && seconds > 0 ? CMTime(seconds: seconds / 2, preferredTimescale: 600) : .zero
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: longEdge, height: longEdge)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        guard let frame = try? await gen.image(at: time).image else { return nil }
        guard let jpeg = encodeJPEG(frame) else { return nil }
        return .image(jpeg: jpeg)
    }

    /// Scales to a 768 px long edge if larger, flattens onto white (JPEG has no alpha), encodes at
    /// q80 and retries at lower quality when above 300 KB. Nil when still too large.
    static func encodeJPEG(_ image: CGImage, maxBytes: Int = maxImageBytes) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, Double(longEdge) / Double(max(w, h)))
        let tw = max(1, Int((Double(w) * scale).rounded())), th = max(1, Int((Double(h) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let flat = ctx.makeImage() else { return nil }
        for quality in [0.8, 0.6, 0.4] {
            guard let data = jpegData(flat, quality: quality) else { return nil }
            if data.count <= maxBytes { return data }
        }
        return nil
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: Timeout

    /// Returns the work's result, or nil after `seconds`. Blocking work that ignores cancellation
    /// keeps running in the background but no longer holds up the caller.
    static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let gate = Gate<T>(cont)
            let timer = Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                gate.finish(nil)
            }
            gate.timer = timer
            Task.detached {
                gate.finish(await work())
            }
        }
    }

    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T?, Never>?
        private var _timer: Task<Void, Never>?
        init(_ cont: CheckedContinuation<T?, Never>) { self.cont = cont }
        var timer: Task<Void, Never>? {
            get { lock.withLock { _timer } }
            set { lock.withLock { _timer = newValue } }
        }
        func finish(_ value: T?) {
            let c: CheckedContinuation<T?, Never>? = lock.withLock {
                defer { cont = nil }
                return cont
            }
            guard let c else { return }
            timer?.cancel()
            c.resume(returning: value)
        }
    }
}
