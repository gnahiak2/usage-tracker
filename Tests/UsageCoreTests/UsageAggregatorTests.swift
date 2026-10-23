import Foundation
import XCTest
@testable import UsageCore

final class UsageAggregatorTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private var now: Date { date(day: 23, hour: 12) }

    private func date(day: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = day
        components.hour = hour
        components.timeZone = utc
        return calendar.date(from: components)!
    }

    private func event(
        provider: ProviderID = .codex,
        day: Int,
        hour: Int,
        input: Int64 = 100,
        output: Int64 = 50,
        model: String? = "gpt-5.4",
        reportedCost: Decimal? = nil,
        estimatedCost: Decimal? = nil
    ) -> UsageEvent {
        UsageEvent(
            provider: provider,
            dedupeKey: UUID().uuidString,
            timestamp: date(day: day, hour: hour),
            model: model,
            tokens: TokenBreakdown(inputTokens: input, outputTokens: output),
            reportedCostUSD: reportedCost,
            estimatedCostUSD: estimatedCost
        )
    }

    func testTodayExcludesOlderEvents() {
        let aggregator = UsageAggregator(calendar: calendar)
        let events = [
            event(day: 23, hour: 9),
            event(day: 23, hour: 11),
            event(day: 21, hour: 11)
        ]

        let today = aggregator.summarize(
            provider: .codex,
            events: events,
            period: .today,
            now: now
        )
        XCTAssertEqual(today.eventCount, 2)
        XCTAssertEqual(today.tokens.total, 300)

        let week = aggregator.summarize(
            provider: .codex,
            events: events,
            period: .last7Days,
            now: now
        )
        XCTAssertEqual(week.eventCount, 3)
        XCTAssertEqual(week.tokens.total, 450)
    }

    func testSummarizeFiltersByProvider() {
        let aggregator = UsageAggregator(calendar: calendar)
        let events = [
            event(provider: .codex, day: 23, hour: 9),
            event(provider: .commandCode, day: 23, hour: 10),
            event(provider: .claudeChat, day: 23, hour: 11)
        ]

        let summary = aggregator.summarize(
            provider: .commandCode,
            events: events,
            period: .today,
            now: now
        )
        XCTAssertEqual(summary.eventCount, 1)
        XCTAssertEqual(summary.tokens.total, 150)
    }

    func testReportedCostIsUnavailableWhenAnyEventIsMissingIt() {
        let aggregator = UsageAggregator(calendar: calendar)
        let complete = [
            event(day: 23, hour: 9, reportedCost: Decimal(string: "0.10")!),
            event(day: 23, hour: 10, reportedCost: Decimal(string: "0.20")!)
        ]

        let completeSummary = aggregator.summarize(
            provider: .codex,
            events: complete,
            period: .today,
            now: now
        )
        XCTAssertEqual(completeSummary.reportedCostUSD, .available(Decimal(string: "0.30")!))

        let partialSummary = aggregator.summarize(
            provider: .codex,
            events: complete + [event(day: 23, hour: 11)],
            period: .today,
            now: now
        )
        guard case .unavailable(let reason) = partialSummary.reportedCostUSD else {
            return XCTFail("Expected reported cost to be unavailable")
        }
        XCTAssertTrue(reason.contains("missing"))
    }

    func testEstimatedCostNamesModelsWithoutARate() {
        let aggregator = UsageAggregator(calendar: calendar)
        let events = [
            event(day: 23, hour: 9, model: "gpt-5.4", estimatedCost: Decimal(string: "0.25")!),
            event(day: 23, hour: 10, model: "mystery-model")
        ]

        let summary = aggregator.summarize(
            provider: .codex,
            events: events,
            period: .today,
            now: now
        )
        guard case .unavailable(let reason) = summary.estimatedCostUSD else {
            return XCTFail("Expected estimated cost to be unavailable")
        }
        XCTAssertTrue(reason.contains("mystery-model"))
    }

    func testModelBreakdownGroupsEvents() {
        let aggregator = UsageAggregator(calendar: calendar)
        let events = [
            event(day: 23, hour: 9, model: "gpt-5.4"),
            event(day: 23, hour: 10, model: "gpt-5.4"),
            event(day: 23, hour: 11, model: "gpt-5.3-codex")
        ]

        let summary = aggregator.summarize(
            provider: .codex,
            events: events,
            period: .today,
            now: now
        )
        XCTAssertEqual(summary.models.count, 2)
        let gpt54 = summary.models.first { $0.model == "gpt-5.4" }
        XCTAssertEqual(gpt54?.eventCount, 2)
        XCTAssertEqual(gpt54?.tokens.total, 300)
    }

    func testEventsWithMissingTokenCountsMarkIncomplete() {
        let aggregator = UsageAggregator(calendar: calendar)
        let event = UsageEvent(
            provider: .codex,
            dedupeKey: "missing-tokens",
            timestamp: date(day: 23, hour: 9),
            model: "gpt-5.4",
            tokens: TokenBreakdown()
        )

        let summary = aggregator.summarize(
            provider: .codex,
            events: [event],
            period: .today,
            now: now
        )
        XCTAssertTrue(summary.hasIncompleteTokenData)
        XCTAssertEqual(summary.tokens.total, 0)
    }
}
