/// Ordered schema migrations. Append new ones; never edit a shipped migration.
///
/// Each canonical record is stored whole as JSON (`record`), with the fields
/// that queries need, including truth class, copied into indexed columns.
/// The JSON is authoritative; the columns are derived from it on every write.
struct Migration: Sendable {
    let version: Int
    let name: String
    let sql: String
}

enum Migrations {
    static let all: [Migration] = [
        Migration(version: 1, name: "canonical world model", sql: """
            -- row_id aliases rowid explicitly so VACUUM cannot renumber it;
            -- search_index rows share it.
            CREATE TABLE objects (
                row_id INTEGER PRIMARY KEY,
                id TEXT NOT NULL UNIQUE,
                type TEXT NOT NULL,
                title TEXT NOT NULL,
                lifecycle TEXT NOT NULL,
                truth TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                head_revision TEXT NOT NULL,
                record TEXT NOT NULL
            );
            CREATE INDEX objects_type ON objects(type, id);

            CREATE TABLE revisions (
                id TEXT PRIMARY KEY,
                object_id TEXT NOT NULL REFERENCES objects(id),
                parent_id TEXT REFERENCES revisions(id),
                seq INTEGER NOT NULL,
                at REAL NOT NULL,
                record TEXT NOT NULL,
                UNIQUE (object_id, seq)
            );

            CREATE TABLE relationships (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                from_id TEXT NOT NULL REFERENCES objects(id),
                to_id TEXT NOT NULL REFERENCES objects(id),
                truth TEXT NOT NULL,
                valid_from REAL,
                valid_to REAL,
                record TEXT NOT NULL
            );
            CREATE INDEX relationships_from ON relationships(from_id, kind);
            CREATE INDEX relationships_to ON relationships(to_id, kind);

            CREATE TABLE events (
                id TEXT PRIMARY KEY,
                at REAL NOT NULL,
                kind TEXT NOT NULL,
                truth TEXT NOT NULL,
                record TEXT NOT NULL
            );
            CREATE INDEX events_at ON events(at, id);

            CREATE TABLE event_subjects (
                event_id TEXT NOT NULL REFERENCES events(id),
                object_id TEXT NOT NULL REFERENCES objects(id),
                PRIMARY KEY (event_id, object_id)
            );
            CREATE INDEX event_subjects_object ON event_subjects(object_id);

            CREATE TABLE claims (
                id TEXT PRIMARY KEY REFERENCES objects(id),
                source_class TEXT NOT NULL,
                confidence REAL,
                record TEXT NOT NULL
            );

            CREATE TABLE claim_sources (
                claim_id TEXT NOT NULL REFERENCES claims(id),
                source_id TEXT NOT NULL REFERENCES objects(id),
                PRIMARY KEY (claim_id, source_id)
            );
            CREATE INDEX claim_sources_source ON claim_sources(source_id);

            CREATE TABLE measurements (
                id TEXT PRIMARY KEY REFERENCES objects(id),
                test_point TEXT NOT NULL REFERENCES objects(id),
                quantity TEXT NOT NULL,
                value REAL NOT NULL,
                unit TEXT NOT NULL,
                truth TEXT NOT NULL,
                sampled_at REAL NOT NULL,
                record TEXT NOT NULL
            );
            CREATE INDEX measurements_test_point ON measurements(test_point, sampled_at);

            CREATE VIRTUAL TABLE search_index USING fts5(
                object_id UNINDEXED,
                title,
                body,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            """),
        Migration(version: 2, name: "exact title lookup", sql: """
            CREATE INDEX objects_title_nocase ON objects(title COLLATE NOCASE);
            """),
        // 3 reserved: permissions/change feed.
        // Version 4 depends only on version 1's tables, never on version 3's.
        Migration(version: 4, name: "content-addressed blobs", sql: """
            -- Metadata only; the bytes live in a content-addressed directory
            -- next to the database (see NexusStore+Blobs.swift). IF NOT EXISTS
            -- so a file rolled back to an earlier schema version re-applies cleanly.
            CREATE TABLE IF NOT EXISTS blobs (
                id TEXT PRIMARY KEY,
                sha256 TEXT NOT NULL UNIQUE,
                byte_count INTEGER NOT NULL,
                media_type TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """),
    ]

    static var latestVersion: Int { all.last?.version ?? 0 }
}
