/// The earliest point where an actual run departs from a reference run.
public struct Divergence: Sendable, Hashable {
    public var tick: Int
    public var seconds: Double
    public var key: StateKey
    public var expected: Double
    public var actual: Double

    public var deviation: Double { actual - expected }
}

public enum DivergenceDetector {
    /// Compares two runs tick by tick and returns the first divergence.
    ///
    /// `signalPath` lists the watched keys upstream-first (e.g. terminal voltage
    /// before loop current before measured level). When several keys depart on
    /// the same tick, the most upstream one is reported, since downstream
    /// deviations are usually its consequences. Keys missing a tolerance use
    /// `defaultTolerance`.
    public static func firstDivergence(
        reference: [Snapshot],
        actual: [Snapshot],
        signalPath: [StateKey],
        tolerances: [StateKey: Double] = [:],
        defaultTolerance: Double = 1e-6
    ) -> Divergence? {
        let referenceByTick = Dictionary(reference.map { ($0.tick, $0) }, uniquingKeysWith: { _, last in last })
        for snapshot in actual.sorted(by: { $0.tick < $1.tick }) {
            guard let expected = referenceByTick[snapshot.tick] else { continue }
            for key in signalPath {
                guard let want = expected.values[key], let got = snapshot.values[key] else { continue }
                if abs(got - want) > (tolerances[key] ?? defaultTolerance) {
                    return Divergence(tick: snapshot.tick, seconds: snapshot.seconds, key: key, expected: want, actual: got)
                }
            }
        }
        return nil
    }
}
