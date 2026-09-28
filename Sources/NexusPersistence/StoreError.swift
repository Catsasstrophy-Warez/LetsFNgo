import NexusCore
import NexusModel

public enum StoreError: Error, Equatable, Sendable {
    case sqlite(code: Int32, message: String)
    case schemaTooNew(found: Int, supported: Int)
    case notFound(ObjectID)
    case duplicate(ObjectID)
    /// A write tried to replace a protected (recorded/observed) value with a
    /// weaker truth class. See `TruthPolicy`.
    case truthConflict(object: ObjectID, attribute: String?, existing: TruthClass, incoming: TruthClass)
    /// A protected value may only be removed by a user or the system.
    case protectedRemoval(object: ObjectID, attribute: String, by: Origin)
    case immutableField(object: ObjectID, field: String)
    /// Measurements are append-only; claims change through claim APIs.
    case immutableRecord(ObjectID, ObjectType)
    case corruptRecord(table: String, id: String)
    /// The revision does not exist or belongs to a different object.
    case revisionNotFound(object: ObjectID, revision: RevisionID)
    /// The lifecycle transition is not allowed. See `NexusStore.allowedTransitions`.
    case invalidTransition(object: ObjectID, from: Lifecycle, to: Lifecycle)
    /// A file offered as a backup is not a Nexus store this build can open.
    case invalidBackup(reason: String)
    /// Restoring a backup would overwrite an existing file.
    case destinationExists(String)
}
