import Foundation
import NexusCore
import NexusVisualization

/// One sample: a time (seconds since the reference date) and a value in
/// the channel's unit.
public struct TelemetrySample: Codable, Sendable, Hashable {
    public var time: Double
    public var value: Double

    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }

    public init(date: Date, value: Double) {
        self.init(time: date.timeIntervalSinceReferenceDate, value: value)
    }

    public var date: Date { Date(timeIntervalSinceReferenceDate: time) }
}

/// The chunk payload format: little-endian Float64 pairs (time, value),
/// 16 bytes per sample. On little-endian hosts (every Apple and Linux target
/// Nexus ships on) samples are copied as one block.
enum SampleCodec {
    static let encoding = "f64le-pairs"

    /// True when `TelemetrySample`'s in-memory layout is the payload format.
    private static let blockCopy: Bool = {
        #if _endian(little)
            return MemoryLayout<TelemetrySample>.size == 16 && MemoryLayout<TelemetrySample>.stride == 16
                && MemoryLayout<TelemetrySample>.offset(of: \.time) == 0 && MemoryLayout<TelemetrySample>.offset(of: \.value) == 8
        #else
            return false
        #endif
    }()

    static func encode(_ samples: ArraySlice<TelemetrySample>) -> Data {
        if blockCopy {
            return samples.withUnsafeBytes { Data($0) }
        }
        var data = Data(capacity: samples.count * 16)
        for sample in samples {
            withUnsafeBytes(of: sample.time.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: sample.value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data, count: Int, into samples: inout [TelemetrySample]) throws {
        guard data.count == count * 16 else { throw TelemetryError.corruptChunk }
        if blockCopy {
            let start = samples.count
            samples.append(contentsOf: repeatElement(TelemetrySample(time: 0, value: 0), count: count))
            samples.withUnsafeMutableBytes { target in
                data.withUnsafeBytes { source in
                    target.baseAddress!.advanced(by: start * 16).copyMemory(from: source.baseAddress!, byteCount: count * 16)
                }
            }
            return
        }
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let time = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: index * 16, as: UInt64.self)))
                let value = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: index * 16 + 8, as: UInt64.self)))
                samples.append(TelemetrySample(time: time, value: value))
            }
        }
    }
}

public enum TelemetryError: Error, Equatable, Sendable {
    case channelNotFound(ObjectID)
    /// Sample times must be finite; values may be NaN (a dropout) but not infinite.
    case invalidSample(index: Int)
    case unsupportedEncoding(String)
    case corruptChunk
}

extension TelemetryError: ClassifiableError {
    public var classified: ClassifiedError {
        switch self {
        case .channelNotFound:
            ClassifiedError(
                category: .dataSource, whatHappened: "That telemetry channel doesn't exist.", whatSurvived: ["Other channels are unchanged."],
                nextActions: [NextAction("Choose another channel")]
            )
        case .invalidSample(let index):
            ClassifiedError(
                category: .dataSource, whatHappened: "Sample \(index) has an invalid time or value, so the batch wasn't saved.",
                whatSurvived: ["Samples saved before this batch are kept."], nextActions: [NextAction("Check the source and resend")]
            )
        case .unsupportedEncoding(let encoding):
            ClassifiedError(
                category: .systemRuntime, whatHappened: "Stored samples use a format (\(encoding)) this version can't read.",
                whatSurvived: ["The stored samples are unchanged."], nextActions: [NextAction("Update the app")]
            )
        case .corruptChunk:
            ClassifiedError(
                category: .dataSource, whatHappened: "Some stored samples are damaged.", whatSurvived: ["Other samples are unchanged."],
                nextActions: [NextAction("Restore from a backup")]
            )
        }
    }
}

extension Array where Element == TelemetrySample {
    /// LTTB-downsampled to at most `maxPoints`, keeping the first and last samples.
    public func downsampled(to maxPoints: Int) -> [TelemetrySample] {
        guard count > maxPoints, maxPoints >= 3 else { return self }
        return Downsampling.lttb(map { DataPoint($0.time, $0.value) }, threshold: maxPoints).map { TelemetrySample(time: $0.x, value: $0.y) }
    }
}
