import CoreGraphics
import Foundation

struct UsageChartHoverSelection: Equatable {
    let agent: UsageAgent
    let date: Date
    let value: Double
}

struct UsageChartCurvePoint: Equatable, Identifiable {
    let date: Date
    let value: Double

    var id: Date { date }
}

struct UsageChartScreenPoint: Equatable {
    let date: Date
    let value: Double
    let position: CGPoint
}

struct UsageChartScreenSeries: Equatable {
    let agent: UsageAgent
    let points: [UsageChartScreenPoint]
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
    static func nearestSelection(
        to pointer: CGPoint,
        series: [UsageChartScreenSeries],
        maximumDistance: CGFloat
    ) -> UsageChartHoverSelection? {
        var nearest: (selection: UsageChartHoverSelection, distance: CGFloat)?

        for item in series {
            guard let first = item.points.first else { continue }

            if item.points.count == 1 {
                consider(
                    selection: UsageChartHoverSelection(
                        agent: item.agent,
                        date: first.date,
                        value: first.value
                    ),
                    distance: distance(from: pointer, to: first.position),
                    maximumDistance: maximumDistance,
                    nearest: &nearest
                )
                continue
            }

            for (start, end) in zip(item.points, item.points.dropFirst()) {
                let projection = projection(of: pointer, ontoSegmentFrom: start.position, to: end.position)
                let selection = UsageChartHoverSelection(
                    agent: item.agent,
                    date: start.date.addingTimeInterval(
                        end.date.timeIntervalSince(start.date) * projection.fraction
                    ),
                    value: start.value + (end.value - start.value) * projection.fraction
                )
                consider(
                    selection: selection,
                    distance: projection.distance,
                    maximumDistance: maximumDistance,
                    nearest: &nearest
                )
            }
        }

        return nearest?.selection
    }

    private static func consider(
        selection: UsageChartHoverSelection,
        distance: CGFloat,
        maximumDistance: CGFloat,
        nearest: inout (selection: UsageChartHoverSelection, distance: CGFloat)?
    ) {
        guard distance <= maximumDistance else { return }
        guard let current = nearest else {
            nearest = (selection, distance)
            return
        }
        guard distance < current.distance else { return }
        nearest = (selection, distance)
    }

    private static func projection(
        of point: CGPoint,
        ontoSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> (fraction: Double, distance: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy

        guard squaredLength > 0 else {
            return (0, distance(from: point, to: start))
        }

        let unclamped = ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength
        let fraction = min(max(unclamped, 0), 1)
        let projected = CGPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
        return (Double(fraction), distance(from: point, to: projected))
    }

    private static func distance(from first: CGPoint, to second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
}
