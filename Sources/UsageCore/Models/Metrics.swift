import Foundation

public enum MetricAvailability<Value: Sendable & Equatable>: Sendable, Equatable {
    case available(Value)
    case unavailable(String)

    public var value: Value? {
        if case .available(let value) = self { return value }
        return nil
    }

    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

public struct TokenBreakdown: Codable, Sendable, Equatable {
    /// Input tokens as reported by the provider. Cached input is a subset of this value.
    public var inputTokens: Int64?
    /// Output tokens as reported by the provider. Reasoning tokens are a subset.
    public var outputTokens: Int64?
    public var cacheReadTokens: Int64?
    public var cacheWriteTokens: Int64?
    public var reasoningTokens: Int64?

    public init(
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        cacheReadTokens: Int64? = nil,
        cacheWriteTokens: Int64? = nil,
        reasoningTokens: Int64? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }

    public var totalTokens: Int64? {
        guard inputTokens != nil || outputTokens != nil else { return nil }
        return (inputTokens ?? 0) + (outputTokens ?? 0)
    }

    public var hasAnyTokenValue: Bool {
        inputTokens != nil || outputTokens != nil || cacheReadTokens != nil
            || cacheWriteTokens != nil || reasoningTokens != nil
    }
}

public struct TokenTotals: Codable, Sendable, Equatable {
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var reasoning: Int64
    public var total: Int64

    public init(
        input: Int64 = 0,
        output: Int64 = 0,
        cacheRead: Int64 = 0,
        cacheWrite: Int64 = 0,
        reasoning: Int64 = 0,
        total: Int64 = 0
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
        self.total = total
    }

    public static let zero = TokenTotals()

    public init(breakdown: TokenBreakdown) {
        input = breakdown.inputTokens ?? 0
        output = breakdown.outputTokens ?? 0
        cacheRead = breakdown.cacheReadTokens ?? 0
        cacheWrite = breakdown.cacheWriteTokens ?? 0
        reasoning = breakdown.reasoningTokens ?? 0
        total = breakdown.totalTokens ?? 0
    }

    public mutating func add(_ other: TokenTotals) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        reasoning += other.reasoning
        total += other.total
    }

    public mutating func add(_ breakdown: TokenBreakdown) {
        input += breakdown.inputTokens ?? 0
        output += breakdown.outputTokens ?? 0
        cacheRead += breakdown.cacheReadTokens ?? 0
        cacheWrite += breakdown.cacheWriteTokens ?? 0
        reasoning += breakdown.reasoningTokens ?? 0
        total += breakdown.totalTokens ?? 0
    }

    public func adding(_ other: TokenTotals) -> TokenTotals {
        var copy = self
        copy.add(other)
        return copy
    }

    public func isMonotonic(over previous: TokenTotals) -> Bool {
        input >= previous.input
            && output >= previous.output
            && cacheRead >= previous.cacheRead
            && cacheWrite >= previous.cacheWrite
            && reasoning >= previous.reasoning
            && total >= previous.total
    }

    public func subtracting(_ previous: TokenTotals) -> TokenTotals {
        TokenTotals(
            input: max(0, input - previous.input),
            output: max(0, output - previous.output),
            cacheRead: max(0, cacheRead - previous.cacheRead),
            cacheWrite: max(0, cacheWrite - previous.cacheWrite),
            reasoning: max(0, reasoning - previous.reasoning),
            total: max(0, total - previous.total)
        )
    }

    public var isEmpty: Bool {
        input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0
            && reasoning == 0 && total == 0
    }
}

public enum QuotaWindowKind: String, Codable, Sendable {
    case session
    case weekly
    case monthly
    case other
}

public struct QuotaWindow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: QuotaWindowKind
    public let label: String
    /// The provider-reported percentage consumed, 0...100. This is never derived from local tokens.
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    public let observedAt: Date
    public let scope: String
    public let source: String

    public init(
        id: String,
        kind: QuotaWindowKind,
        label: String,
        usedPercent: Double,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil,
        observedAt: Date,
        scope: String,
        source: String
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.scope = scope
        self.source = source
    }

    public var remainingPercent: Double {
        guard usedPercent.isFinite else { return 0 }
        return min(100, max(0, 100 - usedPercent))
    }

    public func isReset(now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

public enum MetricNoteKind: String, Codable, Sendable {
    case unavailable
    case unsupported
    case stale
    case error
    case info
}

public struct MetricNote: Codable, Sendable, Equatable {
    public let kind: MetricNoteKind
    public let message: String
    public let recovery: String?
    public let actionURL: URL?

    public init(
        kind: MetricNoteKind,
        message: String,
        recovery: String? = nil,
        actionURL: URL? = nil
    ) {
        self.kind = kind
        self.message = message
        self.recovery = recovery
        self.actionURL = actionURL
    }
}

public struct ProviderCapabilities: Codable, Sendable, Equatable {
    public let reportsQuota: Bool
    public let reportsResetTimes: Bool
    public let reportsLocalTokens: Bool
    public let reportsReportedCost: Bool
    public let reportsEstimatedCost: Bool
    public let supportsVerifiedSignIn: Bool
    public let accountUsageURL: URL?

    public init(
        reportsQuota: Bool,
        reportsResetTimes: Bool,
        reportsLocalTokens: Bool,
        reportsReportedCost: Bool,
        reportsEstimatedCost: Bool,
        supportsVerifiedSignIn: Bool,
        accountUsageURL: URL?
    ) {
        self.reportsQuota = reportsQuota
        self.reportsResetTimes = reportsResetTimes
        self.reportsLocalTokens = reportsLocalTokens
        self.reportsReportedCost = reportsReportedCost
        self.reportsEstimatedCost = reportsEstimatedCost
        self.supportsVerifiedSignIn = supportsVerifiedSignIn
        self.accountUsageURL = accountUsageURL
    }

    public static let none = ProviderCapabilities(
        reportsQuota: false,
        reportsResetTimes: false,
        reportsLocalTokens: false,
        reportsReportedCost: false,
        reportsEstimatedCost: false,
        supportsVerifiedSignIn: false,
        accountUsageURL: nil
    )
}

public enum ProviderStatus: String, Codable, Sendable {
    case loading
    case ok
    case empty
    case notConfigured
    case unsupported
    case stale
    case error
}

public struct UsageSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: ProviderID { provider }
    public let provider: ProviderID
    public var status: ProviderStatus
    /// When the underlying data was observed at the source.
    public var observedAt: Date
    /// When this app last attempted or completed a refresh.
    public var lastCheckedAt: Date
    public var source: String
    public var accountScope: String?
    public var quotas: [QuotaWindow]
    public var notes: [MetricNote]
    public var capabilities: ProviderCapabilities

    public init(
        provider: ProviderID,
        status: ProviderStatus,
        observedAt: Date,
        lastCheckedAt: Date,
        source: String,
        accountScope: String?,
        quotas: [QuotaWindow] = [],
        notes: [MetricNote] = [],
        capabilities: ProviderCapabilities
    ) {
        self.provider = provider
        self.status = status
        self.observedAt = observedAt
        self.lastCheckedAt = lastCheckedAt
        self.source = source
        self.accountScope = accountScope
        self.quotas = quotas
        self.notes = notes
        self.capabilities = capabilities
    }

    public var isStale: Bool { status == .stale }

    public func replacing(status: ProviderStatus, notes extraNotes: [MetricNote], checkedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            status: status,
            observedAt: observedAt,
            lastCheckedAt: checkedAt,
            source: source,
            accountScope: accountScope,
            quotas: quotas,
            notes: notes + extraNotes,
            capabilities: capabilities
        )
    }
}
