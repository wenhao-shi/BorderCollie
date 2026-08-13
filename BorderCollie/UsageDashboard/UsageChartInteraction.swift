import CoreGraphics
import Foundation

struct UsageChartHoverSelection: Equatable {
    let agent: UsageAgent
    let date: Date
    let value: Double
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
