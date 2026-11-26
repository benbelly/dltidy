import Foundation

/// Readiness rules 1–3, 5 and 7 for one candidate. Rule 4 (unknown inode, not a replacement) is
/// decided in reconcile, rule 6 (batch settle) over all candidates, rule 8 (clone + decode) in
/// the pipeline.
struct Readiness {
    let config: Config

    enum Verdict: Equatable {
        case ready
        case hidden, partialExtension, partialSibling, empty, unstable, tooYoung
    }

    func verdict(_ c: Item, names: Set<String>, now: Double) -> Verdict {
        // 1. Regular file (only regular files become candidates), not hidden.
        if c.path.hasPrefix(".") { return .hidden }
        // 2. Not a partial download, and no partial sibling.
        if config.partialExtensions.contains(c.ext.lowercased()) { return .partialExtension }
        for suffix in config.partialSiblingSuffixes where names.contains("\(c.path).\(suffix)".lowercased()) {
            return .partialSibling
        }
        // 3. Non-empty.
        if (c.size ?? 0) <= 0 { return .empty }
        // 5. (inode, size, mtime_ns) unchanged across N scans spanning the minimum time.
        if c.stableCount < config.stableScans || now - (c.stableSince ?? now) < config.stableSpan { return .unstable }
        // 7. Old enough that a click in the browser's download bar works first. Counted from
        // first_seen, or from the last rename while waiting, whichever is later.
        if now - max(c.firstSeen, c.pathSince ?? 0) < config.minAge { return .tooYoung }
        return .ready
    }

    /// Rule 6: no new candidate for `batchSettle` seconds, or this candidate waited `batchMaxWait`.
    func settled(_ c: Item, newestFirstSeen: Double, now: Double) -> Bool {
        now - newestFirstSeen >= config.batchSettle || now - c.firstSeen >= config.batchMaxWait
    }
}
