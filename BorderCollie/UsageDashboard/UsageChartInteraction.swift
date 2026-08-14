import CoreGraphics
import Foundation

struct UsageChartCurvePoint: Equatable, Identifiable {
    let date: Date
    let value: Double

    var id: Date { date }
}

enum UsageChartCurve {
    static func samples(
        points: [UsageChartCurvePoint],
        subdivisions: Int = 16
    ) -> [UsageChartCurvePoint] {
        guard points.count > 1, subdivisions > 1 else { return points }

        let ordered = points.sorted { $0.date < $1.date }
        let x = ordered.map(\.date.timeIntervalSinceReferenceDate)
        let y = ordered.map(\.value)

        guard zip(x, x.dropFirst()).allSatisfy({ $0 < $1 }) else { return ordered }

        let slopes = monotoneSlopes(x: x, y: y)
        var result: [UsageChartCurvePoint] = []
        result.reserveCapacity((ordered.count - 1) * subdivisions + 1)

        for index in 0..<(ordered.count - 1) {
            let width = x[index + 1] - x[index]
            for step in 0..<subdivisions {
                let fraction = Double(step) / Double(subdivisions)
                let sampledX = x[index] + width * fraction
                result.append(
                    UsageChartCurvePoint(
                        date: Date(timeIntervalSinceReferenceDate: sampledX),
                        value: hermiteValue(
                            start: y[index],
                            end: y[index + 1],
                            startSlope: slopes[index],
                            endSlope: slopes[index + 1],
                            width: width,
                            fraction: fraction
                        )
                    )
                )
            }
        }

        result.append(ordered[ordered.count - 1])
        return result
    }

    private static func monotoneSlopes(x: [Double], y: [Double]) -> [Double] {
        let count = x.count
        let widths = zip(x, x.dropFirst()).map { $0.1 - $0.0 }
        let secants = zip(y, y.dropFirst()).enumerated().map { index, pair in
            (pair.1 - pair.0) / widths[index]
        }

        guard count > 2 else {
            return [secants[0], secants[0]]
        }

        var slopes = Array(repeating: 0.0, count: count)
        slopes[0] = endpointSlope(
            firstWidth: widths[0],
            secondWidth: widths[1],
            firstSecant: secants[0],
            secondSecant: secants[1]
        )

        for index in 1..<(count - 1) {
            let previous = secants[index - 1]
            let next = secants[index]
            guard previous != 0, next != 0, previous.sign == next.sign else {
                slopes[index] = 0
                continue
            }

            let previousWidth = widths[index - 1]
            let nextWidth = widths[index]
            let firstWeight = 2 * nextWidth + previousWidth
            let secondWeight = nextWidth + 2 * previousWidth
            slopes[index] = (firstWeight + secondWeight) /
                (firstWeight / previous + secondWeight / next)
        }

        slopes[count - 1] = endpointSlope(
            firstWidth: widths[count - 2],
            secondWidth: widths[count - 3],
            firstSecant: secants[count - 2],
            secondSecant: secants[count - 3]
        )
        return slopes
    }

    private static func endpointSlope(
        firstWidth: Double,
        secondWidth: Double,
        firstSecant: Double,
        secondSecant: Double
    ) -> Double {
        var slope = ((2 * firstWidth + secondWidth) * firstSecant - firstWidth * secondSecant) /
            (firstWidth + secondWidth)

        if slope.sign != firstSecant.sign {
            slope = 0
        } else if firstSecant.sign != secondSecant.sign, abs(slope) > abs(3 * firstSecant) {
            slope = 3 * firstSecant
        }
        return slope
    }

    private static func hermiteValue(
        start: Double,
        end: Double,
        startSlope: Double,
        endSlope: Double,
        width: Double,
        fraction: Double
    ) -> Double {
        let squared = fraction * fraction
        let cubed = squared * fraction
        let startBasis = 2 * cubed - 3 * squared + 1
        let startSlopeBasis = cubed - 2 * squared + fraction
        let endBasis = -2 * cubed + 3 * squared
        let endSlopeBasis = cubed - squared
        return startBasis * start
            + startSlopeBasis * width * startSlope
            + endBasis * end
            + endSlopeBasis * width * endSlope
    }
}

enum UsageChartInteraction {
    /// Snap a raw x-position from `chartXSelection` onto the nearest sample the
    /// chart actually drew.
    ///
    /// The chart stacks its series, so a point's on-screen height is the
    /// running total rather than its own value. Hit-testing in two dimensions
    /// would therefore select by a coordinate that no longer means what the
    /// reader thinks it means; selection is indexed on x alone, and the callout
    /// reports every series at that x.
    static func nearestDate(to date: Date, in dates: [Date]) -> Date? {
        dates.min { first, second in
            abs(first.timeIntervalSince(date)) < abs(second.timeIntervalSince(date))
        }
    }

    /// Put every series on one shared date grid, filling absences with zero.
    ///
    /// Swift Charts stacks by matching x values. Agents only produce points for
    /// buckets they were active in, so without this an agent that idled on
    /// Tuesday would shift the bands above it rather than leave a gap.
    static func densified(
        series: [UsageAgent: [UsageChartCurvePoint]]
    ) -> [UsageAgent: [UsageChartCurvePoint]] {
        let grid = Set(series.values.flatMap { $0.map(\.date) }).sorted()
        guard !grid.isEmpty else { return series }

        return series.mapValues { points in
            let byDate = Dictionary(points.map { ($0.date, $0.value) }, uniquingKeysWith: +)
            return grid.map { UsageChartCurvePoint(date: $0, value: byDate[$0] ?? 0) }
        }
    }
}
