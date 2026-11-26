import CryptoKit
import Darwin
import Foundation

public struct POSIXFailure: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let path: String
    public let code: Int32
    public var description: String { "\(operation) \(path): \(String(cString: strerror(code))) (\(code))" }
}

public enum EntryKind: Sendable, Equatable { case regular, directory, symlink, other }

/// One top-level entry of the watch directory, from `readdir` + `lstat`.
public struct DirEntry: Sendable, Equatable {
    public var name: String
    public var dev: Int64
    public var inode: Int64
    public var size: Int64
    public var mtimeNs: Int64
    public var kind: EntryKind
}

/// File-system primitives. All calls use POSIX directly so failures carry an errno.
public enum FS {
    public static let roleXattr = "local.dltidy.role"
    public static let itemXattr = "local.dltidy.item"

    /// Lists the top level of `dir`. Any read failure throws; an unreadable directory is never
    /// reported as empty. An entry that vanishes between readdir and lstat is left out.
    public static func scanTopLevel(_ dir: URL) throws -> [DirEntry] {
        guard let dp = opendir(dir.path) else { throw POSIXFailure(operation: "opendir", path: dir.path, code: errno) }
        defer { closedir(dp) }
        let fd = dirfd(dp)
        var out: [DirEntry] = []
        while true {
            errno = 0
            guard let ent = readdir(dp) else {
                if errno != 0 { throw POSIXFailure(operation: "readdir", path: dir.path, code: errno) }
                break
            }
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw POSIXFailure(operation: "lstat", path: name, code: errno)
            }
            out.append(entry(name: name, st))
        }
        return out
    }

    /// Names only (no lstat), for sibling and collision checks.
    public static func listNames(_ dir: URL) throws -> [String] {
        guard let dp = opendir(dir.path) else { throw POSIXFailure(operation: "opendir", path: dir.path, code: errno) }
        defer { closedir(dp) }
        var out: [String] = []
        while true {
            errno = 0
            guard let ent = readdir(dp) else {
                if errno != 0 { throw POSIXFailure(operation: "readdir", path: dir.path, code: errno) }
                break
            }
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    /// lstat of one path; nil when it does not exist.
    public static func lstatEntry(_ url: URL) throws -> DirEntry? {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw POSIXFailure(operation: "lstat", path: url.path, code: errno)
        }
        return entry(name: url.lastPathComponent, st)
    }

    static func entry(name: String, _ st: stat) -> DirEntry {
        let kind: EntryKind
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return DirEntry(name: name, dev: Int64(st.st_dev), inode: Int64(bitPattern: st.st_ino),
                        size: Int64(st.st_size), mtimeNs: mtime, kind: kind)
    }

    /// APFS clone (copy-on-write). Fails across volumes.
    public static func clone(_ src: URL, to dst: URL) throws {
        if clonefile(src.path, dst.path, UInt32(CLONE_NOFOLLOW)) != 0 {
            throw POSIXFailure(operation: "clonefile", path: src.path, code: errno)
        }
    }

    /// Atomic rename that never overwrites. Throws `POSIXFailure` with `EEXIST` when `dst` exists.
    public static func renameExclusive(_ src: URL, to dst: URL) throws {
        if renamex_np(src.path, dst.path, UInt32(RENAME_EXCL)) != 0 {
            throw POSIXFailure(operation: "renamex_np", path: "\(src.path) -> \(dst.path)", code: errno)
        }
    }

    public static func setXattr(_ url: URL, name: String, value: String) throws {
        let data = Array(value.utf8)
        let rc = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        if rc != 0 { throw POSIXFailure(operation: "setxattr", path: url.path, code: errno) }
    }

    public static func getXattr(_ url: URL, name: String) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        let read = buf.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read >= 0 else { return nil }
        return String(decoding: buf.prefix(read), as: UTF8.self)
    }

    public static func removeXattr(_ url: URL, name: String) {
        removexattr(url.path, name, XATTR_NOFOLLOW)
    }

    /// SHA-256 of a file, hex. If `expectInode` is given, the open file must have that inode.
    public static func sha256(_ url: URL, expectInode: Int64? = nil) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXFailure(operation: "open", path: url.path, code: errno) }
        defer { close(fd) }
        if let expectInode {
            var st = stat()
            guard fstat(fd, &st) == 0 else { throw POSIXFailure(operation: "fstat", path: url.path, code: errno) }
            guard Int64(bitPattern: st.st_ino) == expectInode else {
                throw POSIXFailure(operation: "inode-check", path: url.path, code: ESTALE)
            }
        }
        var hasher = SHA256()
        let chunk = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = read(fd, buf, chunk)
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXFailure(operation: "read", path: url.path, code: errno)
            }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes available for important usage on the volume holding `url`.
    public static func freeSpace(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public static func removeTree(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public static func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

extension String {
    /// Extension after the last dot (no dot → ""), as written.
    var fileExtension: String {
        guard let dot = lastIndex(of: "."), dot != startIndex else { return "" }
        return String(self[index(after: dot)...])
    }

    /// Name without its last extension.
    var fileStem: String {
        guard let dot = lastIndex(of: "."), dot != startIndex else { return self }
        return String(self[..<dot])
    }
}
