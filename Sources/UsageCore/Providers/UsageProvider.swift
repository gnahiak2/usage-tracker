import Foundation

public enum RefreshCadence: String, Sendable {
    case local
    case remote
    case manual
}

public struct ProviderRefreshResult: Sendable {
    public let provider: ProviderID
    public let snapshot: UsageSnapshot
    public let newEvents: [UsageEvent]
    public let checkpoints: [String: FileCheckpoint]
    /// Honored by the coordinator when a source asks the app to slow down.
    public let retryAfter: TimeInterval?
    public let filesDiscovered: Int
    public let malformedLines: Int

    public init(
        provider: ProviderID,
        snapshot: UsageSnapshot,
        newEvents: [UsageEvent] = [],
        checkpoints: [String: FileCheckpoint] = [:],
        retryAfter: TimeInterval? = nil,
        filesDiscovered: Int = 0,
        malformedLines: Int = 0
    ) {
        self.provider = provider
        self.snapshot = snapshot
        self.newEvents = newEvents
        self.checkpoints = checkpoints
        self.retryAfter = retryAfter
        self.filesDiscovered = filesDiscovered
        self.malformedLines = malformedLines
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var refreshCadence: RefreshCadence { get }
    var capabilities: ProviderCapabilities { get }
    var sourceDescription: String { get }
    func refresh(cache: ProviderCache?, now: Date) async -> ProviderRefreshResult
}

public extension UsageProvider {
    func timedOutResult(now: Date, cache: ProviderCache?) -> ProviderRefreshResult {
        let previous = cache?.lastSnapshot
        let note = MetricNote(
            kind: .error,
            message: "Refresh timed out.",
            recovery: "Try again, or check that the local data folder is readable."
        )
        let snapshot = UsageSnapshot(
            provider: id,
            status: .error,
            observedAt: previous?.observedAt ?? now,
            lastCheckedAt: now,
            source: sourceDescription,
            accountScope: previous?.accountScope,
            quotas: previous?.quotas ?? [],
            notes: (previous?.notes ?? []) + [note],
            capabilities: capabilities
        )
        return ProviderRefreshResult(
            provider: id,
            snapshot: snapshot,
            checkpoints: cache?.checkpoints ?? [:]
        )
    }
}
