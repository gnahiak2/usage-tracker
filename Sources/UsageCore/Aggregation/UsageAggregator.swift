import Foundation

public struct UsageAggregator: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func summarize(
        provider: ProviderID,
        events: [UsageEvent],
        period: ActivityPeriod,
        now: Date
    ) -> ActivitySummary {
        let start = period.start(calendar: calendar, now: now)
        let filtered = events
            .filter { $0.provider == provider && $0.timestamp >= start && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }

        var totals = TokenTotals.zero
        var incomplete = false
        for event in filtered {
            if event.tokens.totalTokens == nil { incomplete = true }
            totals.add(event.tokens)
        }

        let groups = Dictionary(grouping: filtered) { event in
            event.model ?? "Unknown model"
        }
        let models = groups.keys.sorted().map { key -> ModelUsage in
            let modelEvents = groups[key] ?? []
            var modelTotals = TokenTotals.zero
            for event in modelEvents { modelTotals.add(event.tokens) }
            return ModelUsage(
                model: key,
                tokens: modelTotals,
                eventCount: modelEvents.count,
                reportedCostUSD: reportedCost(modelEvents),
                estimatedCostUSD: estimatedCost(modelEvents)
            )
        }

        return ActivitySummary(
            provider: provider,
            period: period,
            start: start,
            end: now,
            tokens: totals,
            hasIncompleteTokenData: incomplete,
            reportedCostUSD: reportedCost(filtered),
            estimatedCostUSD: estimatedCost(filtered),
            models: models,
            eventCount: filtered.count
        )
    }

    private func reportedCost(_ events: [UsageEvent]) -> MetricAvailability<Decimal> {
        guard !events.isEmpty else { return .available(0) }
        var sum = Decimal(0)
        var missing = 0
        for event in events {
            if let cost = event.reportedCostUSD {
                sum += cost
            } else {
                missing += 1
            }
        }
        guard missing == 0 else {
            return .unavailable("Reported cost is missing for \(missing) session\(missing == 1 ? "" : "s").")
        }
        return .available(sum)
    }

    private func estimatedCost(_ events: [UsageEvent]) -> MetricAvailability<Decimal> {
        guard !events.isEmpty else { return .available(0) }
        var sum = Decimal(0)
        var missingModels: Set<String> = []
        for event in events {
            if let cost = event.estimatedCostUSD {
                sum += cost
            } else {
                missingModels.insert(event.model ?? "unknown model")
            }
        }
        guard missingModels.isEmpty else {
            let names = missingModels.sorted().joined(separator: ", ")
            return .unavailable("API-equivalent estimate unavailable for \(names).")
        }
        return .available(sum)
    }
}
