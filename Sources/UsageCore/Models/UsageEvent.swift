import Foundation

public struct UsageEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: String { dedupeKey }

    public let provider: ProviderID
    /// Stable identity used to prevent double counting copied fork/clone records.
    public let dedupeKey: String
    public let timestamp: Date
    public let model: String?
    public let tokens: TokenBreakdown
    /// Cost reported by the provider. Never derived.
    public let reportedCostUSD: Decimal?
    /// Explicitly labelled API-equivalent estimate. Never mixed with reported cost.
    public let estimatedCostUSD: Decimal?
    public let estimateNote: String?

    public init(
        provider: ProviderID,
        dedupeKey: String,
        timestamp: Date,
        model: String?,
        tokens: TokenBreakdown,
        reportedCostUSD: Decimal? = nil,
        estimatedCostUSD: Decimal? = nil,
        estimateNote: String? = nil
    ) {
        self.provider = provider
        self.dedupeKey = dedupeKey
        self.timestamp = timestamp
        self.model = model
        self.tokens = tokens
        self.reportedCostUSD = reportedCostUSD
        self.estimatedCostUSD = estimatedCostUSD
        self.estimateNote = estimateNote
    }
}

public struct ModelUsage: Sendable, Equatable, Identifiable {
    public var id: String { model }
    public let model: String
    public let tokens: TokenTotals
    public let eventCount: Int
    public let reportedCostUSD: MetricAvailability<Decimal>
    public let estimatedCostUSD: MetricAvailability<Decimal>
}

public struct ActivitySummary: Sendable, Equatable {
    public let provider: ProviderID
    public let period: ActivityPeriod
    public let start: Date
    public let end: Date
    public let tokens: TokenTotals
    public let hasIncompleteTokenData: Bool
    public let reportedCostUSD: MetricAvailability<Decimal>
    public let estimatedCostUSD: MetricAvailability<Decimal>
    public let models: [ModelUsage]
    public let eventCount: Int

    public init(
        provider: ProviderID,
        period: ActivityPeriod,
        start: Date,
        end: Date,
        tokens: TokenTotals,
        hasIncompleteTokenData: Bool,
        reportedCostUSD: MetricAvailability<Decimal>,
        estimatedCostUSD: MetricAvailability<Decimal>,
        models: [ModelUsage],
        eventCount: Int
    ) {
        self.provider = provider
        self.period = period
        self.start = start
        self.end = end
        self.tokens = tokens
        self.hasIncompleteTokenData = hasIncompleteTokenData
        self.reportedCostUSD = reportedCostUSD
        self.estimatedCostUSD = estimatedCostUSD
        self.models = models
        self.eventCount = eventCount
    }

    public var isEmpty: Bool { eventCount == 0 }
}

public enum ActivityPeriod: String, CaseIterable, Codable, Sendable, Identifiable {
    case today
    case last7Days
    case last30Days

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .today: return "Today"
        case .last7Days: return "7 days"
        case .last30Days: return "30 days"
        }
    }

    public func start(calendar: Calendar, now: Date) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return today
        case .last7Days:
            return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .last30Days:
            return calendar.date(byAdding: .day, value: -29, to: today) ?? today
        }
    }
}
