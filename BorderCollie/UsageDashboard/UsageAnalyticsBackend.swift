import Foundation

enum UsageAggregationError: Error, Equatable {
    case invalidDateInterval
    case arithmeticOverflow
}

enum UsageDateIntervals {
    static func interval(
        range: UsageDateRange,
        endingAt date: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DateInterval {
        if range == .oneDay {
            return DateInterval(start: date.addingTimeInterval(-24 * 60 * 60), end: date)
        }

        let endDay = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: endDay),
              let end = calendar.date(byAdding: .day, value: 1, to: endDay)
        else { throw UsageAggregationError.invalidDateInterval }
        return DateInterval(start: start, end: end)
    }
}

struct UsageAggregator: Sendable {
    func aggregate(
        events: [UsageEvent],
        range: UsageDateRange,
        interval: DateInterval,
        agents: Set<UsageAgent>,
        calendar: Calendar = .current
    ) throws -> UsageAggregate {
        let filtered = events.filter {
            interval.containsHalfOpen($0.occurredAt) && agents.contains($0.agent)
        }
        let complete = filtered.filter { $0.completeness == .complete }
        let priced = complete.filter { $0.estimatedAPICostNanodollars != nil }

        let input = try sum(complete.compactMap(\.inputTokens))
        let cacheWrite = try sum(complete.compactMap(\.cacheWriteTokens))
        let cacheRead = try sum(complete.compactMap(\.cacheReadTokens))
        let output = try sum(complete.compactMap(\.outputTokens))
        let reasoning = try sum(complete.compactMap(\.reasoningOutputTokens))
        let total = try sum(complete.compactMap(\.totalTokens))
        let estimatedCost = try sum(priced.compactMap(\.estimatedAPICostNanodollars))
        let observedInput = try sum([input, cacheWrite, cacheRead])

        var dailyGroups: [DailyKey: GroupAccumulator] = [:]
        var chartGroups: [ChartKey: GroupAccumulator] = [:]
        var modelGroups: [ModelKey: GroupAccumulator] = [:]
        for event in complete {
            guard let input = event.inputTokens,
                  let cacheWrite = event.cacheWriteTokens,
                  let cacheRead = event.cacheReadTokens,
                  let output = event.outputTokens,
                  let eventTotal = event.totalTokens
            else { continue }
            let reasoning = event.reasoningOutputTokens ?? 0
            let cost = event.estimatedAPICostNanodollars ?? 0
            let isPriced = event.estimatedAPICostNanodollars != nil
            let day = calendar.startOfDay(for: event.occurredAt)
            let dailyKey = DailyKey(day: day, agent: event.agent)
            dailyGroups[dailyKey] = try adding(
                dailyGroups[dailyKey] ?? .zero,
                input: input,
                cacheWrite: cacheWrite,
                cacheRead: cacheRead,
                output: output,
                reasoning: reasoning,
                total: eventTotal,
                cost: cost,
                isPriced: isPriced
            )

            let chartKey = ChartKey(
                timestamp: try chartBucketStart(for: event.occurredAt, range: range, calendar: calendar),
                agent: event.agent
            )
            chartGroups[chartKey] = try adding(
                chartGroups[chartKey] ?? .zero,
                input: input,
                cacheWrite: cacheWrite,
                cacheRead: cacheRead,
                output: output,
                reasoning: reasoning,
                total: eventTotal,
                cost: cost,
                isPriced: isPriced
            )

            let modelKey = ModelKey(agent: event.agent, model: event.canonicalModelID ?? event.rawModelID)
            modelGroups[modelKey] = try adding(
                modelGroups[modelKey] ?? .zero,
                input: input,
                cacheWrite: cacheWrite,
                cacheRead: cacheRead,
                output: output,
                reasoning: reasoning,
                total: eventTotal,
                cost: cost,
                isPriced: isPriced
            )
        }

        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            for agent in agents {
                let key = DailyKey(day: day, agent: agent)
                if dailyGroups[key] == nil {
                    dailyGroups[key] = .zero
                }
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > day else {
                throw UsageAggregationError.invalidDateInterval
            }
            day = nextDay
        }

        var chartBucket = try chartBucketStart(for: interval.start, range: range, calendar: calendar)
        let chartComponent: Calendar.Component = range == .oneDay ? .hour : .day
        while chartBucket < interval.end {
            for agent in agents {
                let key = ChartKey(timestamp: chartBucket, agent: agent)
                if chartGroups[key] == nil {
                    chartGroups[key] = .zero
                }
            }
            guard let nextBucket = calendar.date(byAdding: chartComponent, value: 1, to: chartBucket),
                  nextBucket > chartBucket
            else { throw UsageAggregationError.invalidDateInterval }
            chartBucket = nextBucket
        }

        var chartPoints: [UsageChartPoint] = []
        for (key, value) in chartGroups {
            chartPoints.append(UsageChartPoint(
                timestamp: max(key.timestamp, interval.start),
                agent: key.agent,
                totalTokens: value.total,
                estimatedCostNanodollars: value.cost,
                completeEvents: value.completeEvents,
                pricedEvents: value.pricedEvents
            ))
        }
        chartPoints.sort {
            $0.timestamp == $1.timestamp
                ? $0.agent.rawValue < $1.agent.rawValue
                : $0.timestamp < $1.timestamp
        }

        var daily: [UsageDailyPoint] = []
        for (key, value) in dailyGroups {
            daily.append(UsageDailyPoint(
                day: key.day,
                agent: key.agent,
                inputTokens: value.input,
                cacheWriteTokens: value.cacheWrite,
                cacheReadTokens: value.cacheRead,
                outputTokens: value.output,
                reasoningOutputTokens: value.reasoning,
                totalTokens: value.total,
                estimatedCostNanodollars: value.cost,
                completeEvents: value.completeEvents,
                pricedEvents: value.pricedEvents
            ))
        }
        daily.sort {
            $0.day == $1.day ? $0.agent.rawValue < $1.agent.rawValue : $0.day < $1.day
        }

        var models: [UsageModelBreakdown] = []
        for (key, value) in modelGroups {
            models.append(UsageModelBreakdown(
                agent: key.agent,
                modelID: key.model,
                inputTokens: value.input,
                cacheWriteTokens: value.cacheWrite,
                cacheReadTokens: value.cacheRead,
                outputTokens: value.output,
                reasoningOutputTokens: value.reasoning,
                totalTokens: value.total,
                estimatedCostNanodollars: value.cost,
                completeEvents: value.completeEvents,
                pricedEvents: value.pricedEvents
            ))
        }
        models.sort {
            if $0.estimatedCostNanodollars != $1.estimatedCostNanodollars {
                return $0.estimatedCostNanodollars > $1.estimatedCostNanodollars
            }
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.id < $1.id
        }

        return UsageAggregate(
            range: range,
            interval: interval,
            agents: agents,
            inputTokens: input,
            cacheWriteTokens: cacheWrite,
            cacheReadTokens: cacheRead,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total,
            estimatedCostNanodollars: estimatedCost,
            inputCacheHitRate: observedInput == 0 ? nil : Double(cacheRead) / Double(observedInput),
            outputShare: total == 0 ? nil : Double(output) / Double(total),
            chartPoints: chartPoints,
            daily: daily,
            models: models,
            coverage: UsageCoverage(
                totalEvents: filtered.count,
                completeEvents: complete.count,
                pricedEvents: priced.count,
                partialEvents: filtered.count - complete.count,
                unpricedCompleteEvents: complete.count - priced.count
            )
        )
    }

    private func sum(_ values: [Int64]) throws -> Int64 {
        guard let value = values.checkedSum() else { throw UsageAggregationError.arithmeticOverflow }
        return value
    }

    private func adding(
        _ current: GroupAccumulator,
        input: Int64,
        cacheWrite: Int64,
        cacheRead: Int64,
        output: Int64,
        reasoning: Int64,
        total: Int64,
        cost: Int64,
        isPriced: Bool
    ) throws -> GroupAccumulator {
        let newInput = current.input.addingReportingOverflow(input)
        let newCacheWrite = current.cacheWrite.addingReportingOverflow(cacheWrite)
        let newCacheRead = current.cacheRead.addingReportingOverflow(cacheRead)
        let newOutput = current.output.addingReportingOverflow(output)
        let newReasoning = current.reasoning.addingReportingOverflow(reasoning)
        let newTotal = current.total.addingReportingOverflow(total)
        let (newCost, costOverflow) = current.cost.addingReportingOverflow(cost)
        guard !newInput.overflow,
              !newCacheWrite.overflow,
              !newCacheRead.overflow,
              !newOutput.overflow,
              !newReasoning.overflow,
              !newTotal.overflow,
              !costOverflow
        else { throw UsageAggregationError.arithmeticOverflow }
        return GroupAccumulator(
            input: newInput.partialValue,
            cacheWrite: newCacheWrite.partialValue,
            cacheRead: newCacheRead.partialValue,
            output: newOutput.partialValue,
            reasoning: newReasoning.partialValue,
            total: newTotal.partialValue,
            cost: newCost,
            completeEvents: current.completeEvents + 1,
            pricedEvents: current.pricedEvents + (isPriced ? 1 : 0)
        )
    }

    private func chartBucketStart(
        for date: Date,
        range: UsageDateRange,
        calendar: Calendar
    ) throws -> Date {
        if range == .oneDay {
            guard let interval = calendar.dateInterval(of: .hour, for: date) else {
                throw UsageAggregationError.invalidDateInterval
            }
            return interval.start
        }
        return calendar.startOfDay(for: date)
    }

    private struct GroupAccumulator {
        static let zero = GroupAccumulator(
            input: 0,
            cacheWrite: 0,
            cacheRead: 0,
            output: 0,
            reasoning: 0,
            total: 0,
            cost: 0,
            completeEvents: 0,
            pricedEvents: 0
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

    private struct DailyKey: Hashable {
        let day: Date
        let agent: UsageAgent
    }

    private struct ChartKey: Hashable {
        let timestamp: Date
        let agent: UsageAgent
    }

    private struct ModelKey: Hashable {
        let agent: UsageAgent
        let model: String
    }
}

actor UsageAnalyticsBackend {
    private let store: UsageAnalyticsStore
    private let importers: [any UsageSourceImporter]
    private let pricingEngine: UsagePricingEngine
    private let aggregator = UsageAggregator()
    private var isPrepared = false

    init(
        store: UsageAnalyticsStore,
        importers: [any UsageSourceImporter] = [
            ClaudeCodeUsageImporter(),
            CodexUsageImporter(),
            OpenCodeUsageImporter(),
            PiUsageImporter(),
        ],
        pricingEngine: UsagePricingEngine = UsagePricingEngine()
    ) {
        self.store = store
        self.importers = importers
        self.pricingEngine = pricingEngine
    }

    func refresh() async throws -> UsageImportReport {
        try await prepareIfNeeded()
        var reports: [UsageAgentImportReport] = []
        for importer in importers {
            try Task.checkCancellation()
            do {
                let checkpoints = try await store.checkpoints(for: importer.agent)
                let batch = try importer.importBatch(checkpoints: checkpoints)
                try Task.checkCancellation()
                try await store.apply(batch)
                reports.append(UsageAgentImportReport(
                    agent: importer.agent,
                    importedEvents: batch.events.count,
                    importedActiveTurns: batch.activeTurns.count,
                    issues: batch.issues
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reports.append(UsageAgentImportReport(
                    agent: importer.agent,
                    importedEvents: 0,
                    importedActiveTurns: 0,
                    issues: [UsageImportIssue(
                        agent: importer.agent,
                        sourceKey: nil,
                        severity: .error,
                        message: "Import failed before commit (\(String(describing: type(of: error))))"
                    )]
                ))
            }
        }

        let events = try await store.events()
        let prices = Dictionary(uniqueKeysWithValues: events.map { ($0.id, pricingEngine.price($0)) })
        try await store.updatePricing(prices)
        return UsageImportReport(agents: reports, finishedAtMilliseconds: UsageEpoch.milliseconds(Date()))
    }

    func aggregate(
        range: UsageDateRange,
        agents: Set<UsageAgent> = Set(UsageAgent.allCases),
        endingAt date: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> UsageAggregate {
        try await prepareIfNeeded()
        let interval = try UsageDateIntervals.interval(range: range, endingAt: date, calendar: calendar)
        let events = try await store.events(interval: interval, agents: agents)
        return try aggregator.aggregate(
            events: events,
            range: range,
            interval: interval,
            agents: agents,
            calendar: calendar
        )
    }

    private func prepareIfNeeded() async throws {
        guard !isPrepared else { return }
        try await store.replacePricingCatalog(rules: pricingEngine.rules, aliases: UsageModelCatalog.aliases)
        isPrepared = true
    }
}

private extension DateInterval {
    func containsHalfOpen(_ date: Date) -> Bool {
        date >= start && date < end
    }
}
