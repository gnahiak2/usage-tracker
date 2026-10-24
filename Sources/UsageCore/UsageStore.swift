import Foundation
import Observation

@MainActor
@Observable
public final class UsageStore {
    public private(set) var snapshots: [ProviderID: UsageSnapshot] = [:]
    public private(set) var events: [ProviderID: [UsageEvent]] = [:]
    public private(set) var refreshing: Set<ProviderID> = []
    public private(set) var lastRefresh: Date?
    public private(set) var cacheLocation: URL?

    @ObservationIgnored private var providers: [ProviderID: any UsageProvider] = [:]
    @ObservationIgnored private var cache: UsageCache?
    @ObservationIgnored private var coordinator: RefreshCoordinator?
    @ObservationIgnored private var aggregator: UsageAggregator
    @ObservationIgnored private var refreshInterval: TimeInterval = 20

    public init(calendar: Calendar = .current) {
        self.aggregator = UsageAggregator(calendar: calendar)
    }

    public var providerOrder: [ProviderID] { ProviderID.allCases }

    public func configure(
        providers: [any UsageProvider],
        cacheDirectory: URL,
        refreshInterval: TimeInterval = 20,
        calendar: Calendar = .current
    ) async {
        await coordinator?.stop()
        self.aggregator = UsageAggregator(calendar: calendar)
        self.refreshInterval = refreshInterval
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })

        let cache = UsageCache(directory: cacheDirectory)
        self.cache = cache
        self.cacheLocation = await cache.cacheFileURL

        if let all = try? await cache.loadAll() {
            for (id, cached) in all {
                if let snapshot = cached.lastSnapshot { snapshots[id] = snapshot }
                events[id] = cached.events
            }
        }

        let now = Date()
        for provider in providers where snapshots[provider.id] == nil {
            snapshots[provider.id] = UsageSnapshot(
                provider: provider.id,
                status: .loading,
                observedAt: now,
                lastCheckedAt: now,
                source: provider.sourceDescription,
                accountScope: nil,
                quotas: [],
                notes: [],
                capabilities: provider.capabilities
            )
        }

        let coordinator = RefreshCoordinator(
            providers: providers,
            cache: cache,
            configuration: RefreshConfiguration(localInterval: refreshInterval),
            now: Date.init
        ) { [weak self] event in
            await self?.handle(event)
        }
        self.coordinator = coordinator
        await coordinator.start()
        await coordinator.refreshAll(trigger: .startup)
    }

    public func stop() async {
        await coordinator?.stop()
    }

    public func refreshAll(trigger: RefreshTrigger = .manual) async {
        await coordinator?.refreshAll(trigger: trigger)
        lastRefresh = Date()
    }

    public func refresh(provider: ProviderID, trigger: RefreshTrigger = .manual) async {
        await coordinator?.refresh(providerID: provider, trigger: trigger)
        lastRefresh = Date()
    }

    public func wake() async {
        await refreshAll(trigger: .wake)
    }

    public func clearCache() async {
        guard let cache else { return }
        try? await cache.clear()
        events = [:]
        let now = Date()
        for (id, provider) in providers {
            snapshots[id] = UsageSnapshot(
                provider: id,
                status: .loading,
                observedAt: now,
                lastCheckedAt: now,
                source: provider.sourceDescription,
                accountScope: nil,
                quotas: [],
                notes: [],
                capabilities: provider.capabilities
            )
        }
        await coordinator?.refreshAll(trigger: .manual)
    }

    public func snapshot(for provider: ProviderID) -> UsageSnapshot? {
        snapshots[provider]
    }

    public func summary(
        for provider: ProviderID,
        period: ActivityPeriod,
        now: Date = Date()
    ) -> ActivitySummary {
        aggregator.summarize(
            provider: provider,
            events: events[provider] ?? [],
            period: period,
            now: now
        )
    }

    public func eventCount(for provider: ProviderID) -> Int {
        events[provider]?.count ?? 0
    }

    private func handle(_ event: RefreshCoordinatorEvent) async {
        switch event {
        case .started(let provider):
            refreshing.insert(provider)
        case .finished(let outcome):
            refreshing.remove(outcome.provider)
            snapshots[outcome.provider] = outcome.snapshot
            events[outcome.provider] = outcome.events
            lastRefresh = Date()
        }
    }
}
