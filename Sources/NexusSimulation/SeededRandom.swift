/// SplitMix64: a tiny, fast, fully deterministic pseudo-random generator.
///
/// Used wherever a simulation or a dataset needs "random" choices that must
/// replay bit-for-bit from a seed on every platform. It never touches
/// Foundation or system randomness.
public struct SplitMix64: RandomNumberGenerator, Sendable, Hashable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return Self.mix(state)
    }

    /// A uniform value in [0, 1) with 53 bits of precision.
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// A uniform value in `range`.
    public mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
    }

    /// A uniform integer in `0..<bound`. `bound` must be positive.
    public mutating func nextInt(below bound: Int) -> Int {
        precondition(bound > 0, "bound must be positive")
        return Int(next() % UInt64(bound))
    }

    /// A uniformly chosen element. `elements` must not be empty.
    public mutating func pick<T>(_ elements: [T]) -> T {
        elements[nextInt(below: elements.count)]
    }

    /// The SplitMix64 finalizer. Also a good stateless hash of one word.
    public static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
