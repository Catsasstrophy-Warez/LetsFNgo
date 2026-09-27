/// The seven truth classes from the locked decisions. They are never silently
/// collapsed: every stored value records which one it is.
public enum TruthClass: String, Codable, Sendable, CaseIterable {
    /// Direct trusted external-system record.
    case recorded
    /// Measurement or human observation.
    case observed
    /// Simulation result.
    case modeled
    /// Assertion by a source.
    case claimed
    /// Calculation or transformation of other values.
    case derived
    /// Value shown by a device or UI (an HMI reading, a gauge face).
    case display
    /// Conclusion reached by an AI agent or model.
    case agentInterpretation
}

/// Rules for when one truth class may replace another on the same value.
///
/// Recorded and observed truth are protected: simulation output, claims,
/// derivations, display values and agent conclusions may sit *beside* them but
/// never overwrite them. Only another recorded or observed value can supersede
/// a protected one, and that replacement is still revisioned.
public enum TruthPolicy {
    public static let protected: Set<TruthClass> = [.recorded, .observed]

    public static func canReplace(existing: TruthClass, with incoming: TruthClass) -> Bool {
        guard protected.contains(existing) else { return true }
        return protected.contains(incoming)
    }
}
