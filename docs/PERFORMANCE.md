# Performance

Timings for the canonical store at roughly the size of a large single-site
project. They come from the `NexusBenchmarks` executable, which is not part of
`swift test`:

```
swift run -c release NexusBenchmarks        # full size
swift run -c release NexusBenchmarks 0.1    # 10 % scale
```

A small guard, `PerformanceSmokeTests` in `NexusPersistenceTests`, runs with
the test suite and takes about 1 s on its own in a debug build. It inserts
2,500 objects in five chunks and runs 80 searches. It fails if inserts slow
down as the store grows or if limited searches stop being cheap. It measures
thread CPU time rather than wall-clock time, so a busy parallel test run does
not make it flaky.

## Workload

- **Objects:** 100,000 (`component`, 500 of them `testPoint`), each with a
  three-word title and one string attribute, all indexed by FTS5.
- **Relationships:** 300,000 `contains` edges, three per object, forming a
  3-ary tree with wrap-around. Depth 6 from the root reaches 1,092 objects.
- **Measurements:** 50,000 observed readings, 100 per test point. Each one is
  also a canonical object, so the store holds 150,000 objects in total.
- **Batching:** writes go through `NexusStore.batch` in groups of 5,000, in a
  temporary file store (WAL mode, `synchronous = NORMAL`).

## Results

Measured on 2026-09-27, Linux x86_64 (4 vCPU Xeon @ 2.8 GHz, container),
Swift 6.2 release build, SQLite 3.45.1. The component-cost rows were measured
in a separate run at 0.1 scale; they do not depend on store size.

| Operation | Time | Per op |
|---|---|---|
| Insert 100,000 objects | 23.8 s | 238 µs (4,200/s) |
| Insert 300,000 relationships | 20.3 s | 68 µs (14,800/s) |
| Insert 50,000 measurements | 15.9 s | 319 µs (3,100/s) |
| FTS search, limit 50 (200 queries of 1–2 common words) | 4.0 s | 19.9 ms |
| Traverse depth 6, outgoing `contains` (1,092 reached) | 38 ms | ≈35 µs per node |
| Traverse depth 3, both directions (85 reached) | 5 ms | |
| Measurements at a test point (100 rows each) | 2.8 ms per query | ≈28 µs per row |
| Same, filtered to `observed` | 2.7 ms per query | |
| Point lookup by ID | 50 µs | |
| Batch fetch of 10,000 objects | 0.47 s | 47 µs |
| Update (new revision) | 347 µs | |
| Reload: open store | 1 ms | |
| Reload: first FTS query | 20 ms | |
| Reload: 500 test points by type | 17 ms | |
| Reload: 100,000 components by type | 3.5 s | 35 µs |
| *Component:* JSON-encode an `ObjectRecord` (sorted keys) | | 32 µs |
| *Component:* JSON-decode an `ObjectRecord` | | 39 µs |

The database file is 454.5 MB (average record JSON is 408 bytes).

## Reading the numbers

- **Nothing is pathological.** Per-op insert cost at 100,000 objects (238 µs)
  is the same as at 10,000 (228 µs), and traversal cost per node does not
  change with graph size. Reload is instant because nothing is loaded eagerly.
- **JSON dominates reads.** A point lookup is 50 µs, of which about 39 µs is
  decoding the record. Row-heavy queries such as measurements at a test point
  and objects by type cost about 30 µs per row for the same reason.
- **Writes pay for JSON twice, plus SQL overhead.** Creating an object encodes
  the record and then the revision, which embeds the same record again (about
  64 µs). The remaining roughly 170 µs is six prepared statements (existence
  check, object insert, revision insert, a rowid lookup, FTS delete and FTS
  insert) plus a `SAVEPOINT`/`RELEASE` pair. All of them are compiled afresh on
  every call.
- **FTS cost grows with matches, not with `limit`.** A common word matches
  thousands of rows. The query joins `objects` to filter lifecycle and type and
  then sorts every match by `bm25` before applying `LIMIT`, so it takes 20 ms
  at 150,000 objects against 2 ms at 15,000.
- **Size.** Every object is stored as JSON in `objects.record` and again in
  each `revisions.record` snapshot. Measurements and claims add a third copy
  in their own table.

## Proposed store changes

These all touch `NexusStore.swift` and `SQLite.swift`, so they are proposals.
None of them changes the schema.

1. **Statement cache.** Keep a `[String: Statement]` on `SQLiteConnection`,
   and have `run` and `query` reuse the statement with `sqlite3_reset` and
   `sqlite3_clear_bindings` instead of `prepare`/`finalize` on every call.
   Every SQL string in the store is a constant or comes from a small closed
   set, so the cache stays bounded. Expect roughly 30–40 % off inserts and
   point lookups.
2. **Drop the rowid round-trip in `reindex`.** On insert, use
   `sqlite3_last_insert_rowid` (or `RETURNING row_id`); only updates need the
   lookup. On a fresh insert there is no FTS row to delete, so the `DELETE`
   can go too. That saves two statements per create.
3. **Encode once per write.** Encode the record once and build the revision
   JSON around that string, or store revisions as the record JSON plus a
   small header. That saves about 30 µs per write, and the database shrinks
   by about a third.
4. **Rank before joining in search.** Select candidate rowids from
   `search_index` with `ORDER BY rank LIMIT k` in a subquery (FTS5 can stop
   early there), then join `objects` and filter. Widen `k` and retry only when
   filters drop too many rows. Alternatively, carry `type` and `lifecycle` as
   `UNINDEXED` FTS columns so the common filters need no join.
5. **Faster decoding on hot paths.** For queries that only need a few fields
   (search hits, `measurements(at:)` for plotting), read the indexed columns
   and decode JSON lazily or not at all.
6. **Connection pragmas.** Set `temp_store = MEMORY` and a larger
   `cache_size` (for example −65536, which is 64 MB), and consider
   `mmap_size` for file stores. These are cheap one-line changes in `init`.

## Indexes

The benchmark found no missing index. Every query in the run uses an
existing index: `objects(id)`, `objects_type`, `relationships_from/_to`,
`measurements_test_point`, the revisions `UNIQUE(object_id, seq)` and
`claim_sources_source`. Migration 4 therefore adds only the `blobs` table,
whose `sha256 UNIQUE` constraint is the lookup index for blob deduplication.
