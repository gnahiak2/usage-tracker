import Foundation

public enum RefreshTrigger: String, Sendable {
    case startup
    case scheduled
    case manual
    case wake
}

public struct RefreshConfiguration: Sendable {
    public var localInterval: TimeInterval
    public var remoteInterval: TimeInterval
    public var manualDebounce: TimeInterval
    public var baseBackoff: TimeInterval
    public var maxBackoff: TimeInterval
    public var timeout: TimeInterval
    public var tickInterval: TimeInterval

    public init(
        localInterval: TimeInterval = 20,
        remoteInterval: TimeInterval = 300,
        manualDebounce: TimeInterval = 1,
        baseBackoff: TimeInterval = 5,
        maxBackoff: TimeInterval = 300,
        timeout: TimeInterval = 30,
        tickInterval: TimeInterval = 1
    ) {
        self.localInterval = localInterval
        self.remoteInterval = remoteInterval
        self.manualDebounce = manualDebounce
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
        self.timeout = timeout
        self.tickInterval = tickInterval
    }
}

public struct RefreshOutcome: Sendable {
    public let provider: ProviderID
    public let snapshot: UsageSnapshot
    public let events: [UsageEvent]
    public let trigger: RefreshTrigger
    public let errorMessage: String?

    public init(
        provider: ProviderID,
        snapshot: UsageSnapshot,
        events: [UsageEvent],
        trigger: RefreshTrigger,
        errorMessage: String? = nil
    ) {
        self.provider = provider
        self.snapshot = snapshot
        self.events = events
        self.trigger = trigger
        self.errorMessage = errorMessage
    }
}

public enum RefreshCoordinatorEvent: Sendable {
    case started(ProviderID)
    case finished(RefreshOutcome)
}

public actor RefreshCoordinator {
    private let providers: [ProviderID: any UsageProvider]
    private let providerOrder: [ProviderID]
    private let cache: UsageCache
    private let configuration: RefreshConfiguration
    private let now: @Sendable () -> Date
    private let onEvent: @Sendable (RefreshCoordinatorEvent) async -> Void

    private var inFlight: [ProviderID: Task<RefreshOutcome?, Never>] = [:]
    private var lastAttempt: [ProviderID: Date] = [:]
    private var lastManual: [ProviderID: Date] = [:]
    private var failureCounts: [ProviderID: Int] = [:]
    private var retryAfter: [ProviderID: TimeInterval] = [:]
    private var loopTask: Task<Void, Never>?

    public init(
        providers: [any UsageProvider],
        cache: UsageCache,
        configuration: RefreshConfiguration = RefreshConfiguration(),
        now: @escaping @Sendable () -> Date = Date.init,
        onEvent: @escaping @Sendable (RefreshCoordinatorEvent) async -> Void
    ) {
        var map: [ProviderID: any UsageProvider] = [:]
        for provider in providers { map[provider.id] = provider }
        self.providers = map
        self.providerOrder = ProviderID.allCases.filter { map[$0] != nil }
        self.cache = cache
        self.configuration = configuration
        self.now = now
        self.onEvent = onEvent
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.runLoop()
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    public func refreshAll(trigger: RefreshTrigger) async {
        for id in providerOrder {
            _ = await refresh(providerID: id, trigger: trigger)
        }
    }

    @discardableResult
    public func refresh(providerID: ProviderID, trigger: RefreshTrigger) async -> RefreshOutcome? {
        guard let provider = providers[providerID] else { return nil }

        if let existing = inFlight[providerID] {
            return await existing.value
        }

        let nowValue = now()
        guard shouldRun(provider: provider, trigger: trigger, now: nowValue) else { return nil }

        lastAttempt[providerID] = nowValue
        if trigger == .manual { lastManual[providerID] = nowValue }

        let task = Task { [weak self] () -> RefreshOutcome? in
            guard let self else { return nil }
            return await self.perform(provider: provider, trigger: trigger, now: nowValue)
        }
        inFlight[providerID] = task
        let outcome = await task.value
        inFlight[providerID] = nil
        return outcome
    }

    public func secondsUntilNextAttempt(providerID: ProviderID) -> TimeInterval? {
        guard let provider = providers[providerID], provider.refreshCadence != .manual else { return nil }
        guard let attempt = lastAttempt[providerID] else { return 0 }
        let interval = provider.refreshCadence == .local
            ? configuration.localInterval
            : configuration.remoteInterval
        let next = attempt.addingTimeInterval(interval + currentBackoff(providerID))
        return max(0, next.timeIntervalSince(now()))
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let nowValue = now()
            let due = providerOrder.filter { id in
                guard let provider = providers[id] else { return false }
                return shouldRun(provider: provider, trigger: .scheduled, now: nowValue)
            }
            for id in due {
                if Task.isCancelled { return }
                _ = await refresh(providerID: id, trigger: .scheduled)
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(configuration.tickInterval * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    private func shouldRun(provider: any UsageProvider, trigger: RefreshTrigger, now: Date) -> Bool {
        if trigger == .manual {
            guard let previous = lastManual[provider.id] else { return true }
            return now.timeIntervalSince(previous) >= configuration.manualDebounce
        }

        if trigger == .wake {
            guard let previous = lastAttempt[provider.id] else { return true }
            return now.timeIntervalSince(previous) >= 2
        }

        if trigger == .startup {
            return true
        }

        guard provider.refreshCadence != .manual else { return false }
        guard let previous = lastAttempt[provider.id] else { return true }
        let interval = provider.refreshCadence == .local
            ? configuration.localInterval
            : configuration.remoteInterval
        return now.timeIntervalSince(previous) >= interval + currentBackoff(provider.id)
    }

    private func perform(
        provider: any UsageProvider,
        trigger: RefreshTrigger,
        now: Date
    ) async -> RefreshOutcome? {
        await onEvent(.started(provider.id))

        let previous: ProviderCache?
        do {
            previous = try await cache.load(provider: provider.id)
        } catch {
            previous = nil
        }

        let result = await refreshWithTimeout(provider: provider, cache: previous, now: now)

        let failed = result.snapshot.status == .error
        if failed {
            failureCounts[provider.id, default: 0] += 1
            retryAfter[provider.id] = result.retryAfter
        } else {
            failureCounts[provider.id] = 0
            retryAfter[provider.id] = nil
        }

        do {
            let merged = try await cache.merge(result: result, now: now)
            let outcome = RefreshOutcome(
                provider: provider.id,
                snapshot: merged.snapshot,
                events: merged.events,
                trigger: trigger,
                errorMessage: failed ? result.snapshot.notes.first(where: { $0.kind == .error })?.message : nil
            )
            await onEvent(.finished(outcome))
            return outcome
        } catch {
            let outcome = RefreshOutcome(
                provider: provider.id,
                snapshot: result.snapshot,
                events: previous?.events ?? [],
                trigger: trigger,
                errorMessage: error.localizedDescription
            )
            await onEvent(.finished(outcome))
            return outcome
        }
    }

    private func refreshWithTimeout(
        provider: any UsageProvider,
        cache: ProviderCache?,
        now: Date
    ) async -> ProviderRefreshResult {
        let timeout = configuration.timeout
        let result = await withTaskGroup(of: ProviderRefreshResult?.self) { group -> ProviderRefreshResult? in
            group.addTask {
                await provider.refresh(cache: cache, now: now)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return result ?? provider.timedOutResult(now: now, cache: cache)
    }

    private func currentBackoff(_ id: ProviderID) -> TimeInterval {
        if let retry = retryAfter[id], retry > 0 {
            return min(configuration.maxBackoff, retry)
        }
        let failures = failureCounts[id, default: 0]
        guard failures > 0 else { return 0 }
        let exponent = min(10, failures - 1)
        return min(configuration.maxBackoff, configuration.baseBackoff * pow(2, Double(exponent)))
    }
}
