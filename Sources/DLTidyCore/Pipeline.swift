import Foundation
import DLTidyKit

enum CloneResult {
    case ok(URL)
    case missing
    case changed
}

extension Engine {
    // MARK: - Readiness → staging

    /// Promotes ready candidates of a settled batch: clone into staging, hash, then in one
    /// transaction mark duplicates, accept originals and assign stem groups.
    func promoteReady(_ entries: [DirEntry]) async throws {
        let t = now
        let candidates = try ledger.items(where: "role = 'candidate' AND missing_since IS NULL ORDER BY id")
        guard let newest = candidates.map(\.firstSeen).max() else { return }
        let names = Set(entries.map { $0.name.lowercased() })
        let ready = candidates.filter {
            readiness.verdict($0, names: names, now: t) == .ready && readiness.settled($0, newestFirstSeen: newest, now: t)
        }
        guard !ready.isEmpty else { return }

        var ignored: [Item] = []
        var staged: [(item: Item, sha: String)] = []
        for c in ready {
            if !env.isProcessableExtension(c.ext.lowercased()) {
                ignored.append(c)
                continue
            }
            switch cloneOriginal(c) {
            case .ok(let clone):
                do {
                    staged.append((c, try FS.sha256(clone)))
                } catch {
                    log.error("hash of staged \(c.path) failed: \(error)")
                    FS.removeTree(stagingDir(c.id))
                }
            case .missing, .changed:
                continue   // the next scan updates or resets the candidate
            }
        }

        var duplicates: [Int64] = []
        try ledger.db.transaction {
            for c in ignored {
                try ledger.db.run("UPDATE items SET role = 'ignored', state = 'known', updated_at = ? WHERE id = ?", t, c.id)
                log.info("ignored (type not converted or named): \(c.path)")
            }
            var batchHashes = Set<String>()
            var accepted: [Item] = []
            for (c, sha) in staged {
                let known = try ledger.hashKnown(sha, excluding: c.id)
                if batchHashes.contains(sha) || known != nil {
                    try ledger.db.run("UPDATE items SET role = 'duplicate', state = 'known', sha256 = ?, updated_at = ? WHERE id = ?",
                                      sha, t, c.id)
                    duplicates.append(c.id)
                    log.info("duplicate bytes, skipped: \(c.path)")
                    continue
                }
                batchHashes.insert(sha)
                try ledger.db.run("UPDATE items SET role = 'original', state = 'probe', sha256 = ?, updated_at = ? WHERE id = ?",
                                  sha, t, c.id)
                accepted.append(c)
            }
            var byStem: [String: [Int64]] = [:]
            for o in accepted {
                byStem[env.rules.baseStem(of: o.path).lowercased(), default: []].append(o.id)
            }
            for ids in byStem.values {
                let gid = ids.min()!
                for id in ids { try ledger.db.run("UPDATE items SET group_id = ? WHERE id = ?", gid, id) }
            }
            for o in accepted { log.info("new original: \(o.path) #\(o.id)") }
        }
        for id in duplicates { FS.removeTree(stagingDir(id)) }
        try env.failpoints.hit("after-stage")
    }

    /// Clones the file at the item's ledger path into staging after checking that it is still the
    /// same inode with the same size and mtime.
    func cloneOriginal(_ item: Item) -> CloneResult {
        let src = config.watchDir.appendingPathComponent(item.path)
        guard let cur = try? FS.lstatEntry(src), cur.kind == .regular, cur.dev == item.dev, cur.inode == item.inode else {
            return .missing
        }
        guard cur.size == item.size, cur.mtimeNs == item.mtimeNs else { return .changed }
        let dir = stagingDir(item.id)
        let ext = item.ext.lowercased()
        let clone = dir.appendingPathComponent(ext.isEmpty ? "in" : "in.\(ext)")
        if FileManager.default.fileExists(atPath: clone.path) { return .ok(clone) }
        do {
            try FS.makeDir(dir)
            try FS.clone(src, to: clone)
            notices.clear("staging")
            return .ok(clone)
        } catch {
            log.error("clone of \(item.path) failed: \(error)")
            notices.raise("staging", title: "dltidy cannot clone files",
                          body: "Cloning into \(config.stagingDir.path) failed (\(error)). Downloads and the state folder must be on the same APFS volume.")
            FS.removeTree(dir)
            return .missing
        }
    }

    // MARK: - Groups

    func advanceGroups() async throws {
        let groups = try ledger.db.query("""
            SELECT DISTINCT group_id FROM items
            WHERE role = 'original' AND state IN ('probe', 'naming', 'convert') AND group_id IS NOT NULL ORDER BY group_id
            """) { $0.int(0) }
        for g in groups {
            guard canProcess else { return }
            do {
                try await advanceGroup(g)
            } catch let crash as SimulatedCrash {
                throw crash
            } catch let fuse as FuseTripped {
                throw fuse
            } catch {
                // work_starts stays incremented: three failing passes poison the item.
                log.error("group #\(g) failed: \(error)")
                _ = try? ledger.db.run("""
                    UPDATE items SET next_attempt_at = ? WHERE group_id = ? AND role = 'original' AND state IN ('probe', 'naming', 'convert')
                    """, now + config.errorRetry, g)
            }
        }
    }

    func advanceGroup(_ g: Int64) async throws {
        let t = now
        var active = try ledger.group(g).filter { $0.state.isActiveOriginal }
        for m in active where m.workStarts >= config.poisonThreshold {
            try ledger.setState(m.id, .failedPoison, note: "\(m.workStarts) starts without completion", now: t)
            log.error("failed_poison: \(m.path) #\(m.id) after \(m.workStarts) unfinished starts")
            FS.removeTree(stagingDir(m.id))
        }
        active = active.filter { $0.workStarts < config.poisonThreshold }
        guard active.contains(where: { ($0.nextAttemptAt ?? 0) <= t }) else { return }
        let ids = active.map { String($0.id) }.joined(separator: ",")
        try ledger.db.run("UPDATE items SET work_starts = work_starts + 1 WHERE id IN (\(ids))")

        // Rule 8: decode check on the clone.
        for m in active where m.state == .probe && (m.nextAttemptAt ?? 0) <= t {
            try await probe(m)
        }
        active = try ledger.group(g).filter { $0.state.isActiveOriginal }
        if active.contains(where: { $0.state == .probe }) {
            try resetWorkStarts(g)
            return
        }

        // Naming, once per group, before any output exists.
        let naming = active.filter { $0.state == .naming }
        if !naming.isEmpty {
            try await initialNaming(g, members: naming)
        }

        for m in try ledger.group(g) where m.state == .convert && (m.nextAttemptAt ?? 0) <= now {
            try await convert(m)
        }
        try env.failpoints.hit("after-group")
        try resetWorkStarts(g)
    }

    private func resetWorkStarts(_ g: Int64) throws {
        try ledger.db.run("UPDATE items SET work_starts = 0 WHERE group_id = ? AND role = 'original'", g)
    }

    // MARK: - Probe (readiness rule 8)

    func probe(_ m: Item) async throws {
        let t = now
        let clone: URL
        switch cloneOriginal(m) {
        case .ok(let url): clone = url
        case .missing:
            try ledger.setState(m.id, .abandoned, note: "original gone before probe", now: t)
            log.info("original gone, nothing done: \(m.path)")
            return
        case .changed:
            try ledger.setState(m.id, .skippedChanged, note: "changed before probe", now: t)
            log.info("skipped_changed: \(m.path)")
            return
        }
        do {
            let info = try await env.media.probe(clone, sourceExtension: m.ext.lowercased())
            try ledger.db.run("""
                UPDATE items SET state = 'naming', media_kind = ?, duration = ?, is_hdr = ?, width = ?, height = ?,
                  next_attempt_at = NULL, updated_at = ? WHERE id = ?
                """, info.kind.rawValue, info.durationSeconds, info.isHDR, info.width, info.height, now, m.id)
        } catch MediaError.notMedia {
            try ledger.db.run("UPDATE items SET state = 'naming', next_attempt_at = NULL, updated_at = ? WHERE id = ?", now, m.id)
        } catch MediaError.toolMissing(let tool) {
            raiseToolMissing(tool)
            try ledger.db.run("UPDATE items SET next_attempt_at = ? WHERE id = ?", now + config.toolMissingRetry, m.id)
        } catch {
            let failures = m.decodeFailures + 1
            FS.removeTree(stagingDir(m.id))
            if failures > config.decodeRetryDelays.count {
                try ledger.db.run("UPDATE items SET state = 'failed_unreadable', decode_failures = ?, note = ?, updated_at = ? WHERE id = ?",
                                  failures, "\(error)", now, m.id)
                log.warn("failed_unreadable: \(m.path) (\(error)); no API call")
            } else {
                let delay = config.decodeRetryDelays[failures - 1]
                try ledger.db.run("UPDATE items SET decode_failures = ?, next_attempt_at = ?, note = ? WHERE id = ?",
                                  failures, now + delay, "\(error)", m.id)
                log.info("decode failed for \(m.path) (\(error)); retry \(failures) in \(Int(delay)) s")
            }
        }
        try env.failpoints.hit("after-probe")
    }

    func raiseToolMissing(_ tool: String) {
        notices.raise("tool-\(tool)", title: "dltidy: \(tool) not found",
                      body: "Install it (brew install ffmpeg imagemagick). Affected files wait and resume when it is back.")
    }

    // MARK: - Convert and place

    func convert(_ m: Item) async throws {
        guard let info = m.mediaInfo else {
            try finish(m)
            return
        }
        let planned = env.media.plannedOutputs(info: info, sourceExtension: m.ext.lowercased(), isLivePhotoVideo: m.isLiveVideo)
        for format in planned {
            let existing = try ledger.items(where: "role = 'output' AND parent_id = ? AND format = ?", [m.id, format.rawValue])
            if !existing.isEmpty { continue }

            // Re-read: the original may have been renamed by the user since the pass began.
            guard let cur = try ledger.item(m.id) else { return }
            guard verifyIdentity(cur) else {
                let gone = (try? FS.lstatEntry(config.watchDir.appendingPathComponent(cur.path))) == nil
                try ledger.setState(m.id, gone ? .abandoned : .skippedChanged, note: "original changed or gone before output", now: now)
                log.info("\(gone ? "abandoned" : "skipped_changed"): \(cur.path); no further outputs")
                FS.removeTree(stagingDir(m.id))
                return
            }
            let newStem = cur.path.fileStem
            let oldStem = cur.originalName.fileStem
            let target = "\(newStem).\(format.rawValue)"
            let names = Set(try FS.listNames(config.watchDir).map { $0.lowercased() })
            if names.contains("\(oldStem).\(format.rawValue)".lowercased()) || names.contains(target.lowercased()) {
                try recordOutputSkip(cur, format: format, target: target, state: .skippedExists, note: "sibling exists")
                log.info("output \(format.rawValue) skipped for \(cur.path): sibling exists")
                continue
            }
            let need = (cur.size ?? 0) * config.outputSizeFactor + config.minFreeBytes
            if let free = env.freeSpace(config.stateDir), free < need {
                notices.raise("disk-space", title: "dltidy: low disk space",
                              body: "Conversions wait until \(need / (1 << 30)) GB is free.")
                try ledger.db.run("UPDATE items SET next_attempt_at = ? WHERE id = ?", now + config.diskSpaceRetry, m.id)
                cleanStaging(keep: Set(try activeOriginalIDs()))
                return
            }
            notices.clear("disk-space")

            let clone: URL
            switch cloneOriginal(cur) {
            case .ok(let url): clone = url
            case .missing, .changed:
                try ledger.setState(m.id, .skippedChanged, note: "clone failed before output", now: now)
                return
            }
            let dir = stagingDir(m.id)
            let work = dir.appendingPathComponent("work", isDirectory: true)
            try FS.makeDir(work)
            let staged = dir.appendingPathComponent("out.\(format.rawValue)")
            try? FileManager.default.removeItem(at: staged)
            do {
                try await env.media.convert(input: clone, info: info, to: format, output: staged, workDir: work,
                                            allowLongEncode: env.power.allowLongEncode())
            } catch MediaError.deferred(let why) {
                try ledger.db.run("UPDATE items SET next_attempt_at = ? WHERE id = ?", now + config.longEncodeRetry, m.id)
                log.info("conversion of \(cur.path) waits: \(why)")
                return
            } catch MediaError.toolMissing(let tool) {
                raiseToolMissing(tool)
                try ledger.db.run("UPDATE items SET next_attempt_at = ? WHERE id = ?", now + config.toolMissingRetry, m.id)
                return
            } catch {
                try recordOutputSkip(cur, format: format, target: target, state: .failed, note: "\(error)")
                log.warn("output \(format.rawValue) for \(cur.path) failed: \(error)")
                try? FileManager.default.removeItem(at: staged)
                continue
            }
            try env.failpoints.hit("after-convert")
            guard FileManager.default.fileExists(atPath: staged.path) else {
                try recordOutputSkip(cur, format: format, target: target, state: .failed, note: "converter wrote nothing")
                continue
            }
            try place(cur, format: format, staged: staged, target: target)
        }
        try finish(m)
    }

    private func finish(_ m: Item) throws {
        try ledger.db.run("UPDATE items SET state = 'done', next_attempt_at = NULL, updated_at = ? WHERE id = ? AND state = 'convert'",
                          now, m.id)
        FS.removeTree(stagingDir(m.id))
    }

    func activeOriginalIDs() throws -> [Int64] {
        try ledger.db.query("SELECT id FROM items WHERE role = 'original' AND state IN ('probe', 'naming', 'convert')") { $0.int(0) }
    }

    /// True when the original is at its ledger path with the inode, size and mtime recorded at staging.
    func verifyIdentity(_ item: Item) -> Bool {
        guard let cur = try? FS.lstatEntry(config.watchDir.appendingPathComponent(item.path)) else { return false }
        return cur.kind == .regular && cur.dev == item.dev && cur.inode == item.inode && cur.size == item.size && cur.mtimeNs == item.mtimeNs
    }

    private func recordOutputSkip(_ m: Item, format: OutputFormat, target: String, state: ItemState, note: String) throws {
        try ledger.db.run("""
            INSERT INTO items(role, state, path, original_name, parent_id, format, first_seen, note, updated_at)
            VALUES('output', ?, ?, ?, ?, ?, ?, ?, ?)
            """, state.rawValue, target, target, m.id, format.rawValue, now, note, now)
    }

    /// Output placement: xattr + ledger row committed first, then an atomic no-overwrite move.
    func place(_ m: Item, format: OutputFormat, staged: URL, target: String) throws {
        let key = "place:\(m.id):\(format.rawValue)"
        try checkFuse(key)
        try FS.setXattr(staged, name: FS.roleXattr, value: "output")
        try FS.setXattr(staged, name: FS.itemXattr, value: String(m.id))
        let sha = try FS.sha256(staged)
        guard let st = try FS.lstatEntry(staged) else { return }
        let t = now
        let (outID, actionID): (Int64, Int64) = try ledger.db.transaction {
            try ledger.db.run("""
                INSERT INTO items(role, state, dev, inode, size, mtime_ns, path, original_name, assigned_name, parent_id, format,
                                  sha256, first_seen, updated_at)
                VALUES('output', 'placing', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, st.dev, st.inode, st.size, st.mtimeNs, target, target, target, m.id, format.rawValue, sha, t, t)
            let outID = ledger.db.lastInsertID
            let actionID = try ledger.insertAction(at: t, itemID: outID, kind: "place", key: key, from: m.path, to: target)
            return (outID, actionID)
        }
        try env.failpoints.hit("before-place")
        do {
            try FS.renameExclusive(staged, to: config.watchDir.appendingPathComponent(target))
        } catch let f as POSIXFailure {
            try ledger.db.transaction {
                try ledger.db.run("DELETE FROM actions WHERE id = ?", actionID)
                try ledger.db.run("UPDATE items SET state = 'skipped_exists', dev = NULL, inode = NULL, note = ? WHERE id = ?", "\(f)", outID)
            }
            try? FileManager.default.removeItem(at: staged)
            log.warn("output \(target) not placed: \(f)")
            return
        }
        try env.failpoints.hit("after-place")
        try ledger.db.transaction {
            try ledger.db.run("UPDATE items SET state = 'placed' WHERE id = ?", outID)
            try ledger.db.run("UPDATE actions SET status = 'done' WHERE id = ?", actionID)
        }
        notices.clearPrefix("tool-")
        log.info("placed: \(target) (from \(m.path))")
        emit(ActionEvent(kind: .place, itemID: m.id, from: m.path, to: target))
    }
}
