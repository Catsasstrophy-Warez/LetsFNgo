# 0001 — Sync, backup and encryption at rest

Status: **accepted: B** (CloudKit private database). The owner chose option B. The sync engine, the CloudKit transport, the Keychain key, backup and at-rest protection are implemented; see "Built: option B" below.

## Context
Nexus is local-first. One SQLite file is the canonical store, per the locked decisions. It will hold equipment data, measurements, meeting notes, and possibly finance and personal data later. People will use it on iPhone, iPad and Mac.

## Decided and implemented
- **Encryption at rest:** iOS Data Protection on the store directory, `completeUntilFirstUserAuthentication` (set in `NexusEnvironment.live`). The stricter `complete` class would stop Spotlight indexing and background agent runs while the device is locked. On macOS we rely on FileVault plus the app sandbox.
- **Backup:** `NexusStore.backup(to:)` writes a consistent, compacted snapshot (SQLite `VACUUM INTO`) that opens as a normal store. Device backups (iCloud Backup / Finder) already include the app container. An explicit export lets people keep their own copies.

## Options for sync (owner's call)
| Option | Pros | Cons |
|---|---|---|
| **A. Local-only** (today) | Simplest. Nothing leaves the device. | No iPhone ↔ Mac continuity. |
| **B. CloudKit private database via `CKSyncEngine`** | Apple-native, end-to-end encrypted (Advanced Data Protection), no server of ours. The change feed (`changes` table) already gives exactly the "what changed since seq N" stream a sync engine needs. | Conflict rules to design. Record size limits push blobs to `CKAsset`. Apple-only. |
| **C. Own sync server** | Cross-platform, full control. | Servers, auth and key management become our problem. It contradicts the local-first, privacy-first stance. |

**Recommendation: B.** Mirror objects, relationships, events, claims and measurements as CloudKit records keyed by ObjectID. Revisions travel as their own records, so history merges rather than overwrites.

Conflict policy follows the truth model:
- Protected values (recorded/observed) never lose to weaker truth classes.
- Concurrent edits of the same object keep both revisions. The newer revision becomes the head, and the other stays in history, flagged for review.

Measurements are append-only, so they never conflict.

## Consequences
- The sync engine consumes `changes(after:)` and writes through the same `NexusStore` APIs, so `TruthPolicy` and revisions apply to synced writes too.
- With B chosen, these were built (see "Built: option B"):
  1. The CloudKit container and entitlement, opt-in per build.
  2. The Apple-only CloudKit transport, Keychain key and FileVault check, in `NexusSync` behind `#if canImport`.
  3. A record ↔ change set mapping that is tested on Linux.

## Implemented: the transport-independent half of sync
Whichever transport the owner picks, these parts are the same, so they are built and tested on Linux:

- **Change feed for sync** (migration 7). `sync_log` holds one row per changed entity and is maintained by SQL triggers, so no write path can skip it. `NexusStore.changeSet(since:)` returns a versioned, Codable `ChangeSet`: objects and relationships (current state, head revision, per-field clocks), events, measurements, claims, blob references by SHA-256, telemetry channels and chunk refs, tombstones and preserved alternates, plus the sender's `ReplicaID`.
- **Merge** in `NexusStore.apply(_:from:)`, atomic and idempotent:
  - Events, measurements and claims are append-only and union by ID.
  - Objects and relationships merge per field (title, lifecycle, provenance, validFrom, validTo, each attribute). The later field clock wins, and the higher replica ID breaks a tie.
  - `TruthPolicy` comes first. A recorded or observed value never loses to an unprotected one, whatever the clocks say. A newer agent/modeled value that loses this way is kept as an `AlternateRevision` plus a `syncConflict` event. Both IDs derive from the conflict, so every replica records the same rows. Only a user or the system may remove a protected value, and a newer removal by them wins.
  - Deletes are tombstones. A `deleted` lifecycle and a closed validity interval always win. Deleted telemetry channels and pruned chunks leave `sync_tombstones` rows, so a stale replica cannot resurrect them.
  - Blob bytes travel separately. `apply` lists the missing blobs, and `receiveBlob(_:)` stores them once they arrive.
- **Relationship history.** Every `relate`, `end`, `updateRelationship` and synced merge writes a `RelationshipRevision`.
- **`NexusSync`**: `SyncTransport` (push, pull, fetch blob, put blob), `InMemorySyncTransport` and a `SyncEngine` that pushes, pulls, applies and fetches blobs. A CloudKit transport (`CKSyncEngine`) or any other implements `SyncTransport` only.

## StoreEncryption: encryption at rest
**iOS and iPadOS (in place).** Data Protection on the store directory, class `completeUntilFirstUserAuthentication`. The key is tied to the passcode and the Secure Enclave. The database, WAL and blob directory are unreadable until the first unlock after boot. `complete` would be stronger, but it would stop background agent runs, Spotlight and sync while the device is locked.

**macOS: FileVault vs SQLCipher.**
- **FileVault plus the sandbox (today).** Full-disk encryption covers the store with no code or dependency. It doesn't protect a running, unlocked Mac from other processes of the same user outside the sandbox, or a copy of the file taken while the disk is unlocked (for example a backup to an unencrypted drive). FileVault is on by default on Apple silicon Macs but can be off, so the app should check it and say so.
- **SQLCipher.** Page-level AES-256 of the database file, keyed from the Keychain. Costs:
  - **Licensing.** The Community Edition is BSD-style and needs attribution. The Commercial and Enterprise editions (paid per product/platform) add FIPS builds, support and performance work.
  - **Dependency.** It replaces the system `libsqlite3` everywhere. That means a vendored C amalgamation or an XCFramework build per platform, with its own FTS5 and JSON flags, kept up to date with SQLite security releases ourselves. `CSQLite`'s module map and the Linux CI image would change with it.
  - **Runtime.** A 5–15 % I/O overhead. `VACUUM INTO` backups need `sqlcipher_export`.
  - **Coverage.** It doesn't cover the blob directory, which would need its own file encryption.
- **Recommendation.** Stay on FileVault plus the sandbox, and surface a warning when FileVault is off. Revisit SQLCipher only if a regulated domain (finance, health) or a shared-Mac requirement arrives. At that point, encrypting blobs with the same Keychain key comes with it.

**Sync payloads: CryptoKit AES-GCM with a Keychain key (implemented as a helper).** CloudKit private-database records are encrypted by Apple. They are end-to-end only when the user has Advanced Data Protection on, and `CKAsset` files are not end-to-end otherwise. So Nexus seals every change set and every blob before it leaves the device:
- **`NexusSync.PayloadCipher`.** AES-256-GCM, via CryptoKit on Apple platforms and `apple/swift-crypto` (the same API) on Linux. The format is a version byte, then the 12-byte nonce, the ciphertext and the 16-byte tag. Associated data binds a payload to its record (a replica ID or a blob's SHA-256), so a ciphertext can't be replayed onto another record. `InMemorySyncTransport(cipher:)` exercises it end to end in the tests.
- **Key.** 256 random bits, generated once on the first device. It is stored as a Keychain generic password with `kSecAttrSynchronizable = true` and `kSecAttrAccessibleAfterFirstUnlock`, so iCloud Keychain (itself end-to-end encrypted) carries it to the user's other devices, and Apple never holds it next to the ciphertext. A device without the key can't read synced data. Recovery is re-pairing from a device that has it. Key rotation will need a new format version that carries a key ID. The Keychain wrapper is `NexusSync.SyncKeychain` (Apple-only).
- **Dependency cost.** `swift-crypto` builds only off Apple platforms (a platform condition on the product), so the app links CryptoKit and nothing extra. It is held at 3.9.x. From 3.10 its BoringSSL is C++, and on Linux a C++ link fails against Swift 6.2's `libswiftObservation` (undefined `swift::threading::fatal`). Lift the cap once the toolchain is fixed.

## Built: option B
Everything except the `CKDatabase` calls is plain Swift and is tested on Linux.

- **Records** (`SyncRecordCodec`). There are two custom zones in the private database.
  - `NexusChangeSets` holds one `NexusChangeSet` record per pushed change set, named `cs-<change set ID>`. Its plain fields are what a reader needs before decrypting: `replica`, `since`, `through`, `createdAt`, `version`, `layout`, `keyID`, `byteCount` and `digest`, the SHA-256 of the sealed bytes. The payload is the change set's JSON, sealed with `PayloadCipher`. The associated data covers the record name, replica and range, so a payload can't be moved to another record and the plain fields can't be edited unnoticed.
  - A sealed payload of up to 700 KB goes inline in `payload`, well under CloudKit's 1 MB record limit. A larger one is split into `CKAsset` parts in `parts`, 32 MB each.
  - `NexusBlobs` holds `NexusBlob` records, named `blob-<sha256>`. They are always sealed assets, bound to their digest. Blobs have their own zone so that fetching change sets never downloads blob bytes. Content addressing makes uploads idempotent: an existing blob is detected without downloading it, and a racing duplicate save counts as success.
- **Transport** (`RecordSyncTransport` over a `SyncRecordDatabase`).
  - Push saves a record. Pull follows the zone's change feed, page by page, and skips the device's own records before decrypting.
  - The `SyncCursor` is the server change token, base64-encoded. An expired token restarts the feed from the start, which is safe because `apply` is idempotent.
  - A missing zone is created on first use, or after the user deletes the app's iCloud data.
  - `InMemoryRecordDatabase` mimics CloudKit's semantics for tests: zones, atomic saves, change tags, `serverRecordChanged`, the 1 MB limit, paged change feeds, and tokens that expire when a zone is deleted.
- **CloudKit** (`CloudKitSyncTransport`, `CloudKitRecordDatabase`, Apple-only). It uses `CKDatabase` zone change fetches with server change tokens instead of `CKSyncEngine`. `SyncEngine` already owns scheduling, state and merging, and a token maps one-to-one onto `SyncCursor`, so the in-memory fake covers the logic.
  - The iCloud account is checked before each push and pull.
  - `CKError`s map to a typed `CloudSyncError`: account unavailable, quota exceeded, network, rate limited, zone not found, server record changed, change token expired, record too large, not configured and permission failure. A record sealed with another key raises `keyMismatch`.
- **Key** (`SyncKeychain`, Apple-only). A generic password, `kSecAttrSynchronizable = true`, `kSecAttrAccessibleAfterFirstUnlock`, in the data-protection keychain.
  - Records carry a 16-hex-digit fingerprint of the key (`PayloadCipher.keyID`), so a device holding another key reports a mismatch rather than a decryption failure.
  - Turn sync on first on one device, so the others receive its key through iCloud Keychain.
- **FileVault** (`DiskEncryption`). A best-effort, sandbox-safe read of the volume's `volumeIsEncrypted` value. Settings → Sync on a Mac warns when the volume isn't encrypted. On Apple silicon the volume can report encryption without FileVault, so "on" is not proof.
- **App.**
  - `SyncLoop` runs `SyncEngine` at launch, on foreground, every 5 minutes, and 5 s after local changes. Only one sync runs at a time.
  - Settings → Sync shows the last sync, errors, pending files and the number of `syncConflict` events.
  - Sync is off by default. CloudKit is compiled into the app only with `NEXUS_CLOUDKIT_ENABLED=YES`, which adds `App/NexusCloud.entitlements` (container `iCloud.$(NEXUS_BUNDLE_ID)`) and the `NEXUS_CLOUDKIT` condition. A free Apple ID can't sign that entitlement, so the default build leaves it out. docs/DEVICE.md → "iCloud sync" has the setup.
- **Not yet.**
  - Push notifications for immediate fetches (CloudKit subscriptions). Sync is polled instead.
  - Key rotation.
  - Compacting old change-set records.
  - Re-pushing history after the user deletes the app's iCloud data. The zone is recreated, but only changes made after that are uploaded.

