# 0001 — Sync, backup and encryption at rest

Status: **proposed**. Needs the owner's decision on sync; backup and at-rest protection are implemented.

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
- If B is chosen, the next steps are:
  1. The CloudKit container and entitlement.
  2. A `NexusSync` Apple-only target.
  3. A record ↔ model mapping that can be tested on Linux.
