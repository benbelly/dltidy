import Foundation
import DLTidyKit

enum CallKind: String, Sendable { case classify, name }

/// Proof that a request was reserved and committed to `api_calls`. Only `Budget.reserve` creates
/// one, and `NamingGate` refuses a spent ticket, so each reservation buys at most one request.
final class NamingTicket: @unchecked Sendable {
    let callID: Int64
    let kind: CallKind
    let groupID: Int64
    private let lock = NSLock()
    private var spent = false

    fileprivate init(callID: Int64, kind: CallKind, groupID: Int64) {
        self.callID = callID
        self.kind = kind
        self.groupID = groupID
    }

    fileprivate func spend() -> Bool {
        lock.withLock {
            if spent { return false }
            spent = true
            return true
        }
    }
}

enum Reservation {
    case granted(NamingTicket)
    /// Network, cap, breaker or cool-down: try again later; no attempt consumed.
    case wait(String)
    /// The group used its request allowance.
    case exhausted(String)
}

/// The only holder of the `NamingService`. Every request needs a ticket from `Budget.reserve`.
struct NamingGate: Sendable {
    private let service: any NamingService

    init(service: any NamingService) { self.service = service }

    func classify(_ ticket: NamingTicket, stem: String, apiKey: String) async -> APIResult<Bool> {
        guard ticket.kind == .classify, ticket.spend() else { return .final(reason: "ticket misuse", usage: nil) }
        return await service.classifyStem(stem, apiKey: apiKey)
    }

    func suggest(_ ticket: NamingTicket, payload: NamingPayload, originalName: String, apiKey: String) async -> APIResult<NameSuggestion> {
        guard ticket.kind == .name, ticket.spend() else { return .final(reason: "ticket misuse", usage: nil) }
        return await service.suggestName(for: payload, originalName: originalName, apiKey: apiKey)
    }
}

enum CallOutcome {
    case ok(APIUsage)
    case final(String, APIUsage?)
    case transient(String)
    case rateLimited(TimeInterval?)
    case auth(Int)

    init<T>(_ r: APIResult<T>) {
        switch r {
        case .ok(_, let u): self = .ok(u)
        case .final(let reason, let u): self = .final(reason, u)
        case .transient(let reason): self = .transient(reason)
        case .rateLimited(let ra): self = .rateLimited(ra)
        case .authFailure(let status): self = .auth(status)
        }
    }

    var statusText: String {
        switch self {
        case .ok: return "ok"
        case .final: return "final"
        case .transient: return "transient"
        case .rateLimited: return "rate_limited"
        case .auth: return "auth"
        }
    }
}

struct BreakerState: Equatable {
    enum Mode: String { case closed, open, halfOpen = "half_open", auth }
    var mode: Mode
    var consecutiveFailures: Int
    var openUntil: Double?
    var interval: Double
    var cooldownUntil: Double?
}

struct Usage {
    var dayCalls: Int
    var monthCalls: Int
    var monthInputTokens: Int
}

/// Cost guardrails: per-group allowance, caps, breaker, rate-limit cool-down.
final class Budget {
    private let ledger: Ledger
    private let config: Config
    private let clock: any Clock
    private let notices: Notices
    private let log: Log
    private let isOnline: @Sendable () -> Bool

    init(ledger: Ledger, config: Config, clock: any Clock, notices: Notices, log: Log, isOnline: @escaping @Sendable () -> Bool) {
        self.ledger = ledger
        self.config = config
        self.clock = clock
        self.notices = notices
        self.log = log
        self.isOnline = isOnline
    }

    // MARK: breaker persistence

    func breaker() throws -> BreakerState {
        let rows = try ledger.db.query("SELECT state, consecutive_failures, open_until, interval, cooldown_until FROM breaker WHERE id = 1") {
            BreakerState(mode: BreakerState.Mode(rawValue: $0.text(0)) ?? .closed, consecutiveFailures: Int($0.int(1)),
                         openUntil: $0.optDouble(2), interval: $0.double(3), cooldownUntil: $0.optDouble(4))
        }
        return rows.first ?? BreakerState(mode: .closed, consecutiveFailures: 0, openUntil: nil,
                                          interval: config.breakerBaseInterval, cooldownUntil: nil)
    }

    func saveBreaker(_ b: BreakerState) throws {
        try ledger.db.run("""
            INSERT OR REPLACE INTO breaker(id, state, consecutive_failures, open_until, interval, cooldown_until, updated_at)
            VALUES(1, ?, ?, ?, ?, ?, ?)
            """, b.mode.rawValue, b.consecutiveFailures, b.openUntil, b.interval, b.cooldownUntil,
                   clock.now().timeIntervalSince1970)
    }

    /// After `set-key`: close an auth-opened breaker.
    func keyUpdated() throws {
        var b = try breaker()
        if b.mode == .auth {
            b.mode = .closed
            b.consecutiveFailures = 0
            b.openUntil = nil
            try saveBreaker(b)
            log.info("breaker closed after set-key")
        }
        notices.clear("api-key-rejected")
    }

    /// At start: a probe that was in flight when the process died is treated as never sent for
    /// breaker purposes (its api_calls row still counts toward caps and the group allowance).
    func recoverAfterRestart() throws {
        var b = try breaker()
        if b.mode == .halfOpen {
            b.mode = .open
            b.openUntil = clock.now().timeIntervalSince1970
            try saveBreaker(b)
        }
        try ledger.db.run("UPDATE api_calls SET status = 'abandoned', finished_at = ? WHERE status = 'reserved'",
                          clock.now().timeIntervalSince1970)
    }

    // MARK: accounting

    func usage(at date: Date) throws -> Usage {
        let day = Period.day(date), month = Period.month(date)
        return Usage(
            dayCalls: Int(try ledger.db.scalarInt("SELECT COUNT(*) FROM api_calls WHERE day = ?", day) ?? 0),
            monthCalls: Int(try ledger.db.scalarInt("SELECT COUNT(*) FROM api_calls WHERE month = ?", month) ?? 0),
            monthInputTokens: Int(try ledger.db.scalarInt(
                "SELECT COALESCE(SUM(COALESCE(input_tokens, est_input_tokens)), 0) FROM api_calls WHERE month = ?", month) ?? 0)
        )
    }

    func groupCounts(_ groupID: Int64) throws -> (total: Int, classify: Int, name: Int) {
        let rows = try ledger.db.query("SELECT kind, COUNT(*) FROM api_calls WHERE group_id = ? GROUP BY kind", [groupID]) {
            ($0.text(0), Int($0.int(1)))
        }
        var c = 0, n = 0
        for (kind, count) in rows {
            if kind == CallKind.classify.rawValue { c += count } else { n += count }
        }
        return (c + n, c, n)
    }

    // MARK: reserve

    /// Read-only check, used before extraction so no work is done for a request that cannot go out.
    func availability(_ kind: CallKind, groupID: Int64) throws -> Reservation? {
        let counts = try groupCounts(groupID)
        if counts.total >= config.maxRequestsPerGroup { return .exhausted("group used \(counts.total) requests") }
        switch kind {
        case .classify where counts.classify >= config.maxClassifyRequestsPerGroup:
            return .exhausted("classification already sent")
        case .name where counts.name >= config.maxNamingRequestsPerGroup:
            return .exhausted("naming attempts used")
        default: break
        }
        if ledger.flag("safe_mode") { return .wait("safe mode") }
        if ledger.flag("paused") { return .wait("paused") }
        if !isOnline() { return .wait("offline") }
        let now = clock.now()
        let t = now.timeIntervalSince1970
        let b = try breaker()
        switch b.mode {
        case .auth: return .wait("API key rejected; run dltidy set-key")
        case .halfOpen: return .wait("breaker probe in flight")
        case .open where (b.openUntil ?? 0) > t: return .wait("breaker open")
        default: break
        }
        if let cd = b.cooldownUntil, cd > t { return .wait("rate-limit cool-down") }
        let u = try usage(at: now)
        if u.dayCalls >= config.dailyCallCap {
            notices.raise("cap", title: "dltidy: daily API cap reached",
                          body: "\(config.dailyCallCap) naming calls today. Files are converted under their old names and renamed when calls resume (within 24 h).")
            return .wait("daily cap")
        }
        if u.monthCalls >= config.monthlyCallCap {
            notices.raise("cap", title: "dltidy: monthly API cap reached",
                          body: "\(config.monthlyCallCap) naming calls this month. Files keep their names; conversions continue.")
            return .wait("monthly cap")
        }
        let est = kind == .classify ? config.estimatedTokensClassify : config.estimatedTokensImage
        if u.monthInputTokens + est > config.monthlyInputTokenCap {
            notices.raise("cap", title: "dltidy: monthly token cap reached",
                          body: "\(config.monthlyInputTokenCap) input tokens this month. Files keep their names; conversions continue.")
            return .wait("monthly token cap")
        }
        return nil
    }

    /// The sole way to obtain a `NamingTicket`. Commits the `api_calls` row before returning, so a
    /// crash during the request still counts the attempt.
    func reserve(_ kind: CallKind, leader: Item, estimatedTokens: Int) throws -> Reservation {
        guard let groupID = leader.groupID else { return .exhausted("no group") }
        return try ledger.db.transaction {
            // Re-read the leader inside the transaction; the row is the authority.
            guard let item = try ledger.item(leader.id) else { return .exhausted("item gone") }
            guard item.role == .original else { return .exhausted("role \(item.role.rawValue)") }
            guard item.nameStatus == .waitClassify || item.nameStatus == .waitName else {
                return .exhausted("name status \(item.nameStatus.rawValue)")
            }
            guard [.naming, .convert, .done].contains(item.state) else { return .exhausted("state \(item.state.rawValue)") }
            guard let sha = item.sha256, try ledger.hashCount(sha) == 1 else { return .exhausted("hash seen before") }
            if let blocked = try availability(kind, groupID: groupID) { return blocked }

            let now = clock.now()
            var b = try breaker()
            if b.mode == .open {
                b.mode = .halfOpen
                try saveBreaker(b)
                log.info("breaker half-open: probe request")
            }
            notices.clear("cap")
            try ledger.db.run("""
                INSERT INTO api_calls(at, day, month, kind, group_id, item_id, status, est_input_tokens)
                VALUES(?, ?, ?, ?, ?, ?, 'reserved', ?)
                """, now.timeIntervalSince1970, Period.day(now), Period.month(now), kind.rawValue, groupID, item.id,
                                   estimatedTokens)
            return .granted(NamingTicket(callID: ledger.db.lastInsertID, kind: kind, groupID: groupID))
        }
    }

    /// Records the outcome of the one request a ticket bought, and updates the breaker.
    func record(_ ticket: NamingTicket, _ outcome: CallOutcome) throws {
        let now = clock.now().timeIntervalSince1970
        try ledger.db.transaction {
            var reason: String?
            var usage: APIUsage?
            switch outcome {
            case .ok(let u): usage = u
            case .final(let r, let u): reason = r; usage = u
            case .transient(let r): reason = r
            case .rateLimited(let ra): reason = "429 retry-after \(ra.map { String(Int($0)) } ?? "-")"
            case .auth(let s): reason = "HTTP \(s)"
            }
            try ledger.db.run("""
                UPDATE api_calls SET status = ?, reason = ?, input_tokens = ?, output_tokens = ?, finished_at = ? WHERE id = ?
                """, outcome.statusText, reason, usage.map { $0.inputTokens }, usage.map { $0.outputTokens }, now, ticket.callID)

            var b = try breaker()
            switch outcome {
            case .ok, .final:
                if b.mode != .closed { log.info("breaker closed") }
                b.mode = .closed
                b.consecutiveFailures = 0
                b.openUntil = nil
                b.interval = config.breakerBaseInterval
            case .transient(let r):
                b.consecutiveFailures += 1
                if b.mode == .halfOpen {
                    b.interval = min(b.interval * 2, config.breakerMaxInterval)
                    b.mode = .open
                    b.openUntil = now + b.interval
                    log.warn("breaker probe failed (\(r)); open for \(Int(b.interval)) s")
                } else if b.consecutiveFailures >= config.breakerThreshold && b.mode == .closed {
                    b.mode = .open
                    b.openUntil = now + b.interval
                    log.warn("breaker open after \(b.consecutiveFailures) failures (\(r)); open for \(Int(b.interval)) s")
                }
            case .rateLimited(let ra):
                let wait = min(max(ra ?? config.rateLimitMinCooldown, config.rateLimitMinCooldown), config.rateLimitMaxCooldown)
                b.cooldownUntil = now + wait
                if b.mode == .halfOpen { b.mode = .open; b.openUntil = now }
                log.warn("rate limited; cool-down \(Int(wait)) s")
            case .auth(let status):
                b.mode = .auth
                b.openUntil = nil
                notices.raise("api-key-rejected", title: "dltidy: API key rejected",
                              body: "Anthropic returned HTTP \(status). Naming is off until you run `dltidy set-key`.")
            }
            try saveBreaker(b)
        }
    }
}
