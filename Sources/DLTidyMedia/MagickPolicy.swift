import DLTidyKit
import Darwin
import Foundation

/// The ImageMagick security policy every `magick` call runs under (through MAGICK_CONFIGURE_PATH).
///
/// ImageMagick picks the decoder by content, so a file named `.jpg` can be SVG (which reads other
/// local files) or PostScript (Ghostscript). The policy allows only the raster coders behind
/// `MediaProcessor.imageExtensions`, plus NULL for writing (the decode check), denies every delegate
/// (external program) and `@file` indirection, and caps resources.
///
/// The text is compiled into the binary and written to a private directory (0700) on first use;
/// each call re-checks the file and rewrites it if it changed or vanished (e.g. temp cleanup).
enum MagickPolicy {
    /// Coders per extension in `MediaProcessor.imageExtensions`, plus NULL (write only, for the decode
    /// check). Homebrew's ImageMagick has no openjpeg (JP2 does not decode with or without the policy)
    /// and no raw library: DNG decodes only through the darktable-cli delegate, which the policy denies.
    static let readCoders = [
        "PNG", "PNG8", "PNG24", "PNG32", "PNG48", "PNG64", "PNG00",   // png
        "JPEG", "JPG",                                                  // jpg, jpeg
        "HEIC", "HEIF", "AVIF",                                         // heic, heif, avif
        "TIFF", "TIF", "TIFF64",                                        // tif, tiff
        "BMP", "BMP2", "BMP3",                                          // bmp
        "WEBP",                                                         // webp
        "GIF", "GIF87",                                                 // gif
        "JP2", "J2K", "J2C", "JPC", "JPX",                              // jp2
        "DNG",                                                          // dng
    ]
    static let modules = ["PNG", "JPEG", "HEIC", "TIFF", "BMP", "WEBP", "GIF", "JP2", "DNG", "NULL"]

    static let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <policymap>
          <policy domain="delegate" rights="none" pattern="*"/>
          <policy domain="module" rights="none" pattern="*"/>
          <policy domain="module" rights="read|write" pattern="{\(modules.joined(separator: ","))}"/>
          <policy domain="coder" rights="none" pattern="*"/>
          <policy domain="coder" rights="read|write" pattern="{\(readCoders.joined(separator: ","))}"/>
          <policy domain="coder" rights="write" pattern="NULL"/>
          <policy domain="path" rights="none" pattern="@*"/>
          <policy domain="resource" name="memory" value="512MiB"/>
          <policy domain="resource" name="map" value="1GiB"/>
          <policy domain="resource" name="disk" value="2GiB"/>
          <policy domain="resource" name="area" value="128MP"/>
          <policy domain="resource" name="width" value="16KP"/>
          <policy domain="resource" name="height" value="16KP"/>
        </policymap>

        """

    private static let store = Store()

    /// Environment for a `magick` child. Throws when the policy file cannot be written; callers
    /// then do not run `magick` at all.
    static func environment() throws -> [String: String] {
        ["MAGICK_CONFIGURE_PATH": try store.directory().path]
    }

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var dir: URL?

        func directory() throws -> URL {
            try lock.withLock {
                let data = Data(MagickPolicy.xml.utf8)
                if let dir, (try? Data(contentsOf: dir.appendingPathComponent("policy.xml"))) == data { return dir }
                let fresh = try Self.makePrivateDir()
                let file = fresh.appendingPathComponent("policy.xml")
                try data.write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
                if let old = dir { try? FileManager.default.removeItem(at: old) }
                dir = fresh
                return fresh
            }
        }

        private static func makePrivateDir() throws -> URL {
            let template = FileManager.default.temporaryDirectory.appendingPathComponent("dltidy-magick-XXXXXX").path
            var buf = Array(template.utf8CString)
            guard mkdtemp(&buf) != nil else {
                throw MediaError.failed("cannot create ImageMagick policy dir: \(String(cString: strerror(errno)))")
            }
            let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }
}
