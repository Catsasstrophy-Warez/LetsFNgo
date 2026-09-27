import Foundation

/// Point-count reduction that keeps a chart's visual shape.
public enum Downsampling {
    /// Largest-Triangle-Three-Buckets (Steinarsson, 2013).
    ///
    /// Keeps the first and last points, splits the rest into `threshold - 2`
    /// buckets, and from each bucket keeps the point forming the largest
    /// triangle with the previously kept point and the next bucket's average.
    /// Peaks and troughs survive, which plain decimation loses.
    ///
    /// Returns the input unchanged when it already has `threshold` points or
    /// fewer, or when `threshold < 3`. Points must be sorted by `x`.
    public static func lttb(_ points: [DataPoint], threshold: Int) -> [DataPoint] {
        let count = points.count
        guard threshold >= 3, count > threshold else { return points }

        var sampled: [DataPoint] = []
        sampled.reserveCapacity(threshold)
        sampled.append(points[0])

        let bucketSize = Double(count - 2) / Double(threshold - 2)
        var anchor = 0

        points.withUnsafeBufferPointer { buffer in
            for bucket in 0..<(threshold - 2) {
                // The current bucket's range.
                let start = Int(Double(bucket) * bucketSize) + 1
                let end = min(Int(Double(bucket + 1) * bucketSize) + 1, count - 1)

                // Average of the next bucket (the last point for the final bucket).
                let nextStart = end
                let nextEnd = min(Int(Double(bucket + 2) * bucketSize) + 1, count)
                var averageX = 0.0
                var averageY = 0.0
                let nextCount = max(1, nextEnd - nextStart)
                for index in nextStart..<max(nextStart + 1, nextEnd) {
                    averageX += buffer[index].x
                    averageY += buffer[index].y
                }
                averageX /= Double(nextCount)
                averageY /= Double(nextCount)

                let a = buffer[anchor]
                var largest = -1.0
                var chosen = start
                for index in start..<max(start + 1, end) {
                    let p = buffer[index]
                    // Twice the triangle area; the factor doesn't change the argmax.
                    let area = abs((a.x - averageX) * (p.y - a.y) - (a.x - p.x) * (averageY - a.y))
                    if area > largest {
                        largest = area
                        chosen = index
                    }
                }
                sampled.append(buffer[chosen])
                anchor = chosen
            }
        }

        sampled.append(points[count - 1])
        return sampled
    }

    /// LTTB applied to each series, keeping unit, truth and identity.
    public static func lttb(_ series: SeriesSpec, threshold: Int) -> SeriesSpec {
        var copy = series
        copy.points = lttb(series.points, threshold: threshold)
        return copy
    }
}
