import Foundation

struct UsageEvaluationAggregator: Sendable {
    func report(
        run: EvaluationRun,
        availableSessions: [EvaluationSessionSummary],
        selectedSessionKeys: Set<String>,
        events: [UsageEvent],
        turns: [UsageActiveTurn],
        endingAt fallbackEnd: Date = Date()
    ) throws -> UsageEvaluationReport {
        guard let interval = run.interval(endingAt: fallbackEnd) else {
            throw UsageAggregationError.invalidDateInterval
        }
        let intervalStart = UsageEpoch.milliseconds(interval.start)
        let intervalEnd = UsageEpoch.milliseconds(interval.end)
        let selectedEvents = events.filter {
            guard let sessionKey = $0.sessionKey else { return false }
            return selectedSessionKeys.contains(sessionKey)
                && $0.occurredAtMilliseconds >= intervalStart
                && $0.occurredAtMilliseconds < intervalEnd
        }
        let complete = selectedEvents.filter { $0.completeness == .complete }
        let priced = complete.filter { $0.estimatedAPICostNanodollars != nil }

        let input = try sum(complete.compactMap(\.inputTokens))
        let cacheWrite = try sum(complete.compactMap(\.cacheWriteTokens))
        let cacheRead = try sum(complete.compactMap(\.cacheReadTokens))
        let output = try sum(complete.compactMap(\.outputTokens))
        let reasoning = try sum(complete.compactMap(\.reasoningOutputTokens))
        let total = try sum(complete.compactMap(\.totalTokens))
        let cost = try sum(priced.compactMap(\.estimatedAPICostNanodollars))
        let observedInput = try sum([input, cacheWrite, cacheRead])

        let clippedTurns = turns.compactMap { turn -> ClippedTurn? in
            guard selectedSessionKeys.contains(turn.sessionKey) else { return nil }
            let start = max(turn.startedAtMilliseconds, intervalStart)
            let end = min(turn.endedAtMilliseconds, intervalEnd)
            guard end > start else { return nil }
            return ClippedTurn(turn: turn, start: start, end: end)
        }

        var sessionIntervals: [String: [MillisecondInterval]] = [:]
        var modelSessionIntervals: [ModelSessionKey: [MillisecondInterval]] = [:]
        for item in clippedTurns {
            let interval = MillisecondInterval(start: item.start, end: item.end)
            sessionIntervals[item.turn.sessionKey, default: []].append(interval)
            let model = item.turn.canonicalModelID ?? item.turn.rawModelID
            modelSessionIntervals[
                ModelSessionKey(agent: item.turn.agent, model: model, sessionKey: item.turn.sessionKey),
                default: []
            ].append(interval)
        }

        let additiveAgentTime = try sum(sessionIntervals.values.map { try mergedDuration($0) })
        let effectiveWallTime = try mergedDuration(sessionIntervals.values.flatMap { $0 })
        let runDuration = max(intervalEnd - intervalStart, 0)
        let humanIdleTime = max(runDuration - effectiveWallTime, 0)

        var modelGroups: [ModelKey: ModelAccumulator] = [:]
        for event in complete {
            guard let input = event.inputTokens,
                  let cacheWrite = event.cacheWriteTokens,
                  let cacheRead = event.cacheReadTokens,
                  let output = event.outputTokens,
                  let eventTotal = event.totalTokens
            else {
                continue
            }
            let key = ModelKey(agent: event.agent, model: event.canonicalModelID ?? event.rawModelID)
            modelGroups[key] = try adding(
                modelGroups[key] ?? .zero,
                input: input,
                cacheWrite: cacheWrite,
                cacheRead: cacheRead,
                output: output,
                reasoning: event.reasoningOutputTokens ?? 0,
                total: eventTotal,
                cost: event.estimatedAPICostNanodollars ?? 0,
                isPriced: event.estimatedAPICostNanodollars != nil
            )
        }

        var modelTimes: [ModelKey: Int64] = [:]
        for (key, intervals) in modelSessionIntervals {
            let modelKey = ModelKey(agent: key.agent, model: key.model)
            let duration = try mergedDuration(intervals)
            let current = modelTimes[modelKey] ?? 0
            let (newValue, overflow) = current.addingReportingOverflow(duration)
            guard !overflow else { throw UsageAggregationError.arithmeticOverflow }
            modelTimes[modelKey] = newValue
        }

        let modelKeys = Set(modelGroups.keys).union(modelTimes.keys)
        let models = modelKeys.map { key in
            let value = modelGroups[key] ?? .zero
            return EvaluationModelBreakdown(
                agent: key.agent,
                modelID: key.model,
                activeTimeMilliseconds: modelTimes[key] ?? 0,
                inputTokens: value.input,
                cacheWriteTokens: value.cacheWrite,
                cacheReadTokens: value.cacheRead,
                outputTokens: value.output,
                reasoningOutputTokens: value.reasoning,
                totalTokens: value.total,
                estimatedCostNanodollars: value.cost,
                completeEvents: value.completeEvents,
                pricedEvents: value.pricedEvents
            )
        }.sorted {
            if $0.estimatedCostNanodollars != $1.estimatedCostNanodollars {
                return $0.estimatedCostNanodollars > $1.estimatedCostNanodollars
            }
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.id < $1.id
        }

        let turnRows = clippedTurns.map {
            EvaluationTurnBreakdown(
                id: $0.turn.id,
                agent: $0.turn.agent,
                sessionKey: $0.turn.sessionKey,
                modelID: $0.turn.canonicalModelID ?? $0.turn.rawModelID,
                startedAtMilliseconds: $0.start,
                endedAtMilliseconds: $0.end,
                durationMilliseconds: $0.end - $0.start,
                timingQuality: $0.turn.timingQuality
            )
        }.sorted {
            if $0.startedAtMilliseconds != $1.startedAtMilliseconds {
                return $0.startedAtMilliseconds < $1.startedAtMilliseconds
            }
            return $0.id < $1.id
        }

        return UsageEvaluationReport(
            run: run,
            availableSessions: availableSessions,
            selectedSessionKeys: selectedSessionKeys,
            inputTokens: input,
            cacheWriteTokens: cacheWrite,
            cacheReadTokens: cacheRead,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total,
            estimatedCostNanodollars: cost,
            inputCacheHitRate: observedInput == 0 ? nil : Double(cacheRead) / Double(observedInput),
            outputShare: total == 0 ? nil : Double(output) / Double(total),
            models: models,
            turns: turnRows,
            timing: EvaluationTimingSummary(
                additiveAgentTimeMilliseconds: additiveAgentTime,
                effectiveWallTimeMilliseconds: effectiveWallTime,
                humanIdleTimeMilliseconds: humanIdleTime,
                exactTurns: clippedTurns.count { $0.turn.timingQuality == .exact },
                inferredTurns: clippedTurns.count { $0.turn.timingQuality == .inferred }
            ),
            coverage: UsageCoverage(
                totalEvents: selectedEvents.count,
                completeEvents: complete.count,
                pricedEvents: priced.count,
                partialEvents: selectedEvents.count - complete.count,
                unpricedCompleteEvents: complete.count - priced.count
            )
        )
    }

    func sessionSummaries(
        interval: DateInterval,
        events: [UsageEvent],
        turns: [UsageActiveTurn]
    ) -> [EvaluationSessionSummary] {
        let intervalStart = UsageEpoch.milliseconds(interval.start)
        let intervalEnd = UsageEpoch.milliseconds(interval.end)
        var accumulators: [String: SessionAccumulator] = [:]

        for event in events {
            guard let sessionKey = event.sessionKey,
                  event.occurredAtMilliseconds >= intervalStart,
                  event.occurredAtMilliseconds < intervalEnd
            else {
                continue
            }
            var value = accumulators[sessionKey] ?? SessionAccumulator(agent: event.agent)
            value.startedAt = min(value.startedAt, event.occurredAtMilliseconds)
            value.endedAt = max(value.endedAt, event.occurredAtMilliseconds)
            value.eventCount += 1
            value.models.insert(event.canonicalModelID ?? event.rawModelID)
            accumulators[sessionKey] = value
        }

        for turn in turns {
            guard turn.endedAtMilliseconds > intervalStart,
                  turn.startedAtMilliseconds < intervalEnd
            else {
                continue
            }
            var value = accumulators[turn.sessionKey] ?? SessionAccumulator(agent: turn.agent)
            value.startedAt = min(value.startedAt, max(turn.startedAtMilliseconds, intervalStart))
            value.endedAt = max(value.endedAt, min(turn.endedAtMilliseconds, intervalEnd))
            value.activeTurnCount += 1
            value.models.insert(turn.canonicalModelID ?? turn.rawModelID)
            accumulators[turn.sessionKey] = value
        }

        return accumulators.map { sessionKey, value in
            EvaluationSessionSummary(
                sessionKey: sessionKey,
                agent: value.agent,
                startedAtMilliseconds: value.startedAt == .max ? intervalStart : value.startedAt,
                endedAtMilliseconds: value.endedAt == .min ? intervalStart : value.endedAt,
                eventCount: value.eventCount,
                activeTurnCount: value.activeTurnCount,
                modelIDs: value.models.sorted()
            )
        }.sorted {
            if $0.startedAtMilliseconds != $1.startedAtMilliseconds {
                return $0.startedAtMilliseconds < $1.startedAtMilliseconds
            }
            return $0.id < $1.id
        }
    }

    private func sum(_ values: [Int64]) throws -> Int64 {
        guard let value = values.checkedSum() else { throw UsageAggregationError.arithmeticOverflow }
        return value
    }

    private func mergedDuration(_ intervals: [MillisecondInterval]) throws -> Int64 {
        let sorted = intervals.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        guard var current = sorted.first else { return 0 }
        var total: Int64 = 0
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)
            } else {
                let duration = max(current.end - current.start, 0)
                let (next, overflow) = total.addingReportingOverflow(duration)
                guard !overflow else { throw UsageAggregationError.arithmeticOverflow }
                total = next
                current = interval
            }
        }
        let duration = max(current.end - current.start, 0)
        let (result, overflow) = total.addingReportingOverflow(duration)
        guard !overflow else { throw UsageAggregationError.arithmeticOverflow }
        return result
    }

    private func adding(
        _ current: ModelAccumulator,
        input: Int64,
        cacheWrite: Int64,
        cacheRead: Int64,
        output: Int64,
        reasoning: Int64,
        total: Int64,
        cost: Int64,
        isPriced: Bool
    ) throws -> ModelAccumulator {
        let values = [
            current.input.addingReportingOverflow(input),
            current.cacheWrite.addingReportingOverflow(cacheWrite),
            current.cacheRead.addingReportingOverflow(cacheRead),
            current.output.addingReportingOverflow(output),
            current.reasoning.addingReportingOverflow(reasoning),
            current.total.addingReportingOverflow(total),
            current.cost.addingReportingOverflow(cost),
        ]
        guard values.allSatisfy({ !$0.overflow }) else {
            throw UsageAggregationError.arithmeticOverflow
        }
        return ModelAccumulator(
            input: values[0].partialValue,
            cacheWrite: values[1].partialValue,
            cacheRead: values[2].partialValue,
            output: values[3].partialValue,
            reasoning: values[4].partialValue,
            total: values[5].partialValue,
            cost: values[6].partialValue,
            completeEvents: current.completeEvents + 1,
            pricedEvents: current.pricedEvents + (isPriced ? 1 : 0)
        )
    }

    private struct ClippedTurn {
        let turn: UsageActiveTurn
        let start: Int64
        let end: Int64
    }

    private struct MillisecondInterval {
        let start: Int64
        var end: Int64
    }

    private struct ModelKey: Hashable {
        let agent: UsageAgent
        let model: String
    }

    private struct ModelSessionKey: Hashable {
        let agent: UsageAgent
        let model: String
        let sessionKey: String
    }

    private struct ModelAccumulator {
        static let zero = ModelAccumulator(
            input: 0, cacheWrite: 0, cacheRead: 0, output: 0, reasoning: 0,
            total: 0, cost: 0, completeEvents: 0, pricedEvents: 0
        )

        let input: Int64
        let cacheWrite: Int64
        let cacheRead: Int64
        let output: Int64
        let reasoning: Int64
        let total: Int64
        let cost: Int64
        let completeEvents: Int
        let pricedEvents: Int
    }

    private struct SessionAccumulator {
        let agent: UsageAgent
        var startedAt = Int64.max
        var endedAt = Int64.min
        var eventCount = 0
        var activeTurnCount = 0
        var models: Set<String> = []
    }
}

actor EvaluationRunsBackend {
    private let store: UsageAnalyticsStore
    private let usageBackend: UsageAnalyticsBackend
    private let aggregator = UsageEvaluationAggregator()

    init(store: UsageAnalyticsStore) {
        self.store = store
        usageBackend = UsageAnalyticsBackend(store: store)
    }

    func refreshUsage() async throws -> UsageImportReport {
        try await usageBackend.refresh()
    }

    func runs() async throws -> [EvaluationRun] {
        try await store.evaluationRuns()
    }

    func start(name: String, at date: Date = Date()) async throws -> EvaluationRun {
        let milliseconds = UsageEpoch.milliseconds(date)
        return try await store.createEvaluationRun(
            name: name,
            startedAtMilliseconds: milliseconds,
            endedAtMilliseconds: nil,
            createdAtMilliseconds: milliseconds
        )
    }

    func createPast(name: String, interval: DateInterval, now: Date = Date()) async throws -> EvaluationRun {
        _ = try await refreshUsage()
        let run = try await store.createEvaluationRun(
            name: name,
            startedAtMilliseconds: UsageEpoch.milliseconds(interval.start),
            endedAtMilliseconds: UsageEpoch.milliseconds(interval.end),
            createdAtMilliseconds: UsageEpoch.milliseconds(now)
        )
        let sessions = try await candidateSessions(for: run)
        try await store.replaceEvaluationSessionKeys(runID: run.id, sessionKeys: Set(sessions.map(\.sessionKey)))
        return run
    }

    func stop(id: String, at date: Date = Date()) async throws {
        try await store.finishEvaluationRun(id: id, endedAtMilliseconds: UsageEpoch.milliseconds(date))
        var refreshError: Error?
        do {
            _ = try await refreshUsage()
        } catch {
            refreshError = error
        }
        guard let run = try await store.evaluationRuns().first(where: { $0.id == id }) else { return }
        let selected = try await store.evaluationSessionKeys(runID: id)
        if selected.isEmpty {
            let sessions = try await candidateSessions(for: run)
            try await store.replaceEvaluationSessionKeys(runID: id, sessionKeys: Set(sessions.map(\.sessionKey)))
        }
        if let refreshError { throw refreshError }
    }

    func report(runID: String, endingAt date: Date = Date()) async throws -> UsageEvaluationReport? {
        guard let run = try await store.evaluationRuns().first(where: { $0.id == runID }),
              let interval = run.interval(endingAt: date)
        else {
            return nil
        }
        let allEvents = try await store.events(interval: interval)
        let allTurns = try await store.activeTurns(interval: interval)
        let sessions = aggregator.sessionSummaries(interval: interval, events: allEvents, turns: allTurns)
        let selected = try await store.evaluationSessionKeys(runID: runID)
        return try aggregator.report(
            run: run,
            availableSessions: sessions,
            selectedSessionKeys: selected,
            events: allEvents,
            turns: allTurns,
            endingAt: date
        )
    }

    func replaceSessionKeys(runID: String, sessionKeys: Set<String>) async throws {
        try await store.replaceEvaluationSessionKeys(runID: runID, sessionKeys: sessionKeys)
    }

    func delete(runID: String) async throws {
        try await store.deleteEvaluationRun(id: runID)
    }

    private func candidateSessions(for run: EvaluationRun) async throws -> [EvaluationSessionSummary] {
        guard let interval = run.interval() else { return [] }
        let events = try await store.events(interval: interval)
        let turns = try await store.activeTurns(interval: interval)
        return aggregator.sessionSummaries(interval: interval, events: events, turns: turns)
    }
}
