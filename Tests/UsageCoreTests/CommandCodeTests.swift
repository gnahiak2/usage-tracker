import Foundation
import Testing
@testable import UsageCore

@Suite("Command Code rolling windows")
struct CommandCodeTests {
    private func event(_ date: Date, _ cost: Double, tokens: Int = 100) -> CommandCodeProvider.SpendEvent {
        CommandCodeProvider.SpendEvent(date: date, cost: cost, tokens: tokens, key: UUID().uuidString)
    }

    @Test func sumsTheActiveFiveHourWindow() throws {
        let now = Date()
        let events = [event(now.addingTimeInterval(-2 * 3600), 1),
                      event(now.addingTimeInterval(-1 * 3600), 2)]
        let window = try #require(CommandCodeProvider.activeWindow(events, length: 5 * 3600, now: now))
        #expect(abs(window.cost - 3) < 0.0001)
        #expect(window.tokens == 200)
        #expect(abs(window.end.timeIntervalSince(now.addingTimeInterval(3 * 3600))) < 1)
    }

    @Test func expiredWindowIsNotActive() {
        let now = Date()
        let events = [event(now.addingTimeInterval(-6 * 3600), 5)]
        #expect(CommandCodeProvider.activeWindow(events, length: 5 * 3600, now: now) == nil)
        #expect(CommandCodeProvider.activeWindow(events, length: 7 * 86_400, now: now) != nil)
    }

    @Test func aLaterRequestOpensANewWindow() throws {
        let now = Date()
        let events = [event(now.addingTimeInterval(-7 * 3600), 9),
                      event(now.addingTimeInterval(-1 * 3600), 2)]
        let five = try #require(CommandCodeProvider.activeWindow(events, length: 5 * 3600, now: now))
        #expect(abs(five.cost - 2) < 0.0001)
        let week = try #require(CommandCodeProvider.activeWindow(events, length: 7 * 86_400, now: now))
        #expect(abs(week.cost - 11) < 0.0001)
    }

    @Test func planCapsBecomeAnEstimate() throws {
        let now = Date()
        let events = [event(now.addingTimeInterval(-1 * 3600), 3)]
        let snapshot = CommandCodeProvider.snapshot(events: events, plan: .pro, model: "gpt-6-astra", now: now)
        #expect(snapshot.state == .ok)
        #expect(snapshot.windows.count == 2)
        #expect(abs((snapshot.windows[0].used ?? 0) - (3.0 / 16.0 * 100)) < 0.001)
        #expect(abs((snapshot.windows[1].used ?? 0) - (3.0 / 40.0 * 100)) < 0.001)
        #expect(snapshot.windows[0].estimated)
        #expect(snapshot.menuText == nil)
        #expect(snapshot.actionURL == "https://commandcode.ai/usage")
    }

    @Test func withoutAPlanOnlyDollarsAreShown() {
        let now = Date()
        let events = [event(now.addingTimeInterval(-1 * 3600), 0.42)]
        let snapshot = CommandCodeProvider.snapshot(events: events, plan: nil, model: "gpt-6-astra", now: now)
        #expect(snapshot.windows[0].used == nil)
        #expect(snapshot.menuText == "$0.42")
        #expect(snapshot.windows[0].detail == "$0.42")
        #expect(snapshot.windows[0].estimated)
    }

    @Test func noEventsStillReportsZeroWithoutInventingAPercentage() {
        let snapshot = CommandCodeProvider.snapshot(events: [], plan: nil, model: nil, now: Date())
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows[0].used == nil)
        #expect(snapshot.menuText == "$0.00")
    }
}
