import Foundation

/// Ordered migrations. `meta.schema_version` records how many have run.
enum Schema {
    static let migrations: [String] = [
        // 1: initial schema
        """
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE items(
            id INTEGER PRIMARY KEY,
            role TEXT NOT NULL,
            state TEXT NOT NULL,
            dev INTEGER, inode INTEGER, size INTEGER, mtime_ns INTEGER,
            path TEXT NOT NULL,
            original_name TEXT NOT NULL,
            assigned_name TEXT,
            parent_id INTEGER,
            format TEXT,
            group_id INTEGER,
            sha256 TEXT,
            first_seen REAL NOT NULL,
            missing_since REAL,
            stable_count INTEGER NOT NULL DEFAULT 0,
            stable_since REAL,
            path_since REAL,
            work_starts INTEGER NOT NULL DEFAULT 0,
            decode_failures INTEGER NOT NULL DEFAULT 0,
            next_attempt_at REAL,
            name_status TEXT NOT NULL DEFAULT 'none',
            next_name_at REAL,
            slug TEXT,
            media_kind TEXT, duration REAL, is_hdr INTEGER, width INTEGER, height INTEGER,
            is_live_video INTEGER NOT NULL DEFAULT 0,
            note TEXT,
            updated_at REAL
        );
        CREATE INDEX items_inode ON items(dev, inode);
        CREATE INDEX items_sha ON items(sha256);
        CREATE INDEX items_group ON items(group_id);
        CREATE INDEX items_parent ON items(parent_id, format);
        CREATE INDEX items_role_state ON items(role, state);
        CREATE INDEX items_path ON items(path COLLATE NOCASE);
        CREATE INDEX items_missing ON items(missing_since);
        CREATE TABLE api_calls(
            id INTEGER PRIMARY KEY,
            at REAL NOT NULL,
            day TEXT NOT NULL,
            month TEXT NOT NULL,
            kind TEXT NOT NULL,
            group_id INTEGER,
            item_id INTEGER,
            status TEXT NOT NULL,
            reason TEXT,
            est_input_tokens INTEGER NOT NULL,
            input_tokens INTEGER,
            output_tokens INTEGER,
            finished_at REAL
        );
        CREATE INDEX api_calls_day ON api_calls(day);
        CREATE INDEX api_calls_month ON api_calls(month);
        CREATE INDEX api_calls_group ON api_calls(group_id);
        CREATE TABLE breaker(
            id INTEGER PRIMARY KEY CHECK (id = 1),
            state TEXT NOT NULL,
            consecutive_failures INTEGER NOT NULL,
            open_until REAL,
            interval REAL NOT NULL,
            cooldown_until REAL,
            updated_at REAL
        );
        CREATE TABLE notices(
            key TEXT PRIMARY KEY,
            active INTEGER NOT NULL,
            title TEXT, body TEXT,
            first_at REAL, last_at REAL,
            count INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE actions(
            id INTEGER PRIMARY KEY,
            at REAL NOT NULL,
            item_id INTEGER,
            kind TEXT NOT NULL,
            key TEXT NOT NULL,
            from_name TEXT,
            to_name TEXT,
            status TEXT NOT NULL
        );
        CREATE INDEX actions_key ON actions(key);
        CREATE INDEX actions_at ON actions(at);
        CREATE TABLE commands(
            id INTEGER PRIMARY KEY,
            at REAL NOT NULL,
            cmd TEXT NOT NULL,
            arg TEXT,
            status TEXT NOT NULL,
            result TEXT,
            done_at REAL
        );
        CREATE TABLE starts(id INTEGER PRIMARY KEY, at REAL NOT NULL, pid INTEGER);
        """,
    ]

    static var currentVersion: Int { migrations.count }

    /// Applies pending migrations in one transaction.
    static func migrate(_ db: Database) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
        try db.transaction {
            let version = Int(try db.scalarText("SELECT value FROM meta WHERE key = 'schema_version'") ?? "0") ?? 0
            guard version < migrations.count else { return }
            for i in version..<migrations.count {
                try db.execute(migrations[i])
            }
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)", String(migrations.count))
        }
    }
}
