import Foundation

/// Pure divider-weight math for the pane canvas (spec §5.1). Weights are
/// fractions of the canvas width, sum 1.0, each at least minimumFraction.
public enum SplitWeights {
    public static let minimumFraction: Double = 0.15

    public static func equal(count: Int) -> [Double] {
        let clamped = min(max(count, 1), 4)
        return Array(repeating: 1.0 / Double(clamped), count: clamped)
    }

    public static func sanitized(_ weights: [Double], count: Int) -> [Double] {
        let clampedCount = min(max(count, 1), 4)
        guard weights.count == clampedCount,
              weights.allSatisfy({ $0.isFinite && $0 > 0 })
        else { return equal(count: clampedCount) }
        let total = weights.reduce(0, +)
        var normalized = weights.map { $0 / total }
        var pinned = Set<Int>()
        // Each round pins at least one new index or terminates, so this
        // converges in at most `clampedCount` rounds.
        for _ in 0..<clampedCount {
            let deficit = normalized.indices.filter {
                !pinned.contains($0) && normalized[$0] < minimumFraction
            }
            guard !deficit.isEmpty else { break }
            for index in deficit {
                normalized[index] = minimumFraction
                pinned.insert(index)
            }
            let flexible = normalized.indices.filter { !pinned.contains($0) }
            guard !flexible.isEmpty else { return equal(count: clampedCount) }
            let fixedTotal = Double(pinned.count) * minimumFraction
            let flexibleTotal = flexible.map { normalized[$0] }.reduce(0, +)
            guard flexibleTotal > 0 else { return equal(count: clampedCount) }
            let scale = (1.0 - fixedTotal) / flexibleTotal
            for index in flexible { normalized[index] *= scale }
        }
        return normalized
    }

    public static func removing(index: Int, from weights: [Double]) -> [Double] {
        guard weights.indices.contains(index), weights.count > 1 else { return [1.0] }
        var rest = weights
        rest.remove(at: index)
        return sanitized(rest, count: rest.count)
    }

    /// Weights after appending a pane: newcomers get 1/(n+1), the rest
    /// scale down proportionally. At the 4-pane cap, re-normalizes with no growth.
    public static func appending(to weights: [Double]) -> [Double] {
        guard weights.count < 4 else { return sanitized(weights, count: weights.count) }
        let newCount = weights.count + 1
        let scale = Double(weights.count) / Double(newCount)
        var scaled = weights.map { $0 * scale }
        scaled.append(1.0 / Double(newCount))
        return sanitized(scaled, count: newCount)
    }
}
