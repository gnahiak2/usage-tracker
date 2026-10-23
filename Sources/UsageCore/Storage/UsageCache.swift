import Foundation

public struct ProviderCache: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var provider: ProviderID
    public var events: [UsageEvent]
    public var checkpoints: [String: FileCheckpoint]
    public var lastSnapshot: UsageSnapshot?
    public var lastSuccessfulRefresh: Date?

    public init(
        provider: ProviderID,
        events: [UsageEvent] = [],
        checkpoints: [String: FileCheckpoint] = [:],
        lastSnapshot: UsageSnapshot? = nil,
        lastSuccessfulRefresh: Date? = nil,
        schemaVersion: Int = ProviderCache.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.events = events
        self.checkpoints = checkpoints
        self.lastSnapshot = lastSnapshot
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
    }

    public var dedupeKeys: Set<String> {
        Set(events.map(\.dedupeKey))
    }
}

public struct CachedRefresh: Sendable {
    public let cache: ProviderCache
    public let snapshot: UsageSnapshot
    public let events: [UsageEvent]
}

public enum UsageCacheError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case unreadableCache(String)
}

public actor UsageCache {
    public static let defaultRetention: TimeInterval = 90 * 24 * 60 * 60
    public static let defaultMaximumEventsPerProvider = 500_000

    private struct CacheFile: Codable {
        var schemaVersion: Int
        var providers: [String: ProviderCache]
    }

    private let directory: URL
    private let fileURL: URL
    private let retention: TimeInterval
    private let maximumEventsPerProvider: Int
    private var loaded: [ProviderID: ProviderCache]?

    public init(
        directory: URL,
        retention: TimeInterval = UsageCache.defaultRetention,
        maximumEventsPerProvider: Int = UsageCache.defaultMaximumEventsPerProvider
    ) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("usage-cache-v1.json")
        self.retention = retention
        self.maximumEventsPerProvider = maximumEventsPerProvider
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("UsageTracker", isDirectory: true)
    }

    public var cacheFileURL: URL { fileURL }

    public func loadAll() throws -> [ProviderID: ProviderCache] {
        if let loaded { return loaded }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loaded = [:]
            return [:]
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw UsageCacheError.unreadableCache(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(CacheFile.self, from: data) else {
            // A corrupt cache is disposable: report it and rebuild from source files.
            try? FileManager.default.removeItem(at: fileURL)
            loaded = [:]
            return [:]
        }
        guard file.schemaVersion == ProviderCache.currentSchemaVersion else {
            // Cache schemas are disposable. Rebuild from source rather than trusting stale offsets.
            try? FileManager.default.removeItem(at: fileURL)
            loaded = [:]
            return [:]
        }
        var result: [ProviderID: ProviderCache] = [:]
        for (key, value) in file.providers {
            guard let provider = ProviderID(rawValue: key) else { continue }
            guard value.schemaVersion == ProviderCache.currentSchemaVersion else { continue }
            result[provider] = value
        }
        loaded = result
        return result
    }

    public func load(provider: ProviderID) throws -> ProviderCache? {
        try loadAll()[provider]
    }

    public func merge(result: ProviderRefreshResult, now: Date) throws -> CachedRefresh {
        var all = try loadAll()
        var cache = all[result.provider] ?? ProviderCache(provider: result.provider)
        let failed = result.snapshot.status == .error

        if !failed {
            var known = cache.dedupeKeys
            for event in result.newEvents where !known.contains(event.dedupeKey) {
                known.insert(event.dedupeKey)
                cache.events.append(event)
            }
            cache.checkpoints = result.checkpoints
            cache.lastSnapshot = result.snapshot
            cache.lastSuccessfulRefresh = now
        } else {
            if let previous = cache.lastSnapshot {
                let hasPreviousData = !cache.events.isEmpty || !previous.quotas.isEmpty
                    || previous.status == .ok || previous.status == .empty
                if hasPreviousData {
                    let errorNotes = result.snapshot.notes.filter { $0.kind == .error }
                    let stale = UsageSnapshot(
                        provider: previous.provider,
                        status: .stale,
                        observedAt: previous.observedAt,
                        lastCheckedAt: now,
                        source: previous.source,
                        accountScope: previous.accountScope,
                        quotas: previous.quotas,
                        notes: previous.notes + errorNotes,
                        capabilities: previous.capabilities
                    )
                    cache.lastSnapshot = stale
                } else {
                    cache.lastSnapshot = result.snapshot
                }
            } else {
                cache.lastSnapshot = result.snapshot
            }
            // Keep the last good checkpoint so an unreadable source can be retried from where
            // it left off. The failing provider returns its existing checkpoints.
            if !result.checkpoints.isEmpty {
                cache.checkpoints = result.checkpoints
            }
        }

        prune(&cache, now: now)
        all[result.provider] = cache
        try persist(all)
        loaded = all

        guard let snapshot = cache.lastSnapshot else {
            throw UsageCacheError.unreadableCache("provider cache has no snapshot")
        }
        return CachedRefresh(cache: cache, snapshot: snapshot, events: cache.events)
    }

    public func store(snapshot: UsageSnapshot, events: [UsageEvent], checkpoints: [String: FileCheckpoint], now: Date) throws {
        var all = try loadAll()
        var cache = all[snapshot.provider] ?? ProviderCache(provider: snapshot.provider)
        cache.events = events
        cache.checkpoints = checkpoints
        cache.lastSnapshot = snapshot
        cache.lastSuccessfulRefresh = snapshot.status == .error ? cache.lastSuccessfulRefresh : now
        prune(&cache, now: now)
        all[snapshot.provider] = cache
        try persist(all)
        loaded = all
    }

    public func clear() throws {
        loaded = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func prune(_ cache: inout ProviderCache, now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        if cache.events.count > maximumEventsPerProvider {
            cache.events.sort { $0.timestamp < $1.timestamp }
            cache.events.removeFirst(cache.events.count - maximumEventsPerProvider)
        }
        cache.events.removeAll { $0.timestamp < cutoff }
    }

    private func persist(_ all: [ProviderID: ProviderCache]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var providers: [String: ProviderCache] = [:]
        for (provider, cache) in all {
            providers[provider.rawValue] = cache
        }
        let file = CacheFile(schemaVersion: ProviderCache.currentSchemaVersion, providers: providers)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(values)
        #endif
    }
}
