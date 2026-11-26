import DLTidyKit
import Foundation

/// Locates the ImageMagick security policy every `magick` call runs under (MAGICK_CONFIGURE_PATH).
/// The policy ships as `Support/magick/policy.xml`, copied into the app bundle before signing so the
/// code signature seals it. A missing or unreadable file fails closed: no `magick` call runs.
enum MagickPolicy {
    /// `<app>/Contents/Resources/magick`, found from the real executable path. `Bundle.main` is not
    /// used: when the CLI runs through the `~/.local/bin/dltidy` symlink it resolves to that folder.
    static var defaultDirectory: URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else {
            return URL(fileURLWithPath: "/nonexistent/magick", isDirectory: true)
        }
        let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let exe = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return exe.deletingLastPathComponent()          // Contents/MacOS
            .deletingLastPathComponent()                // Contents
            .appendingPathComponent("Resources/magick", isDirectory: true)
    }

    /// nil when `directory/policy.xml` is readable and non-empty; otherwise why not.
    static func problem(in directory: URL) -> String? {
        let file = directory.appendingPathComponent("policy.xml")
        guard let data = try? Data(contentsOf: file) else { return "cannot read \(file.path)" }
        return data.isEmpty ? "\(file.path) is empty" : nil
    }

    /// Environment for a `magick` child. Throws when the policy is missing, so callers do not run it.
    static func environment(directory: URL) throws -> [String: String] {
        if problem(in: directory) != nil { throw MediaError.toolMissing("magick policy") }
        return ["MAGICK_CONFIGURE_PATH": directory.path]
    }
}
