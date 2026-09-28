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
        Migration(version: 3, name: "change feed and settings", sql: """
            CREATE TABLE changes (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                object_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                at REAL NOT NULL
            );
            CREATE INDEX changes_object ON changes(object_id, seq);

            CREATE TABLE settings (
                namespace TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (namespace, key)
            );
            """),
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
        // Version 5 depends on no earlier table. See NexusStore+Telemetry.swift.
        Migration(version: 5, name: "telemetry channels and sample chunks", sql: """
            -- One quantity at one object, in one truth class. The object isn't
            -- a foreign key: acquisition can start before the object is modeled.
            CREATE TABLE IF NOT EXISTS telemetry_channels (
                id TEXT PRIMARY KEY,
                object_id TEXT NOT NULL,
                quantity TEXT NOT NULL,
                unit TEXT NOT NULL,
                truth TEXT NOT NULL,
                sample_rate REAL,
                created_at REAL NOT NULL,
                record TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS telemetry_channels_object ON telemetry_channels(object_id, quantity);

            -- Samples in time-ordered chunks of up to a few thousand
            -- (time, value) pairs. `encoding` names the payload format so it
            -- can change without a migration.
            CREATE TABLE IF NOT EXISTS telemetry_chunks (
                row_id INTEGER PRIMARY KEY,
                channel_id TEXT NOT NULL REFERENCES telemetry_channels(id),
                start_at REAL NOT NULL,
                end_at REAL NOT NULL,
                sample_count INTEGER NOT NULL,
                encoding TEXT NOT NULL,
                payload TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS telemetry_chunks_range ON telemetry_chunks(channel_id, end_at);
            """),
        // Version 6 depends on no earlier table. See NexusStore+Vectors.swift.
        Migration(version: 6, name: "semantic vectors", sql: """
            -- One embedding per object per model. Derived data: it can always be
            -- rebuilt from the object, so the object isn't a foreign key.
            -- `vector` is base64 of little-endian Float32; `content_hash` is the
            -- hash of the text that was embedded, for staleness checks.
            CREATE TABLE IF NOT EXISTS vectors (
                object_id TEXT NOT NULL,
                model TEXT NOT NULL,
                dimension INTEGER NOT NULL,
                vector TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (object_id, model)
            );
            CREATE INDEX IF NOT EXISTS vectors_model ON vectors(model, object_id);
            """),
        // Version 7 depends only on tables from versions 1, 4 and 5, never on
        // version 6. See NexusStore+RelationshipHistory.swift and
        // NexusStore+ChangeSets.swift. Every statement is re-runnable, so a
        // file rolled back to an earlier schema version re-applies cleanly.
        Migration(version: 7, name: "relationship history and sync change log", sql: """
            -- One immutable snapshot per relate/end/update of a relationship.
            -- `author` is the JSON of an Origin; `snapshot` the JSON of the
            -- Relationship after the change.
            CREATE TABLE IF NOT EXISTS relationship_revisions (
                id TEXT PRIMARY KEY,
                relationship_id TEXT NOT NULL REFERENCES relationships(id),
                parent_id TEXT REFERENCES relationship_revisions(id),
                seq INTEGER NOT NULL,
                at REAL NOT NULL,
                author TEXT NOT NULL,
                instruction TEXT,
                snapshot TEXT NOT NULL,
                UNIQUE (relationship_id, seq)
            );

            -- Existing relationships get a synthesized first revision. Its ID
            -- is the relationship's own ID, so replicas migrated separately
            -- synthesize the same revision.
            INSERT OR IGNORE INTO relationship_revisions (id, relationship_id, parent_id, seq, at, author, instruction, snapshot)
            SELECT id, id, NULL, 1, COALESCE(json_extract(record, '$.provenance.timestamp'), 0),
                   COALESCE(json_extract(record, '$.provenance.origin'), '{"system":{}}'),
                   'Synthesized by migration 7', record
            FROM relationships
            WHERE id NOT IN (SELECT relationship_id FROM relationship_revisions);

            -- Per-field merge clocks for objects and relationships: the time
            -- and replica of the write that last set each field ("title",
            -- "lifecycle", "provenance", "validFrom", "validTo", "attr:<key>").
            -- A field with no row was set when the entity was created on this
            -- replica. A NULL replica means this store's own replica.
            CREATE TABLE IF NOT EXISTS sync_field_clocks (
                entity_id TEXT NOT NULL,
                field TEXT NOT NULL,
                at REAL NOT NULL,
                replica TEXT,
                author TEXT NOT NULL,
                PRIMARY KEY (entity_id, field)
            ) WITHOUT ROWID;

            -- Values that lost a merge only because of TruthPolicy (an agent
            -- or modeled value meeting a recorded or observed one). IDs are
            -- derived from the conflict, so every replica records the same row.
            CREATE TABLE IF NOT EXISTS sync_alternates (
                id TEXT PRIMARY KEY,
                entity_id TEXT NOT NULL,
                entity_kind TEXT NOT NULL,
                field TEXT NOT NULL,
                at REAL NOT NULL,
                record TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS sync_alternates_entity ON sync_alternates(entity_id);

            -- Hard deletes (telemetry channels and pruned chunks), so a replica
            -- that still holds the rows cannot resurrect them. Objects and
            -- relationships are never hard-deleted: `deleted` lifecycle and a
            -- closed validity interval are their tombstones.
            CREATE TABLE IF NOT EXISTS sync_tombstones (
                row_id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                start_at REAL NOT NULL DEFAULT 0,
                end_at REAL NOT NULL DEFAULT 0,
                sample_count INTEGER NOT NULL DEFAULT 0,
                deleted_at REAL NOT NULL,
                UNIQUE (kind, entity_id, start_at, end_at, sample_count)
            );

            -- Blobs a change set referenced whose bytes have not arrived yet.
            CREATE TABLE IF NOT EXISTS sync_pending_blobs (
                sha256 TEXT PRIMARY KEY,
                byte_count INTEGER NOT NULL,
                media_type TEXT NOT NULL
            );

            -- The sync feed: one row per changed entity, moved to a new
            -- sequence number on every write, so it stays as small as the
            -- data. Triggers maintain it, so no write path can skip it.
            CREATE TABLE IF NOT EXISTS sync_log (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                entity TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                UNIQUE (entity, entity_id)
            );

            INSERT OR IGNORE INTO sync_log (entity, entity_id) SELECT 'object', id FROM objects ORDER BY row_id;
            INSERT OR IGNORE INTO sync_log (entity, entity_id) SELECT 'relationship', id FROM relationships ORDER BY rowid;
            INSERT OR IGNORE INTO sync_log (entity, entity_id) SELECT 'event', id FROM events ORDER BY at, id;
            INSERT OR IGNORE INTO sync_log (entity, entity_id) SELECT 'blob', sha256 FROM blobs ORDER BY created_at;
            INSERT OR IGNORE INTO sync_log (entity, entity_id) SELECT 'telemetryChannel', id FROM telemetry_channels ORDER BY created_at;
            INSERT OR IGNORE INTO sync_log (entity, entity_id) SELECT 'telemetryChunk', CAST(row_id AS TEXT) FROM telemetry_chunks ORDER BY row_id;

            CREATE TRIGGER IF NOT EXISTS sync_log_object_insert AFTER INSERT ON objects BEGIN
                DELETE FROM sync_log WHERE entity = 'object' AND entity_id = NEW.id;
                INSERT INTO sync_log (entity, entity_id) VALUES ('object', NEW.id);
            END;
            CREATE TRIGGER IF NOT EXISTS sync_log_object_update AFTER UPDATE ON objects BEGIN
                DELETE FROM sync_log WHERE entity = 'object' AND entity_id = NEW.id;
                INSERT INTO sync_log (entity, entity_id) VALUES ('object', NEW.id);
            END;
            CREATE TRIGGER IF NOT EXISTS sync_log_relationship_insert AFTER INSERT ON relationships BEGIN
                DELETE FROM sync_log WHERE entity = 'relationship' AND entity_id = NEW.id;
                INSERT INTO sync_log (entity, entity_id) VALUES ('relationship', NEW.id);
            END;
            CREATE TRIGGER IF NOT EXISTS sync_log_relationship_update AFTER UPDATE ON relationships BEGIN
                DELETE FROM sync_log WHERE entity = 'relationship' AND entity_id = NEW.id;
                INSERT INTO sync_log (entity, entity_id) VALUES ('relationship', NEW.id);
            END;
            CREATE TRIGGER IF NOT EXISTS sync_log_event_insert AFTER INSERT ON events BEGIN
                INSERT INTO sync_log (entity, entity_id) VALUES ('event', NEW.id);
            END;
            CREATE TRIGGER IF NOT EXISTS sync_log_blob_insert AFTER INSERT ON blobs BEGIN
                INSERT INTO sync_log (entity, entity_id) VALUES ('blob', NEW.sha256);
            END;
            CREATE TRIGGER IF NOT EXISTS sync_log_channel_insert AFTER INSERT ON telemetry_channels BEGIN
                DELETE FROM sync_log WHERE entity = 'telemetryChannel' AND entity_id = NEW.id;
                INSERT INTO sync_log (entity, entity_id) VALUES ('telemetryChannel', NEW.id);
            END;
            CREATE TRIGGER IF NOT EXISTS sync_log_chunk_insert AFTER INSERT ON telemetry_chunks BEGIN
                INSERT INTO sync_log (entity, entity_id) VALUES ('telemetryChunk', CAST(NEW.row_id AS TEXT));
            END;
            CREATE TRIGGER IF NOT EXISTS sync_log_alternate_insert AFTER INSERT ON sync_alternates BEGIN
                INSERT INTO sync_log (entity, entity_id) VALUES ('alternate', NEW.id);
            END;
            CREATE TRIGGER IF NOT EXISTS sync_log_tombstone_insert AFTER INSERT ON sync_tombstones BEGIN
                INSERT INTO sync_log (entity, entity_id) VALUES ('tombstone', CAST(NEW.row_id AS TEXT));
            END;
            -- Julian day 2451910.5 is 2001-01-01, the reference date of every stored time.
            CREATE TRIGGER IF NOT EXISTS sync_tombstone_channel AFTER DELETE ON telemetry_channels BEGIN
                DELETE FROM sync_log WHERE entity = 'telemetryChannel' AND entity_id = OLD.id;
                INSERT OR IGNORE INTO sync_tombstones (kind, entity_id, deleted_at)
                VALUES ('telemetryChannel', OLD.id, (julianday('now') - 2451910.5) * 86400);
            END;
            CREATE TRIGGER IF NOT EXISTS sync_tombstone_chunk AFTER DELETE ON telemetry_chunks BEGIN
                DELETE FROM sync_log WHERE entity = 'telemetryChunk' AND entity_id = CAST(OLD.row_id AS TEXT);
                INSERT OR IGNORE INTO sync_tombstones (kind, entity_id, start_at, end_at, sample_count, deleted_at)
                VALUES ('telemetryChunk', OLD.channel_id, OLD.start_at, OLD.end_at, OLD.sample_count, (julianday('now') - 2451910.5) * 86400);
            END;
            """),
    ]

    static var latestVersion: Int { all.last?.version ?? 0 }
}
