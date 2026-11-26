import Foundation
import DLTidyKit

/// Append-only text log with size rotation (`dltidy.log`, `.1` … `.N`).
public final class Log: @unchecked Sendable {
    public enum Level: String, Sendable { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    private let url: URL?
    private let maxBytes: Int
    private let filesKept: Int
    private let clock: any Clock
    private let echo: Bool
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0
    private let formatter: ISO8601DateFormatter

    /// `url == nil` keeps lines in memory only (`recent`), for tests.
    public init(url: URL?, maxBytes: Int = 5 << 20, filesKept: Int = 5, clock: any Clock = SystemClock(), echo: Bool = false) {
        self.url = url
        self.maxBytes = maxBytes
        self.filesKept = filesKept
        self.clock = clock
        self.echo = echo
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    private var memory: [String] = []

    /// Last lines written (bounded), for tests and diagnostics.
    public var recent: [String] { lock.withLock { memory } }

    public func debug(_ message: @autoclosure () -> String) { write(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    public func warn(_ message: @autoclosure () -> String) { write(.warn, message()) }
    public func error(_ message: @autoclosure () -> String) { write(.error, message()) }

    public func write(_ level: Level, _ message: String) {
        lock.withLock {
            let line = "\(formatter.string(from: clock.now())) \(level.rawValue) \(message)\n"
            memory.append(line)
            if memory.count > 2_000 { memory.removeFirst(memory.count - 1_000) }
            if echo { FileHandle.standardError.write(Data(line.utf8)) }
            guard let url else { return }
            let data = Data(line.utf8)
            if handle == nil { open(url) }
            if size + data.count > maxBytes { rotate(url) }
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
                size += data.count
            } catch {
                self.handle = nil
            }
        }
    }

    private func open(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate(_ url: URL) {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let base = url.path
        try? fm.removeItem(atPath: "\(base).\(filesKept)")
        if filesKept > 1 {
            for i in stride(from: filesKept - 1, through: 1, by: -1) {
                try? fm.moveItem(atPath: "\(base).\(i)", toPath: "\(base).\(i + 1)")
            }
        }
        try? fm.moveItem(atPath: base, toPath: "\(base).1")
        open(url)
    }
}
