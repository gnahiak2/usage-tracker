import Foundation

/// Claude chat does not expose a verified public personal-usage interface that this app can read.
/// No browser cookies are harvested, no chat pages are scraped, and no OAuth flow is invented.
/// The row remains visibly unsupported and links to the account usage page instead.
public struct ClaudeChatProvider: UsageProvider {
    public let id: ProviderID = .claudeChat
    public let refreshCadence: RefreshCadence = .manual
    public let usagePageURL: URL

    public init(usagePageURL: URL = URL(string: "https://claude.ai/settings/usage")!) {
        self.usagePageURL = usagePageURL
    }

    public var sourceDescription: String {
        "No verified Claude chat usage interface"
    }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            reportsQuota: false,
            reportsResetTimes: false,
            reportsLocalTokens: false,
            reportsReportedCost: false,
            reportsEstimatedCost: false,
            supportsVerifiedSignIn: false,
            accountUsageURL: usagePageURL
        )
    }

    public func refresh(cache: ProviderCache?, now: Date) async -> ProviderRefreshResult {
        let notes = [
            MetricNote(
                kind: .unsupported,
                message: "Claude chat usage is unavailable through a verified interface.",
                recovery: "Open the Claude account usage page to check limits and reset times.",
                actionURL: usagePageURL
            ),
            MetricNote(
                kind: .info,
                message: "This app does not read browser cookies, scrape chats, or invent an OAuth flow."
            ),
            MetricNote(
                kind: .info,
                message: "The Claude row stays unavailable rather than showing a fabricated percentage."
            )
        ]
        let snapshot = UsageSnapshot(
            provider: id,
            status: .unsupported,
            observedAt: now,
            lastCheckedAt: now,
            source: sourceDescription,
            accountScope: "Claude account",
            quotas: [],
            notes: notes,
            capabilities: capabilities
        )
        return ProviderRefreshResult(provider: id, snapshot: snapshot)
    }
}
