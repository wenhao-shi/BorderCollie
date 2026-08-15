import Foundation

struct TrajectoryProjectedRecord: Equatable, Sendable, Identifiable {
    let id: String
    let parentID: String?
    let turnID: String?
    let depth: Int
    let lane: TrajectoryLane
    let canonicalOrder: Int
    let axisStart: Double
    let axisEnd: Double?
    let isPoint: Bool
    let isUnscoped: Bool
}

struct TrajectoryProjectionIssue: Equatable, Sendable, Identifiable {
    let id: String
    let recordID: String?
    let kind: Kind

    enum Kind: String, Codable, Sendable {
        case missingParent = "missing_parent"
        case parentCycle = "parent_cycle"
        case missingTurn = "missing_turn"
        case outsideActiveTime = "outside_active_time"
    }
}

struct TrajectoryProjectionResult: Equatable, Sendable {
    let records: [TrajectoryProjectedRecord]
    let issues: [TrajectoryProjectionIssue]
    let axisLowerBound: Double
    let axisUpperBound: Double
}

enum TrajectoryProjection {
    static func make(
        report: TrajectorySessionReport,
        mode: TrajectoryTimeMode,
        collapsedRecordIDs: Set<String>
    ) -> TrajectoryProjectionResult {
        let turns = report.turns.sorted {
            $0.startedAtMilliseconds == $1.startedAtMilliseconds ? $0.id < $1.id : $0.startedAtMilliseconds < $1.startedAtMilliseconds
        }
        let activities = report.activities.sorted {
            if $0.sourceOrder != $1.sourceOrder { return $0.sourceOrder < $1.sourceOrder }
            if $0.startedAtMilliseconds != $1.startedAtMilliseconds { return $0.startedAtMilliseconds < $1.startedAtMilliseconds }
            return $0.id < $1.id
        }

        var issues: [TrajectoryProjectionIssue] = []
        var issueIDs: Set<String> = []
        func addIssue(recordID: String?, kind: TrajectoryProjectionIssue.Kind) {
            let id = "\(kind.rawValue):\(recordID ?? "session")"
            guard issueIDs.insert(id).inserted else { return }
            issues.append(TrajectoryProjectionIssue(id: id, recordID: recordID, kind: kind))
        }

        let turnIDs = Set(turns.map(\.id))
        let activityByID = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        var parents: [String: String?] = [:]
        for activity in activities {
            let turnParent = activity.turnID.flatMap { turnIDs.contains($0) ? $0 : nil }
            if let parentID = activity.parentActivityID {
                guard let parent = activityByID[parentID], parent.sessionKey == report.summary.sessionKey else {
                    addIssue(recordID: activity.id, kind: .missingParent)
                    parents[activity.id] = turnParent
                    continue
                }
                parents[activity.id] = parent.id
            } else {
                parents[activity.id] = turnParent
            }
            if activity.turnID == nil || !turnIDs.contains(activity.turnID ?? "") {
                addIssue(recordID: activity.id, kind: .missingTurn)
            }
        }

        var cycleIDs: Set<String> = []
        for activity in activities {
            var path: [String] = []
            var positions: [String: Int] = [:]
            var current: String? = activity.id
            while let id = current {
                if let position = positions[id] {
                    cycleIDs.formUnion(path[position...])
                    break
                }
                guard activityByID[id] != nil else { break }
                positions[id] = path.count
                path.append(id)
                current = parents[id] ?? nil
            }
        }
        for id in cycleIDs {
            parents[id] = activityByID[id]?.turnID.flatMap { turnIDs.contains($0) ? $0 : nil }
            addIssue(recordID: id, kind: .parentCycle)
        }

        let baseTurns = turns.map { turn in
            TrajectoryBaseRecord(
                id: turn.id,
                parentID: nil,
                turnID: turn.id,
                lane: .turn,
                startedAtMilliseconds: turn.startedAtMilliseconds,
                endedAtMilliseconds: turn.endedAtMilliseconds,
                isPoint: turn.startedAtMilliseconds == turn.endedAtMilliseconds,
                isUnscoped: false,
                sourceOrder: Int64.max,
                isActivity: false
            )
        }
        let baseActivities = activities.map { activity in
            let end = activity.endedAtMilliseconds
            return TrajectoryBaseRecord(
                id: activity.id,
                parentID: parents[activity.id] ?? nil,
                turnID: activity.turnID,
                lane: lane(for: activity.kind),
                startedAtMilliseconds: activity.startedAtMilliseconds,
                endedAtMilliseconds: end,
                isPoint: end == activity.startedAtMilliseconds && end != nil,
                isUnscoped: activity.turnID == nil || !turnIDs.contains(activity.turnID ?? ""),
                sourceOrder: activity.sourceOrder,
                isActivity: true
            )
        }
        let allBases = baseTurns + baseActivities
        let sortedIDs = allBases.sorted { lhs, rhs in
            if lhs.isActivity && rhs.isActivity {
                if lhs.sourceOrder != rhs.sourceOrder {
                    return lhs.sourceOrder < rhs.sourceOrder
                }
                if lhs.startedAtMilliseconds != rhs.startedAtMilliseconds {
                    return lhs.startedAtMilliseconds < rhs.startedAtMilliseconds
                }
                return lhs.id < rhs.id
            }
            if lhs.isActivity != rhs.isActivity {
                if lhs.startedAtMilliseconds != rhs.startedAtMilliseconds {
                    return lhs.startedAtMilliseconds < rhs.startedAtMilliseconds
                }
                return !lhs.isActivity
            }
            if lhs.startedAtMilliseconds != rhs.startedAtMilliseconds {
                return lhs.startedAtMilliseconds < rhs.startedAtMilliseconds
            }
            return lhs.id < rhs.id
        }.map(\.id)
        let baseByID = Dictionary(uniqueKeysWithValues: allBases.map { ($0.id, $0) })
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for id in sortedIDs {
            guard let base = baseByID[id] else { continue }
            if let parentID = base.parentID, baseByID[parentID] != nil {
                children[parentID, default: []].append(id)
            } else {
                roots.append(id)
            }
        }
        let orderByID = Dictionary(uniqueKeysWithValues: sortedIDs.enumerated().map { ($1, $0) })
        for key in children.keys {
            children[key]?.sort { (orderByID[$0] ?? .max) < (orderByID[$1] ?? .max) }
        }
        roots.sort { (orderByID[$0] ?? .max) < (orderByID[$1] ?? .max) }

        var flattened: [(TrajectoryBaseRecord, Int)] = []
        func append(_ id: String, depth: Int) {
            guard let base = baseByID[id] else { return }
            flattened.append((base, depth))
            for child in children[id] ?? [] { append(child, depth: depth + 1) }
        }
        for root in roots { append(root, depth: 0) }

        var hidden: Set<String> = []
        func hideDescendants(of id: String) {
            for child in children[id] ?? [] {
                guard hidden.insert(child).inserted else { continue }
                hideDescendants(of: child)
            }
        }
        for collapsedID in collapsedRecordIDs where baseByID[collapsedID] != nil {
            if baseByID[collapsedID]?.isActivity == false {
                for child in allBases where child.isActivity && child.turnID == collapsedID {
                    guard hidden.insert(child.id).inserted else { continue }
                    hideDescendants(of: child.id)
                }
            } else {
                hideDescendants(of: collapsedID)
            }
        }

        let activeIntervals = mergedIntervals(turns.map {
            ($0.startedAtMilliseconds, $0.endedAtMilliseconds)
        })
        let clockLower = allBases.map(\.startedAtMilliseconds).min() ?? 0
        let clockUpper = allBases.compactMap { $0.endedAtMilliseconds ?? $0.startedAtMilliseconds }.max() ?? clockLower
        let clockBounds = (Double(clockLower) / 1_000, max(Double(clockUpper) / 1_000, Double(clockLower) / 1_000 + 1))
        let activeDuration = activeIntervals.reduce(0.0) { $0 + Double($1.1 - $1.0) / 1_000 }
        let activeUpper = max(activeDuration, 1)
        let orderUpper = max(Double(flattened.count), 1)

        var records: [TrajectoryProjectedRecord] = []
        for (index, item) in flattened.enumerated() where !hidden.contains(item.0.id) {
            let base = item.0
            let coordinate = coordinates(
                for: base,
                index: index,
                mode: mode,
                activeIntervals: activeIntervals
            )
            if mode == .activeTime && !overlaps(base, intervals: activeIntervals) {
                addIssue(recordID: base.id, kind: .outsideActiveTime)
            }
            records.append(TrajectoryProjectedRecord(
                id: base.id,
                parentID: base.parentID,
                turnID: base.turnID,
                depth: item.1,
                lane: base.lane,
                canonicalOrder: index,
                axisStart: coordinate.0,
                axisEnd: coordinate.1,
                isPoint: base.isPoint,
                isUnscoped: base.isUnscoped
            ))
        }

        let lower: Double
        let upper: Double
        switch mode {
        case .order:
            lower = 0
            upper = orderUpper
        case .activeTime:
            lower = 0
            upper = activeUpper
        case .clockTime:
            lower = clockBounds.0
            upper = clockBounds.1
        }
        return TrajectoryProjectionResult(
            records: records,
            issues: issues,
            axisLowerBound: lower,
            axisUpperBound: upper
        )
    }

    static func recordIDs(
        overlapping range: ClosedRange<Double>,
        in projection: TrajectoryProjectionResult
    ) -> Set<String> {
        let outside = Set(projection.issues.compactMap { issue in
            issue.kind == .outsideActiveTime ? issue.recordID : nil
        })
        return Set(projection.records.compactMap { record in
            guard !outside.contains(record.id) else { return nil }
            let end = record.axisEnd ?? record.axisStart
            return record.axisStart <= range.upperBound && end >= range.lowerBound ? record.id : nil
        })
    }

    private static func lane(for kind: TrajectoryActivityKind) -> TrajectoryLane {
        switch kind {
        case .modelRequest, .retry, .compaction: .model
        case .tool, .subtool: .tools
        }
    }

    private static func mergedIntervals(_ values: [(Int64, Int64)]) -> [(Int64, Int64)] {
        let sorted = values.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        guard var current = sorted.first else { return [] }
        var result: [(Int64, Int64)] = []
        for value in sorted.dropFirst() {
            if value.0 <= current.1 {
                current.1 = max(current.1, value.1)
            } else {
                result.append(current)
                current = value
            }
        }
        result.append(current)
        return result
    }

    private static func overlaps(_ base: TrajectoryBaseRecord, intervals: [(Int64, Int64)]) -> Bool {
        let end = base.endedAtMilliseconds ?? base.startedAtMilliseconds
        return intervals.contains { base.startedAtMilliseconds <= $0.1 && end >= $0.0 }
    }

    private static func coordinates(
        for base: TrajectoryBaseRecord,
        index: Int,
        mode: TrajectoryTimeMode,
        activeIntervals: [(Int64, Int64)]
    ) -> (Double, Double?) {
        switch mode {
        case .order:
            let start = Double(index)
            return (start, base.endedAtMilliseconds == nil ? nil : (base.isPoint ? start : start + 1))
        case .clockTime:
            let start = Double(base.startedAtMilliseconds) / 1_000
            let end = base.endedAtMilliseconds.map { Double($0) / 1_000 }
            return (start, end)
        case .activeTime:
            let start = activeCoordinate(base.startedAtMilliseconds, intervals: activeIntervals)
            let end = base.endedAtMilliseconds.map { activeCoordinate($0, intervals: activeIntervals) }
            return (start, end)
        }
    }

    private static func activeCoordinate(_ value: Int64, intervals: [(Int64, Int64)]) -> Double {
        var accumulated = 0.0
        for interval in intervals {
            if value < interval.0 { return accumulated }
            if value <= interval.1 {
                return accumulated + Double(max(value - interval.0, 0)) / 1_000
            }
            accumulated += Double(interval.1 - interval.0) / 1_000
        }
        return accumulated
    }
}

private struct TrajectoryBaseRecord {
    let id: String
    let parentID: String?
    let turnID: String?
    let lane: TrajectoryLane
    let startedAtMilliseconds: Int64
    let endedAtMilliseconds: Int64?
    let isPoint: Bool
    let isUnscoped: Bool
    let sourceOrder: Int64
    let isActivity: Bool
}
