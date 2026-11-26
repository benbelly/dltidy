import Foundation
import DLTidyKit

public enum CommandName: String, Sendable, CaseIterable {
    case pause, resume, undo, keyUpdated = "key-updated", health, scan
}

extension Engine {
    /// Applies queued CLI commands. The CLI only writes `commands` rows; every filesystem change
    /// happens here.
    func processCommands() throws {
        let queued = try ledger.db.query("SELECT id, cmd, arg FROM commands WHERE status = 'queued' ORDER BY id") {
            (id: $0.int(0), cmd: $0.text(1), arg: $0.optText(2))
        }
        for c in queued {
            var result: String
            do {
                result = try handle(CommandName(rawValue: c.cmd), arg: c.arg)
            } catch is FuseTripped {
                result = "safety fuse tripped; processing paused"
            } catch let crash as SimulatedCrash {
                throw crash
            } catch {
                result = "error: \(error)"
            }
            try ledger.db.run("UPDATE commands SET status = 'done', result = ?, done_at = ? WHERE id = ?", result, now, c.id)
            log.info("command \(c.cmd)\(c.arg.map { " \($0)" } ?? ""): \(result)")
        }
    }

    private func handle(_ cmd: CommandName?, arg: String?) throws -> String {
        switch cmd {
        case .pause:
            try ledger.setMeta("paused", "1")
            try ledger.setMeta("paused_reason", "user")
            return "paused"
        case .resume:
            var parts = ["resumed"]
            if safeMode { parts.append("safe mode cleared") }
            try ledger.db.transaction {
                try ledger.setMeta("paused", nil)
                try ledger.setMeta("paused_reason", nil)
                try ledger.setMeta("safe_mode", nil)
                try ledger.setMeta("safe_mode_reason", nil)
                if arg == "skip-backlog" {
                    let n = try ledger.db.run("UPDATE items SET role = 'skipped', state = 'known', updated_at = ? WHERE role = 'candidate'", now)
                    parts.append("\(n) waiting files skipped")
                }
            }
            notices.clear("fuse")
            notices.clear("safe-mode")
            return parts.joined(separator: "; ")
        case .undo:
            return try undo(arg)
        case .keyUpdated:
            try budget.keyUpdated()
            notices.clear("health-key")
            return "API key reloaded; breaker closed"
        case .health:
            let results = runHealth()
            return results.map { "\($0.ok ? "ok  " : "FAIL") \($0.name): \($0.detail)" }.joined(separator: "\n")
        case .scan:
            return "scan queued"
        case nil:
            return "unknown command"
        }
    }
}

/// CLI side: reads the ledger and queues commands. Never touches the watch directory.
public final class ControlClient {
    let ledger: Ledger
    let config: Config

    public init(config: Config) throws {
        self.config = config
        ledger = try Ledger(existing: config.ledgerURL)
    }

    /// Queues a command and waits up to `timeout` for the daemon's answer.
    public func send(_ cmd: CommandName, arg: String? = nil, timeout: TimeInterval = 10) throws -> String? {
        try ledger.db.run("INSERT INTO commands(at, cmd, arg, status) VALUES(?, ?, ?, 'queued')",
                          Date().timeIntervalSince1970, cmd.rawValue, arg)
        let id = ledger.db.lastInsertID
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = try ledger.db.query("SELECT status, result FROM commands WHERE id = ?", [id], { ($0.text(0), $0.optText(1)) }).first,
               r.0 == "done" {
                return r.1 ?? ""
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    public func status(now: Date = Date()) throws -> String {
        var lines: [String] = []
        let paused = ledger.flag("paused"), safe = ledger.flag("safe_mode")
        var state = "running"
        if safe { state = "SAFE MODE (\(ledger.meta("safe_mode_reason") ?? "?")); run `dltidy resume`" }
        else if paused { state = "paused (\(ledger.meta("paused_reason") ?? "user"))" }
        lines.append("state:      \(state)")
        if let hb = ledger.meta("heartbeat_at").flatMap(Double.init) {
            lines.append("heartbeat:  \(Self.ago(now.timeIntervalSince1970 - hb)) ago")
        } else {
            lines.append("heartbeat:  none (daemon has not scanned yet)")
        }
        if let b = ledger.meta("baseline_done_at").flatMap(Double.init) {
            let pre = try ledger.db.scalarInt("SELECT COUNT(*) FROM items WHERE role = 'preexisting'") ?? 0
            lines.append("baseline:   \(Self.date(b)) (\(pre) pre-existing)")
        }
        let day = Period.day(now), month = Period.month(now)
        let dayCalls = try ledger.db.scalarInt("SELECT COUNT(*) FROM api_calls WHERE day = ?", day) ?? 0
        let monthCalls = try ledger.db.scalarInt("SELECT COUNT(*) FROM api_calls WHERE month = ?", month) ?? 0
        let tokens = try ledger.db.scalarInt("SELECT COALESCE(SUM(COALESCE(input_tokens, est_input_tokens)), 0) FROM api_calls WHERE month = ?", month) ?? 0
        lines.append("API calls:  today \(dayCalls)/\(config.dailyCallCap), month \(monthCalls)/\(config.monthlyCallCap), input tokens \(tokens)/\(config.monthlyInputTokenCap)")
        if let b = try ledger.db.query("SELECT state, open_until, cooldown_until FROM breaker WHERE id = 1", [], {
            ($0.text(0), $0.optDouble(1), $0.optDouble(2))
        }).first {
            var s = "breaker:    \(b.0)"
            if let u = b.1, b.0 == "open" { s += " until \(Self.date(u))" }
            if b.0 == "auth" { s += " (run `dltidy set-key`)" }
            if let c = b.2, c > now.timeIntervalSince1970 { s += "; rate-limit cool-down until \(Self.date(c))" }
            lines.append(s)
        } else {
            lines.append("breaker:    closed")
        }
        let waiting = try ledger.db.scalarInt("SELECT COUNT(*) FROM items WHERE role = 'candidate' AND missing_since IS NULL") ?? 0
        let active = try ledger.db.scalarInt("SELECT COUNT(*) FROM items WHERE role = 'original' AND state IN ('probe','naming','convert')") ?? 0
        let deferred = try ledger.db.scalarInt("""
            SELECT COUNT(DISTINCT group_id) FROM items WHERE role = 'original' AND name_status IN ('waitClassify','waitName')
              AND state NOT IN ('probe','naming')
            """) ?? 0
        lines.append("pending:    \(waiting) arriving, \(active) in progress, \(deferred) awaiting deferred rename")
        let notices = try ledger.db.query("SELECT key, title FROM notices WHERE active = 1 ORDER BY last_at", []) { "\($0.text(0)): \($0.text(1))" }
        lines.append("incidents:  " + (notices.isEmpty ? "none" : notices.joined(separator: "; ")))
        if let h = ledger.meta("health_report"), let at = ledger.meta("health_at").flatMap(Double.init) {
            let failing = h.split(separator: "\n").filter { $0.hasPrefix("FAIL") }
            lines.append("health:     \(Self.date(at)): " + (failing.isEmpty ? "all checks pass" : failing.joined(separator: "; ")))
        }
        return lines.joined(separator: "\n")
    }

    public func recentActions(limit: Int) throws -> String {
        let rows = try ledger.db.query("""
            SELECT at, kind, from_name, to_name FROM actions WHERE status = 'done' ORDER BY id DESC LIMIT ?
            """, [limit]) { "\(Self.date($0.double(0)))  \($0.text(1).padding(toLength: 6, withPad: " ", startingAt: 0)) \($0.text(2)) -> \($0.text(3))" }
        return rows.isEmpty ? "no actions yet" : rows.reversed().joined(separator: "\n")
    }

    public func quickCheck() -> Bool { ledger.db.quickCheck() }

    public func lastHealthReport() -> (at: Date, report: String)? {
        guard let r = ledger.meta("health_report"), let at = ledger.meta("health_at").flatMap(Double.init) else { return nil }
        return (Date(timeIntervalSince1970: at), r)
    }

    static func date(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    static func ago(_ s: Double) -> String {
        if s < 120 { return "\(Int(s)) s" }
        if s < 7_200 { return "\(Int(s / 60)) min" }
        return "\(Int(s / 3_600)) h"
    }
}
