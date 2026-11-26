import Foundation
import DLTidyKit

public struct HealthCheck: Sendable, Equatable {
    public var name: String
    public var ok: Bool
    public var detail: String
    /// A blocking failure stops processing until it passes.
    public var blocking: Bool
}

extension Engine {
    /// Start-up and 5-minute checks. Each failure raises one notice key, cleared when the check
    /// passes. Blocking failures (staging, ledger) make the engine idle; it never exits.
    @discardableResult
    public func runHealth() -> [HealthCheck] {
        var results: [HealthCheck] = []

        do {
            _ = try FS.listNames(config.watchDir)
            results.append(HealthCheck(name: "downloads", ok: true, detail: config.watchDir.path, blocking: false))
        } catch {
            results.append(HealthCheck(name: "downloads", ok: false, detail: "\(error)", blocking: false))
        }

        let missing = env.requiredTools.filter { env.resolveTool($0) == nil }
        results.append(HealthCheck(name: "tools", ok: missing.isEmpty,
                                   detail: missing.isEmpty ? env.requiredTools.joined(separator: ", ") : "missing: \(missing.joined(separator: ", "))",
                                   blocking: false))

        let hasKey = env.apiKey() != nil
        results.append(HealthCheck(name: "key", ok: hasKey, detail: hasKey ? "present" : "absent; run dltidy set-key", blocking: false))

        results.append(stagingCheck())

        let ledgerOK = ledger.db.quickCheck()
        results.append(HealthCheck(name: "ledger", ok: ledgerOK, detail: ledgerOK ? "quick_check ok" : "quick_check failed", blocking: true))

        if let free = env.freeSpace(config.stateDir) {
            let ok = free >= config.minFreeBytes
            results.append(HealthCheck(name: "space", ok: ok, detail: "\(free / (1 << 30)) GB free", blocking: false))
        } else {
            results.append(HealthCheck(name: "space", ok: false, detail: "free space unknown", blocking: false))
        }

        for r in results {
            let key = "health-\(r.name)"
            if r.ok { notices.clear(key) } else { notices.raise(key, title: Self.healthTitle(r.name), body: Self.healthBody(r)) }
        }
        let wasBlocking = healthBlocking
        healthBlocking = results.contains { $0.blocking && !$0.ok }
        if healthBlocking != wasBlocking {
            log.warn(healthBlocking ? "health: blocking failure; processing idles" : "health: recovered; processing resumes")
        }
        let report = results.map { "\($0.ok ? "ok  " : "FAIL") \($0.name): \($0.detail)" }.joined(separator: "\n")
        try? ledger.setMeta("health_report", report)
        try? ledger.setMeta("health_at", String(now))
        let failing = results.filter { !$0.ok }.map(\.name)
        if !failing.isEmpty { log.warn("health: failing \(failing.joined(separator: ", "))") }
        return results
    }

    private func stagingCheck() -> HealthCheck {
        let fm = FileManager.default
        let src = config.stagingDir.appendingPathComponent(".health-src")
        let dst = config.stagingDir.appendingPathComponent(".health-clone")
        defer {
            try? fm.removeItem(at: src)
            try? fm.removeItem(at: dst)
        }
        do {
            try FS.makeDir(config.stagingDir)
            try? fm.removeItem(at: dst)
            try Data("dltidy".utf8).write(to: src)
            try FS.clone(src, to: dst)
            guard let watch = try FS.lstatEntry(config.watchDir), let staging = try FS.lstatEntry(config.stagingDir) else {
                return HealthCheck(name: "staging", ok: false, detail: "cannot stat watch or staging dir", blocking: true)
            }
            guard watch.dev == staging.dev else {
                return HealthCheck(name: "staging", ok: false, detail: "watch dir and staging are on different volumes", blocking: true)
            }
            return HealthCheck(name: "staging", ok: true, detail: "clonefile ok", blocking: true)
        } catch {
            return HealthCheck(name: "staging", ok: false, detail: "\(error)", blocking: true)
        }
    }

    static func healthTitle(_ name: String) -> String {
        switch name {
        case "downloads": return "dltidy cannot read Downloads"
        case "tools": return "dltidy: conversion tools missing"
        case "key": return "dltidy: no API key"
        case "staging": return "dltidy cannot use its staging folder"
        case "ledger": return "dltidy ledger check failed"
        case "space": return "dltidy: low disk space"
        default: return "dltidy health check failed: \(name)"
        }
    }

    static func healthBody(_ r: HealthCheck) -> String {
        switch r.name {
        case "downloads":
            return "Grant access in System Settings > Privacy & Security > Files and Folders > DLTidy > Downloads Folder."
        case "tools": return "\(r.detail). Install with `brew install ffmpeg imagemagick`. Affected files wait."
        case "key": return "Run `dltidy set-key`. Files are converted under their old names until then."
        case "space": return "\(r.detail). Conversions wait until space is free."
        default: return r.detail
        }
    }
}
