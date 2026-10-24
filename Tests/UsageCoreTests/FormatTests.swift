import Foundation
import Testing
@testable import UsageCore

@Suite("Formatting and model")
struct FormatTests {
    @Test func percentNeverRoundsUpTo100() {
        #expect(percentText(99.6) == "99")
        #expect(percentText(99.4) == "99")
        #expect(percentText(100) == "100")
        #expect(percentText(0) == "0")
        #expect(percentText(nil) == "—")
    }

    @Test func percentRejectsOutOfRangeInput() {
        #expect(percent(101) == nil)
        #expect(percent(-1) == nil)
        #expect(percent(Double.nan) == nil)
        #expect(percent(42.5) == 42.5)
    }

    @Test func currencyUsesTwoDecimals() {
        #expect(currencyText(0.4) == "$0.40")
        #expect(currencyText(12) == "$12.00")
    }

    @Test func otherHotIgnoresBarWindowAndPassedResets() {
        let now = Date()
        let snapshot = Snapshot(
            service: .claude,
            windows: [
                LimitWindow(label: "5-hour", short: "5h", used: 10, resetsAt: now.addingTimeInterval(3600)),
                LimitWindow(label: "Week", short: "w", used: 95, resetsAt: now.addingTimeInterval(3600)),
            ]
        )
        #expect(snapshot.otherHot)

        let passed = Snapshot(
            service: .claude,
            windows: [
                LimitWindow(label: "5-hour", short: "5h", used: 10, resetsAt: now.addingTimeInterval(3600)),
                LimitWindow(label: "Week", short: "w", used: 95, resetsAt: now.addingTimeInterval(-60)),
            ]
        )
        #expect(!passed.otherHot)
    }

    @Test func staleAfterFortyFiveMinutes() {
        let snapshot = Snapshot(service: .codex, measuredAt: Date().addingTimeInterval(-46 * 60))
        #expect(snapshot.isStale())
        let fresh = Snapshot(service: .codex, measuredAt: Date().addingTimeInterval(-44 * 60))
        #expect(!fresh.isStale())
    }
}
