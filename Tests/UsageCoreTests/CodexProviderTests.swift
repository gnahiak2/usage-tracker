import Foundation
import XCTest
@testable import UsageCore

final class CodexProviderTests: XCTestCase {
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

    func testCumulativeTotalsBecomeDeltas() async throws {
        let contents = """
        {"timestamp":"2026-10-23T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"2026-10-23T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":1100}},"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1761300000},"plan_type":"plus"}}}
        {"timestamp":"2026-10-23T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":200,"output_tokens":150,"reasoning_output_tokens":0,"total_tokens":1650}}}}
        """
        try write(contents, to: "rollout-2026-10-23.jsonl")

        let provider = CodexProvider(root: root)
        let result = await provider.refresh(cache: nil, now: now)

        XCTAssertEqual(result.snapshot.status, .ok)
        XCTAssertEqual(result.newEvents.count, 2)

        let first = try XCTUnwrap(result.newEvents.first)
        XCTAssertEqual(first.model, "gpt-5.4")
        XCTAssertEqual(first.tokens.inputTokens, 1000)
        XCTAssertEqual(first.tokens.outputTokens, 100)
        XCTAssertEqual(first.tokens.cacheReadTokens, 200)
        XCTAssertEqual(
            first.estimatedCostUSD,
            Decimal(string: "0.00355"),
            "Cached input must use the discounted rate."
        )

        let second = try XCTUnwrap(result.newEvents.last)
        XCTAssertEqual(second.tokens.inputTokens, 500)
        XCTAssertEqual(second.tokens.outputTokens, 50)
        XCTAssertEqual(second.tokens.cacheReadTokens, 0)

        XCTAssertEqual(result.snapshot.quotas.count, 1)
        let quota = try XCTUnwrap(result.snapshot.quotas.first)
        XCTAssertEqual(quota.usedPercent, 12.5)
        XCTAssertEqual(quota.kind, .session)
        XCTAssertEqual(quota.label, "5-hour window")
        XCTAssertNotNil(quota.resetsAt)
    }

    func testRepeatedCumulativeTotalsProduceNoDuplicates() async throws {
        let line = """
        {"timestamp":"2026-10-23T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":100,"total_tokens":1100}}}}
        """
        try write("\(line)\n\(line)\n", to: "rollout-2026-10-23.jsonl")

        let provider = CodexProvider(root: root)
        let result = await provider.refresh(cache: nil, now: now)

        XCTAssertEqual(result.newEvents.count, 1)
    }

    func testNullRateLimitsAreNotShownAsZeroUsage() async throws {
        let contents = """
        {"timestamp":"2026-10-23T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}
        """
        try write(contents, to: "rollout-2026-10-23.jsonl")

        let provider = CodexProvider(root: root)
        let result = await provider.refresh(cache: nil, now: now)

        XCTAssertEqual(result.snapshot.status, .empty)
        XCTAssertTrue(result.snapshot.quotas.isEmpty)
        XCTAssertTrue(result.newEvents.isEmpty)
        XCTAssertTrue(result.snapshot.notes.contains { $0.message.contains("did not persist rate-limit") })
    }

    func testCumulativeResetIsCountedOnce() async throws {
        let contents = """
        {"timestamp":"2026-10-23T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":100,"total_tokens":1100}}}}
        {"timestamp":"2026-10-23T10:01:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"output_tokens":30,"total_tokens":330}}}}
        """
        try write(contents, to: "rollout-2026-10-23.jsonl")

        let provider = CodexProvider(root: root)
        let result = await provider.refresh(cache: nil, now: now)

        XCTAssertEqual(result.newEvents.count, 2)
        XCTAssertEqual(result.newEvents.last?.tokens.inputTokens, 300)
    }

    func testMissingRootIsReportedAsNotConfigured() async {
        let provider = CodexProvider(root: root.appendingPathComponent("missing"))
        let result = await provider.refresh(cache: nil, now: now)

        XCTAssertEqual(result.snapshot.status, .notConfigured)
        XCTAssertEqual(result.filesDiscovered, 0)
    }
}
