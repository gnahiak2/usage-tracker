import Foundation
import XCTest
@testable import UsageCore

final class UsageCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func snapshot(
        status: ProviderStatus,
        now: Date,
        provider: ProviderID = .codex
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            status: status,
            observedAt: now,
            lastCheckedAt: now,
            source: "test",
            accountScope: nil,
            quotas: [],
            notes: status == .error
                ? [MetricNote(kind: .error, message: "boom")]
                : [],
            capabilities: .none
        )
    }

    private func makeEvent(_ key: String, at date: Date) -> UsageEvent {
        UsageEvent(
            provider: .codex,
            dedupeKey: key,
            timestamp: date,
            model: "gpt-5.4",
            tokens: TokenBreakdown(inputTokens: 10, outputTokens: 5)
        )
    }

    func testMergeDeduplicatesAndPersists() async throws {
        let cache = UsageCache(directory: directory)
        let now = Date()
        let event = makeEvent("k1", at: now)
        let result = ProviderRefreshResult(
            provider: .codex,
            snapshot: snapshot(status: .ok, now: now),
            newEvents: [event]
        )

        let first = try await cache.merge(result: result, now: now)
        XCTAssertEqual(first.events.count, 1)

        let duplicate = ProviderRefreshResult(
            provider: .codex,
            snapshot: snapshot(status: .ok, now: now),
            newEvents: [event, event]
        )
        let second = try await cache.merge(result: duplicate, now: now)
        XCTAssertEqual(second.events.count, 1)

        let reloaded = UsageCache(directory: directory)
        let stored = try await reloaded.load(provider: .codex)
        XCTAssertEqual(stored?.events.count, 1)
        XCTAssertEqual(stored?.lastSnapshot?.status, .ok)
    }

    func testErrorRefreshKeepsPreviousDataAndMarksItStale() async throws {
        let cache = UsageCache(directory: directory)
        let now = Date()
        let event = makeEvent("k1", at: now)
        let ok = ProviderRefreshResult(
            provider: .codex,
            snapshot: snapshot(status: .ok, now: now),
            newEvents: [event]
        )
        _ = try await cache.merge(result: ok, now: now)

        let failed = ProviderRefreshResult(
            provider: .codex,
            snapshot: snapshot(status: .error, now: now)
        )
        let merged = try await cache.merge(result: failed, now: now)

        XCTAssertEqual(merged.snapshot.status, .stale)
        XCTAssertEqual(merged.events.count, 1)
        XCTAssertTrue(merged.snapshot.notes.contains { $0.kind == .error })
    }

    func testOldEventsArePrunedByRetention() async throws {
        let cache = UsageCache(directory: directory, retention: 60)
        let now = Date()
        let old = makeEvent("old", at: now.addingTimeInterval(-120))
        let fresh = makeEvent("fresh", at: now)

        let result = ProviderRefreshResult(
            provider: .codex,
            snapshot: snapshot(status: .ok, now: now),
            newEvents: [old, fresh]
        )
        let merged = try await cache.merge(result: result, now: now)

        XCTAssertEqual(merged.events.map(\.dedupeKey), ["fresh"])
    }

    func testClearRemovesTheCacheFileAndEvents() async throws {
        let cache = UsageCache(directory: directory)
        let now = Date()
        let result = ProviderRefreshResult(
            provider: .codex,
            snapshot: snapshot(status: .ok, now: now),
            newEvents: [makeEvent("k1", at: now)]
        )
        _ = try await cache.merge(result: result, now: now)
        let fileURL = await cache.cacheFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        try await cache.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let stored = try await cache.load(provider: .codex)
        XCTAssertNil(stored)
    }

    func testCorruptCacheFileIsDiscarded() async throws {
        let cache = UsageCache(directory: directory)
        let fileURL = await cache.cacheFileURL
        try Data("not a cache".utf8).write(to: fileURL)

        let all = try await cache.loadAll()
        XCTAssertTrue(all.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
