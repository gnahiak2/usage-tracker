import Foundation
import XCTest
@testable import UsageCore

private actor RefreshCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private struct StubProvider: UsageProvider {
    let id: ProviderID
    let refreshCadence: RefreshCadence
    let capabilities: ProviderCapabilities = .none
    let sourceDescription: String = "stub"
    let delayNanoseconds: UInt64
    let counter: RefreshCounter

    init(
        id: ProviderID = .codex,
        cadence: RefreshCadence = .local,
        delayNanoseconds: UInt64 = 0,
        counter: RefreshCounter
    ) {
        self.id = id
        self.refreshCadence = cadence
        self.delayNanoseconds = delayNanoseconds
        self.counter = counter
    }

    func refresh(cache: ProviderCache?, now: Date) async -> ProviderRefreshResult {
        await counter.increment()
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let snapshot = UsageSnapshot(
            provider: id,
            status: .ok,
            observedAt: now,
            lastCheckedAt: now,
            source: sourceDescription,
            accountScope: nil,
            capabilities: capabilities
        )
        return ProviderRefreshResult(provider: id, snapshot: snapshot)
    }
}

final class RefreshCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCoordinator(
        provider: any UsageProvider,
        configuration: RefreshConfiguration = RefreshConfiguration()
    ) -> RefreshCoordinator {
        RefreshCoordinator(
            providers: [provider],
            cache: UsageCache(directory: directory),
            configuration: configuration
        ) { _ in }
    }

    func testManualRefreshIsDebounced() async throws {
        let counter = RefreshCounter()
        let coordinator = makeCoordinator(
            provider: StubProvider(counter: counter),
            configuration: RefreshConfiguration(manualDebounce: 60)
        )

        let first = await coordinator.refresh(providerID: .codex, trigger: .manual)
        XCTAssertNotNil(first)

        let second = await coordinator.refresh(providerID: .codex, trigger: .manual)
        XCTAssertNil(second)

        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testScheduledRefreshWaitsForTheInterval() async throws {
        let counter = RefreshCounter()
        let coordinator = makeCoordinator(
            provider: StubProvider(counter: counter),
            configuration: RefreshConfiguration(localInterval: 300, remoteInterval: 300)
        )

        _ = await coordinator.refresh(providerID: .codex, trigger: .startup)
        let scheduled = await coordinator.refresh(providerID: .codex, trigger: .scheduled)

        XCTAssertNil(scheduled)
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testTimeoutProducesAnErrorSnapshot() async throws {
        let counter = RefreshCounter()
        let coordinator = makeCoordinator(
            provider: StubProvider(delayNanoseconds: 2_000_000_000, counter: counter),
            configuration: RefreshConfiguration(timeout: 0.1)
        )

        let outcome = await coordinator.refresh(providerID: .codex, trigger: .manual)

        XCTAssertEqual(outcome?.snapshot.status, .error)
        XCTAssertTrue(outcome?.snapshot.notes.contains { $0.kind == .error } ?? false)
    }

    func testFailedRefreshIncrementsBackoff() async throws {
        struct FailingProvider: UsageProvider {
            let id: ProviderID = .codex
            let refreshCadence: RefreshCadence = .local
            let capabilities: ProviderCapabilities = .none
            let sourceDescription: String = "failing"

            func refresh(cache: ProviderCache?, now: Date) async -> ProviderRefreshResult {
                let snapshot = UsageSnapshot(
                    provider: .codex,
                    status: .error,
                    observedAt: now,
                    lastCheckedAt: now,
                    source: sourceDescription,
                    accountScope: nil,
                    notes: [MetricNote(kind: .error, message: "boom")],
                    capabilities: capabilities
                )
                return ProviderRefreshResult(provider: .codex, snapshot: snapshot)
            }
        }

        let coordinator = makeCoordinator(
            provider: FailingProvider(),
            configuration: RefreshConfiguration(localInterval: 20, baseBackoff: 40)
        )

        _ = await coordinator.refresh(providerID: .codex, trigger: .manual)
        let wait = await coordinator.secondsUntilNextAttempt(providerID: .codex)
        let unwrapped = try XCTUnwrap(wait)

        XCTAssertGreaterThan(unwrapped, 20)
        XCTAssertLessThanOrEqual(unwrapped, 60)
    }

    func testCoordinatorEmitsStartedAndFinishedEvents() async throws {
        let counter = RefreshCounter()
        actor Recorder {
            var events: [String] = []
            func append(_ value: String) { events.append(value) }
            func snapshot() -> [String] { events }
        }
        let recorder = Recorder()
        let coordinator = RefreshCoordinator(
            providers: [StubProvider(counter: counter)],
            cache: UsageCache(directory: directory)
        ) { event in
            switch event {
            case .started(let provider):
                await recorder.append("started:\(provider.rawValue)")
            case .finished(let outcome):
                await recorder.append("finished:\(outcome.provider.rawValue)")
            }
        }

        _ = await coordinator.refresh(providerID: .codex, trigger: .manual)

        let events = await recorder.snapshot()
        XCTAssertEqual(events, ["started:codex", "finished:codex"])
    }
}
