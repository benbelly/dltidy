import Foundation
import DLTidyKit

/// One user notification per incident key. A key fires again only after it was cleared.
final class Notices {
    private let ledger: Ledger
    private let notifier: any Notifier
    private let clock: any Clock
    private let log: Log

    init(ledger: Ledger, notifier: any Notifier, clock: any Clock, log: Log) {
        self.ledger = ledger
        self.notifier = notifier
        self.clock = clock
        self.log = log
    }

    func raise(_ key: String, title: String, body: String) {
        let now = clock.now().timeIntervalSince1970
        do {
            let active = try ledger.db.scalarInt("SELECT active FROM notices WHERE key = ?", key) ?? 0
            if active == 1 { return }
            try ledger.db.run("""
                INSERT INTO notices(key, active, title, body, first_at, last_at, count) VALUES(?, 1, ?, ?, ?, ?, 1)
                ON CONFLICT(key) DO UPDATE SET active = 1, title = excluded.title, body = excluded.body,
                    last_at = excluded.last_at, count = count + 1
                """, key, title, body, now, now)
        } catch {
            log.error("notice ledger write failed for \(key): \(error)")
        }
        log.warn("NOTICE [\(key)] \(title): \(body)")
        notifier.post(title: title, body: body)
    }

    func clear(_ key: String) {
        do {
            let changed = try ledger.db.run("UPDATE notices SET active = 0 WHERE key = ? AND active = 1", key)
            if changed > 0 { log.info("incident cleared: \(key)") }
        } catch {
            log.error("notice clear failed for \(key): \(error)")
        }
    }

    func clearPrefix(_ prefix: String) {
        let keys = (try? ledger.db.query("SELECT key FROM notices WHERE active = 1 AND key LIKE ?", [prefix + "%"]) { $0.text(0) }) ?? []
        for key in keys { clear(key) }
    }

    func isActive(_ key: String) -> Bool {
        ((try? ledger.db.scalarInt("SELECT active FROM notices WHERE key = ?", key)) ?? nil) == 1
    }
}
