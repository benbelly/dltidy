import Foundation
import DLTidyKit

enum NamingOutcome: Equatable {
    case rename(slug: String)
    case keep(String)
    case wait(String)
}

extension Engine {
    /// The member whose content names the group: a still image (Live Photo), then video, then any.
    func primary(_ members: [Item]) -> Item {
        members.first { $0.mediaKind == .stillImage }
            ?? members.first { $0.mediaKind == .video || $0.mediaKind == .animatedImage }
            ?? members[0]
    }

    // MARK: - Initial naming (before any output exists)

    func initialNaming(_ g: Int64, members: [Item]) async throws {
        let all = try ledger.group(g).filter { $0.state != .failedUnreadable && $0.state != .failedPoison }
        // Live Photo: a video beside a still of the same stem gets no mp4/gif.
        if all.contains(where: { $0.mediaKind == .stillImage }) {
            for m in members where m.mediaKind == .video {
                try ledger.db.run("UPDATE items SET is_live_video = 1 WHERE id = ?", m.id)
            }
        }
        let current = try ledger.group(g).filter { $0.state == .naming }
        guard !current.isEmpty else { return }
        let leader = primary(current)

        switch leader.nameStatus {
        case .renaming:
            try finishRename(g)
        case .none, .waitClassify, .waitName:
            let outcome = try await resolveName(g, leader: leader, deferred: false)
            try await apply(outcome, group: g, members: current, deferred: false)
        default:
            break
        }
        try ledger.db.run("UPDATE items SET state = 'convert', updated_at = ? WHERE group_id = ? AND role = 'original' AND state = 'naming'",
                          now, g)
    }

    private func apply(_ outcome: NamingOutcome, group g: Int64, members: [Item], deferred: Bool) async throws {
        switch outcome {
        case .rename(let slug):
            let fresh = try ledger.group(g)
            guard let stem = try chooseStem(slug: slug, members: fresh, includePlanned: !deferred) else {
                try ledger.setGroupNameStatus(g, .keep, now: now)
                log.info("no free name for slug \(slug) (tried -2…-99); keeping names")
                return
            }
            try ledger.db.transaction {
                try ledger.db.run("""
                    UPDATE items SET slug = ?, name_status = 'renaming', assigned_name = COALESCE(CASE WHEN ? THEN assigned_name END, path)
                    WHERE group_id = ? AND role = 'original'
                    """, stem, deferred, g)
            }
            try env.failpoints.hit("after-name-decided")
            try finishRename(g)
        case .keep(let reason):
            try ledger.setGroupNameStatus(g, .keep, now: now)
            log.info("name kept for group #\(g): \(reason)")
        case .wait(let reason):
            if !deferred {
                // The app-assigned path a deferred rename will look for.
                try ledger.db.run("UPDATE items SET assigned_name = path WHERE group_id = ? AND role = 'original'", g)
                log.info("naming deferred for group #\(g): \(reason); converting under the old name")
            }
        }
    }

    /// Decides the group's name, spending at most one request per call. All requests go through
    /// `Budget.reserve` and the `NamingGate`.
    func resolveName(_ g: Int64, leader: Item, deferred: Bool) async throws -> NamingOutcome {
        var status = leader.nameStatus
        if status == .none {
            switch env.rules.classify(filename: leader.path) {
            case .meaningful:
                return .keep("meaningful name")
            case .generic:
                status = .waitName
            case .unclear:
                status = .waitClassify
            }
            try ledger.setGroupNameStatus(g, status, now: now)
        }

        if status == .waitClassify {
            if let blocked = try budget.availability(.classify, groupID: g) { return blockedOutcome(blocked) }
            guard let key = env.apiKey() else { return missingKey() }
            let reservation = try budget.reserve(.classify, leader: try ledger.item(leader.id) ?? leader,
                                                 estimatedTokens: config.estimatedTokensClassify)
            guard case .granted(let ticket) = reservation else { return blockedOutcome(reservation) }
            try env.failpoints.hit("after-reserve")
            let result = await gate.classify(ticket, stem: env.rules.baseStem(of: leader.path), apiKey: key)
            try env.failpoints.hit("after-request")
            try budget.record(ticket, CallOutcome(result))
            switch result {
            case .ok(true, _):
                try ledger.setGroupNameStatus(g, .waitName, now: now)
                log.info("model: name \(leader.path) is generic")
            case .ok(false, _):
                return .keep("model: name is meaningful")
            default:
                return .keep("classification not answered (\(CallOutcome(result).statusText))")
            }
        }

        // Naming request.
        let t = now
        if let next = (try ledger.item(leader.id))?.nextNameAt, next > t { return .wait("retry at \(Int(next - t)) s") }
        if let blocked = try budget.availability(.name, groupID: g) { return blockedOutcome(blocked) }
        guard let key = env.apiKey() else { return missingKey() }
        let clone: URL
        switch cloneOriginal(leader) {
        case .ok(let url): clone = url
        case .missing: return .keep("original gone")
        case .changed: return .keep("original changed")
        }
        // Extraction decodes untrusted content in-process. The main path counts it in work_starts per
        // group pass; a deferred attempt counts here, so a crash in the extractor poisons the item
        // after `poisonThreshold` attempts instead of looping across restarts.
        if deferred {
            try ledger.db.run("UPDATE items SET work_starts = work_starts + 1 WHERE id = ?", leader.id)
        }
        try env.failpoints.hit("during-extract")
        let payload = await env.extractor.extract(from: clone, sourceExtension: leader.ext.lowercased())
        if deferred {
            try ledger.db.run("UPDATE items SET work_starts = 0 WHERE id = ?", leader.id)
        }
        if deferred && !leader.state.isActiveOriginal { FS.removeTree(stagingDir(leader.id)) }
        guard let payload else { return .keep("content not nameable") }
        let est: Int
        switch payload {
        case .image: est = config.estimatedTokensImage
        case .text: est = config.estimatedTokensText
        }
        let reservation = try budget.reserve(.name, leader: try ledger.item(leader.id) ?? leader, estimatedTokens: est)
        guard case .granted(let ticket) = reservation else { return blockedOutcome(reservation) }
        try env.failpoints.hit("after-reserve")
        let result = await gate.suggest(ticket, payload: payload, originalName: leader.path, apiKey: key)
        try env.failpoints.hit("after-request")
        try budget.record(ticket, CallOutcome(result))

        let attempts = try budget.groupCounts(g).name
        switch result {
        case .ok(let s, _):
            if s.confidence == .low { return .keep("low confidence (\(s.name))") }
            guard let slug = env.rules.slug(from: s.name) else { return .keep("invalid slug from \"\(s.name)\"") }
            return .rename(slug: slug)
        case .final(let reason, _):
            return .keep("API final: \(reason)")
        case .transient(let reason):
            guard attempts < config.maxNamingRequestsPerGroup else { return .keep("second attempt failed: \(reason)") }
            try ledger.db.run("UPDATE items SET next_name_at = ? WHERE group_id = ? AND role = 'original'",
                              now + config.transientRetryDelay, g)
            return .wait("transient failure (\(reason)); one retry in \(Int(config.transientRetryDelay)) s")
        case .rateLimited:
            guard attempts < config.maxNamingRequestsPerGroup else { return .keep("rate limited; attempts used") }
            return .wait("rate limited")
        case .authFailure(let status):
            guard attempts < config.maxNamingRequestsPerGroup else { return .keep("HTTP \(status); attempts used") }
            return .wait("API key rejected (HTTP \(status))")
        }
    }

    private func blockedOutcome(_ r: Reservation) -> NamingOutcome {
        switch r {
        case .wait(let why): return .wait(why)
        case .exhausted(let why): return .keep(why)
        case .granted: return .wait("unexpected grant")
        }
    }

    private func missingKey() -> NamingOutcome {
        notices.raise("health-key", title: "dltidy: no API key",
                      body: "Run `dltidy set-key`. Files are converted under their old names until then.")
        return .wait("no API key")
    }

    // MARK: - Stem choice and renames

    /// `slug`, `slug-2` … `slug-99`: the first stem free (case-insensitive) for every member's
    /// extension, every output to be renamed and, before conversion, every planned output.
    func chooseStem(slug: String, members: [Item], includePlanned: Bool) throws -> String? {
        let names = Set(try FS.listNames(config.watchDir).map { $0.lowercased() })
        var own = Set<String>()
        var exts: [String] = []
        for m in members where m.missingSince == nil && (m.path == m.assignedName || m.assignedName == nil) {
            own.insert(m.path.lowercased())
            exts.append(m.ext.lowercased())
            if includePlanned, let info = m.mediaInfo {
                let planned = env.media.plannedOutputs(info: info, sourceExtension: m.ext.lowercased(), isLivePhotoVideo: m.isLiveVideo)
                exts.append(contentsOf: planned.map(\.rawValue))
            }
            for o in try ledger.outputs(parent: m.id) where o.state == .placed && o.missingSince == nil {
                own.insert(o.path.lowercased())
                if let f = o.format { exts.append(f) }
            }
        }
        for n in 1...99 {
            let stem = n == 1 ? slug : "\(slug)-\(n)"
            let free = exts.allSatisfy { ext in
                let candidate = (ext.isEmpty ? stem : "\(stem).\(ext)").lowercased()
                return !names.contains(candidate) || own.contains(candidate)
            }
            if free { return stem }
        }
        return nil
    }

    /// Renames every member still at its assigned path, then every placed output still at its
    /// assigned path, to the stored stem. Idempotent: done actions are skipped.
    func finishRename(_ g: Int64) throws {
        let members = try ledger.group(g)
        guard let stem = members.first?.slug else {
            try ledger.setGroupNameStatus(g, .keep, now: now)
            return
        }
        for m in members {
            if [.skippedChanged, .abandoned, .failedPoison, .failedUnreadable].contains(m.state) { continue }
            let key = "rename:\(m.id)"
            if try ledger.actionExists(key: key) { continue }
            guard m.missingSince == nil, m.path == m.assignedName else {
                log.info("not renamed (moved or renamed by user): \(m.path)")
                continue
            }
            guard verifyIdentity(m) else {
                if m.state == .naming {
                    try ledger.setState(m.id, .skippedChanged, note: "changed before rename", now: now)
                    FS.removeTree(stagingDir(m.id))
                }
                log.info("not renamed (changed): \(m.path)")
                continue
            }
            let ext = m.ext.lowercased()
            _ = try performRename(m, to: ext.isEmpty ? stem : "\(stem).\(ext)", kind: .rename, key: key)
        }
        for m in members {
            for o in try ledger.outputs(parent: m.id) where o.state == .placed {
                let key = "rename:\(o.id)"
                if try ledger.actionExists(key: key) { continue }
                guard o.missingSince == nil, o.path == o.assignedName, let format = o.format else { continue }
                guard let url = watchURL(o.path, for: "rename output"), let cur = try FS.lstatEntry(url), cur.inode == o.inode else { continue }
                _ = try performRename(o, to: "\(stem).\(format)", kind: .rename, key: key)
            }
        }
        try ledger.setGroupNameStatus(g, .renamed, now: now)
    }

    // MARK: - Deferred rename

    /// Groups converted under the old name while naming was unavailable: retried until 24 h
    /// after first_seen, then the old name is final.
    func advanceDeferred() async throws {
        let groups = try ledger.db.query("""
            SELECT DISTINCT group_id FROM items WHERE role = 'original' AND group_id IS NOT NULL
              AND name_status IN ('waitClassify', 'waitName', 'renaming') AND state NOT IN ('probe', 'naming')
            ORDER BY group_id
            """) { $0.int(0) }
        for g in groups {
            guard canProcess else { return }
            let members = try ledger.group(g)
            if members.contains(where: { $0.state == .probe || $0.state == .naming }) { continue }
            let leader = primary(members)
            if leader.nameStatus == .renaming {
                try finishRename(g)
                continue
            }
            if leader.workStarts >= config.poisonThreshold {
                try ledger.setState(leader.id, .failedPoison,
                                    note: "deferred naming: \(leader.workStarts) starts without completion", now: now)
                try ledger.setGroupNameStatus(g, .keep, now: now)
                FS.removeTree(stagingDir(leader.id))
                log.error("failed_poison: \(leader.path) #\(leader.id) after \(leader.workStarts) unfinished deferred naming starts; name kept")
                continue
            }
            let firstSeen = members.map(\.firstSeen).min() ?? leader.firstSeen
            if now >= firstSeen + config.deferredRenameWindow {
                try ledger.setGroupNameStatus(g, .expired, now: now)
                log.info("deferred rename window passed; names final for group #\(g)")
                continue
            }
            if let next = leader.nextNameAt, next > now { continue }
            let renameable = members.contains { m in
                m.missingSince == nil && m.path == m.assignedName && ![.skippedChanged, .abandoned].contains(m.state)
            }
            guard renameable else {
                try ledger.setGroupNameStatus(g, .keep, now: now)
                log.info("deferred rename dropped for group #\(g): originals moved or renamed by user")
                continue
            }
            do {
                let outcome = try await resolveName(g, leader: leader, deferred: true)
                try await apply(outcome, group: g, members: members, deferred: true)
            } catch let crash as SimulatedCrash {
                throw crash
            } catch let fuse as FuseTripped {
                throw fuse
            } catch {
                log.error("deferred rename for group #\(g) failed: \(error)")
            }
        }
    }

    // MARK: - Undo

    /// Restores the old names of a renamed group's originals and present copies. The group gets
    /// no further renames.
    func undo(_ target: String?) throws -> String {
        let groupID: Int64?
        if let target, !target.isEmpty {
            guard FS.isSafeName(target) else { return "not a file name: \(target)" }
            guard let item = try ledger.items(where: """
                path = ? COLLATE NOCASE AND missing_since IS NULL AND role IN ('original', 'output') ORDER BY id DESC LIMIT 1
                """, [target]).first else { return "no file named \(target) in the ledger" }
            if item.role == .output, let parent = item.parentID {
                groupID = try ledger.item(parent)?.groupID
            } else {
                groupID = item.groupID
            }
        } else {
            groupID = try ledger.db.scalarInt("""
                SELECT i.group_id FROM actions a JOIN items i ON i.id = a.item_id
                WHERE a.kind = 'rename' AND a.status = 'done' AND i.role = 'original' AND i.name_status = 'renamed'
                ORDER BY a.id DESC LIMIT 1
                """)
        }
        guard let g = groupID else { return "nothing to undo" }
        let members = try ledger.group(g)
        guard members.first?.nameStatus == .renamed else { return "group #\(g) was not renamed by dltidy" }
        var restored: [String] = []
        var skipped = 0
        for m in members where m.missingSince == nil && m.path == m.assignedName && m.path != m.originalName {
            // Names come from the ledger, which any process of the user can write: each one must be a
            // single component, and each file must still be the one dltidy recorded.
            guard FS.isSafeName(m.originalName) else {
                log.warn("undo skipped for #\(m.id): unsafe original name \(m.originalName)")
                skipped += 1
                continue
            }
            guard verifyIdentity(m) else {
                log.warn("undo skipped for #\(m.id) \(m.path): file differs from the ledger record")
                skipped += 1
                continue
            }
            for o in try ledger.outputs(parent: m.id) where o.state == .placed && o.missingSince == nil && o.path == o.assignedName {
                guard let format = o.format else { continue }
                guard verifyIdentity(o) else {
                    log.warn("undo skipped for output #\(o.id) \(o.path): file differs from the ledger record")
                    skipped += 1
                    continue
                }
                let back = "\(m.originalName.fileStem).\(format)"
                if try performRename(o, to: back, kind: .undo, key: "undo:\(o.id)") { restored.append(back) } else { skipped += 1 }
            }
            if try performRename(m, to: m.originalName, kind: .undo, key: "undo:\(m.id)") { restored.append(m.originalName) } else { skipped += 1 }
        }
        try ledger.setGroupNameStatus(g, .undone, now: now)
        let note = skipped > 0 ? " (\(skipped) skipped; see the log)" : ""
        return (restored.isEmpty ? "nothing restored (files moved or renamed)" : "restored: " + restored.joined(separator: ", ")) + note
    }
}
