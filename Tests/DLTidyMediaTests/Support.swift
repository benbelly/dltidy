import DLTidyKit
import Foundation
import Testing
@testable import DLTidyMedia

/// Forwards to the real runner and records every call.
final class RecordingRunner: ToolRunning, @unchecked Sendable {
    struct Call: Sendable { var tool: String; var args: [String]; var timeout: Duration }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    let inner = ToolRunner()

    func run(_ tool: String, _ args: [String], cwd: URL?, timeout: Duration, outputLimit: Int) async throws -> ToolResult {
        lock.withLock { _calls.append(Call(tool: tool, args: args, timeout: timeout)) }
        return try await inner.run(tool, args, cwd: cwd, timeout: timeout, outputLimit: outputLimit)
    }
}

/// ToolResult has no public initialiser, so a real short-lived process produces the timed-out result.
struct TimedOutRunner: ToolRunning {
    func run(_ tool: String, _ args: [String], cwd: URL?, timeout: Duration, outputLimit: Int) async throws -> ToolResult {
        try await ToolRunner().run("/bin/sh", ["-c", "exec sleep 30"], cwd: nil, timeout: .milliseconds(200), outputLimit: 1000)
    }
}

struct MissingToolRunner: ToolRunning {
    func run(_ tool: String, _ args: [String], cwd: URL?, timeout: Duration, outputLimit: Int) async throws -> ToolResult {
        throw ToolError.notFound(tool)
    }
}

let sh = ToolRunner()

@discardableResult
func exec(_ tool: String, _ args: [String], cwd: URL? = nil) async throws -> String {
    let r = try await sh.run(tool, args, cwd: cwd, timeout: .seconds(120), outputLimit: 1 << 20)
    guard r.succeeded else {
        throw MediaTestError.toolFailed("\(tool) \(args.joined(separator: " ")): \(String(decoding: r.stderr, as: UTF8.self))")
    }
    return String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

enum MediaTestError: Error { case toolFailed(String) }

/// Per-test scratch directory.
func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dltidy-media-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Copies a fixture to `<dir>/in.<ext>`, as core stages it.
func stage(_ fixture: URL, in dir: URL) throws -> URL {
    let dest = dir.appendingPathComponent("in." + fixture.pathExtension)
    try FileManager.default.copyItem(at: fixture, to: dest)
    return dest
}

struct Fixtures: Sendable {
    let dir: URL
    var photoJPG: URL { dir.appendingPathComponent("photo.jpg") }       // 120x80, orientation right-top, GPS
    var photoHEIC: URL { dir.appendingPathComponent("photo.heic") }     // from photoJPG via sips
    var alphaPNG: URL { dir.appendingPathComponent("alpha.png") }       // transparent, 100x60
    var animGIF: URL { dir.appendingPathComponent("anim.gif") }         // 3 frames x 0.1 s
    var animWEBP: URL { dir.appendingPathComponent("anim.webp") }
    var h264MOV: URL { dir.appendingPathComponent("h264.mov") }         // 3 s, aac
    var hevcMOV: URL { dir.appendingPathComponent("hevc.mov") }         // 3 s, SDR
    var hdrMOV: URL { dir.appendingPathComponent("hdr.mov") }           // 3 s, HEVC 10-bit HLG
    var mkv: URL { dir.appendingPathComponent("long.mkv") }             // 12 s
    var corruptJPG: URL { dir.appendingPathComponent("corrupt.jpg") }
    var corruptMP4: URL { dir.appendingPathComponent("corrupt.mp4") }
    var pdf: URL { dir.appendingPathComponent("doc.pdf") }
    var txt: URL { dir.appendingPathComponent("note.txt") }
}

actor FixtureStore {
    static let shared = FixtureStore()
    private var cached: Fixtures?

    func get() async throws -> Fixtures {
        if let cached { return cached }
        let f = Fixtures(dir: try scratch())
        try await build(f)
        cached = f
        return f
    }

    private func build(_ f: Fixtures) async throws {
        let plain = f.dir.appendingPathComponent("plain.jpg")
        try await exec("magick", ["-size", "120x80", "gradient:red-blue", plain.path])
        try insertEXIF(into: plain, output: f.photoJPG)
        try await exec("sips", ["-s", "format", "heic", f.photoJPG.path, "--out", f.photoHEIC.path])
        try await exec("magick", ["-size", "100x60", "xc:none", "-fill", "red", "-draw", "circle 50,30 50,10", f.alphaPNG.path])
        try await exec("magick", ["-delay", "10", "-size", "100x60", "xc:red", "xc:blue", "xc:green", "-loop", "0", f.animGIF.path])
        try await exec("magick", [f.animGIF.path, f.animWEBP.path])

        let src = ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15", "-f", "lavfi", "-i", "sine=frequency=440"]
        func ff(_ t: Int, _ extra: [String], _ out: URL) async throws {
            try await exec("ffmpeg", ["-nostdin", "-y", "-v", "error"] + src + ["-t", String(t)] + extra + [out.path])
        }
        try await ff(3, ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                         "-metadata", "location=+37.3349-122.0090/"], f.h264MOV)
        try await ff(3, ["-c:v", "libx265", "-tag:v", "hvc1", "-x265-params", "log-level=none", "-c:a", "aac"], f.hevcMOV)
        try await ff(3, ["-c:v", "libx265", "-tag:v", "hvc1", "-pix_fmt", "yuv420p10le", "-color_primaries", "bt2020",
                         "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc",
                         "-x265-params", "log-level=none:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc",
                         "-c:a", "aac", "-metadata", "location=+37.3349-122.0090/"], f.hdrMOV)
        try await ff(12, ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"], f.mkv)

        try Data((0..<4096).map { UInt8(($0 &* 31 &+ 7) & 0xff) }).write(to: f.corruptJPG)
        try Data((0..<4096).map { UInt8(($0 &* 17 &+ 3) & 0xff) }).write(to: f.corruptMP4)
        try Data("%PDF-1.4\n".utf8).write(to: f.pdf)
        try Data("hello".utf8).write(to: f.txt)
    }
}

// MARK: - Inspection helpers

func ffprobeJSON(_ url: URL) async throws -> FFProbeOutput {
    let out = try await exec("ffprobe", ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
    return try JSONDecoder().decode(FFProbeOutput.self, from: Data(out.utf8))
}

func identify(_ url: URL, _ format: String) async throws -> String {
    try await exec("magick", ["identify", "-format", format, url.path + "[0]"])
}

func pixel(_ url: URL, x: Int, y: Int) async throws -> [Int] {
    let s = try await exec("magick", [url.path + "[0]", "-format", "%[fx:int(255*p{\(x),\(y)}.r)] %[fx:int(255*p{\(x),\(y)}.g)] %[fx:int(255*p{\(x),\(y)}.b)]", "info:"])
    return s.split(separator: " ").compactMap { Int($0) }
}

func size(of url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
}

/// Inserts an APP1/EXIF segment (big-endian TIFF) with Orientation = 6 (right-top) and GPS
/// 37 20 0 N, 122 0 0 W right after the JPEG SOI marker. magick cannot write these tags itself.
func insertEXIF(into src: URL, output: URL) throws {
    var t = [UInt8]()
    func u16(_ v: Int) { t += [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    func u32(_ v: Int) { t += [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    t += Array("MM".utf8); u16(42); u32(8)
    u16(2)
    u16(0x0112); u16(3); u32(1); u16(6); u16(0)          // Orientation
    u16(0x8825); u16(4); u32(1); u32(38)                  // GPS IFD pointer
    u32(0)
    u16(4)
    u16(1); u16(2); u32(2); t += Array("N".utf8) + [0, 0, 0]
    u16(2); u16(5); u32(3); u32(92)
    u16(3); u16(2); u32(2); t += Array("W".utf8) + [0, 0, 0]
    u16(4); u16(5); u32(3); u32(116)
    u32(0)
    for (n, d) in [(37, 1), (20, 1), (0, 1), (122, 1), (0, 1), (0, 1)] { u32(n); u32(d) }
    let payload = Array("Exif".utf8) + [0, 0] + t
    let length = payload.count + 2
    var seg: [UInt8] = [0xFF, 0xE1, UInt8(length >> 8 & 0xff), UInt8(length & 0xff)]
    seg += payload
    let data = try Data(contentsOf: src)
    try (data.prefix(2) + Data(seg) + data.dropFirst(2)).write(to: output)
}
