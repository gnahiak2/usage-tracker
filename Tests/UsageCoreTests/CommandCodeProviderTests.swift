import Foundation
import XCTest
@testable import UsageCore

final class CommandCodeProviderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to name: String) throws {
        let url = root.appendingPathComponent(name)
        let terminated = contents.hasSuffix("\n") ? contents : contents + "\n"
        try Data(terminated.utf8).write(to: url)
    }

    private var now: Date {
        ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")!
    }

    func testParsesAssistantUsageAndIgnoresOtherRoles() async throws {
        let contents = """
        {"type":"session","id":"session-a","version":3}
        {"type":"message","id":"m1","timestamp":"2026-10-23T10:00:00.000Z","model":"claude-sonnet-4-5","message":{"role":"assistant","meta":{"messageId":"msg-1"}},"usage":{"inputTokens":1000,"outputTokens":200,"cacheReadTokens":50,"cacheWriteTokens":10,"costUsd":0.0123}}
        {"type":"message","id":"m2","timestamp":"2026-10-23T10:01:00.000Z","message":{"role":"user"},"usage":{"inputTokens":999,"outputTokens":999}}
        {"type":"message","id":"m3","timestamp":"2026-10-23T10:02:00.000Z","message":{"role":"assistant"}}
        """
        try write(contents, to: "session-a.jsonl")

        let provider = CommandCodeProvider(root: root)
        let result = await provider.refresh(cache: nil, now: now)

        XCTAssertEqual(result.snapshot.status, .ok)
        XCTAssertEqual(result.newEvents.count, 1)
        let event = try XCTUnwrap(result.newEvents.first)
        XCTAssertEqual(event.provider, .commandCode)
        XCTAssertEqual(event.model, "claude-sonnet-4-5")
        XCTAssertEqual(event.tokens.inputTokens, 1000)
        XCTAssertEqual(event.tokens.outputTokens, 200)
        XCTAssertEqual(event.tokens.cacheReadTokens, 50)
        XCTAssertEqual(event.tokens.cacheWriteTokens, 10)
        XCTAssertEqual(event.reportedCostUSD, Decimal(string: "0.0123"))
        XCTAssertEqual(event.dedupeKey, "cc:msg-1")
    }

    func testForkedSessionsDoNotDoubleCount() async throws {
        let original = """
        {"type":"session","id":"session-a","version":3}
        {"type":"message","id":"m1","timestamp":"2026-10-23T10:00:00.000Z","model":"claude-sonnet-4-5","message":{"role":"assistant","meta":{"messageId":"msg-1"}},"usage":{"inputTokens":1000,"outputTokens":200,"costUsd":0.01}}
        """
        let fork = """
        {"type":"session","id":"session-b","version":3}
        {"type":"message","id":"m1","timestamp":"2026-10-23T10:00:00.000Z","model":"claude-sonnet-4-5","message":{"role":"assistant","meta":{"messageId":"msg-1"}},"usage":{"inputTokens":1000,"outputTokens":200,"costUsd":0.01}}
        """
        try write(original, to: "session-a.jsonl")
        try write(fork, to: "session-b.jsonl")

        let provider = CommandCodeProvider(root: root)
        let result = await provider.refresh(cache: nil, now: now)

        XCTAssertEqual(result.newEvents.count, 1)
        XCTAssertEqual(result.filesDiscovered, 2)
    }

    func testSecondRefreshResumesFromCheckpoint() async throws {
        let contents = """
        {"type":"session","id":"session-a","version":3}
        {"type":"message","id":"m1","timestamp":"2026-10-23T10:00:00.000Z","message":{"role":"assistant","meta":{"messageId":"msg-1"}},"usage":{"inputTokens":100,"outputTokens":20}}
        """
        try write(contents, to: "session-a.jsonl")

        let provider = CommandCodeProvider(root: root)
        let first = await provider.refresh(cache: nil, now: now)
        XCTAssertEqual(first.newEvents.count, 1)

        let cache = ProviderCache(
            provider: .commandCode,
            events: first.newEvents,
            checkpoints: first.checkpoints,
            lastSnapshot: first.snapshot
        )
        let second = await provider.refresh(cache: cache, now: now)
        XCTAssertTrue(second.newEvents.isEmpty)
    }

    func testMissingRootIsReportedAsNotConfigured() async {
        let provider = CommandCodeProvider(root: root.appendingPathComponent("missing"))
        let result = await provider.refresh(cache: nil, now: now)

        XCTAssertEqual(result.snapshot.status, .notConfigured)
        XCTAssertTrue(result.snapshot.notes.contains { $0.kind == .unavailable })
    }

    func testMalformedLinesAreIsolated() async throws {
        let contents = """
        {"type":"session","id":"session-a","version":3}
        this is not json
        {"type":"message","id":"m1","timestamp":"2026-10-23T10:00:00.000Z","message":{"role":"assistant","meta":{"messageId":"msg-1"}},"usage":{"inputTokens":100,"outputTokens":20}}
        """
        try write(contents, to: "session-a.jsonl")

        let provider = CommandCodeProvider(root: root)
        let result = await provider.refresh(cache: nil, now: now)

        XCTAssertEqual(result.newEvents.count, 1)
        XCTAssertEqual(result.malformedLines, 1)
        XCTAssertTrue(result.snapshot.notes.contains { $0.message.contains("malformed") })
    }
}
