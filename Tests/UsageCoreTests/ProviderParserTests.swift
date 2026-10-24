import Foundation
import Testing
@testable import UsageCore

@Suite("Claude parser")
struct ClaudeParserTests {
    @Test func parsesStatuslineFile() {
        let object: [String: Any] = [
            "at": "2026-10-24T01:00:00.000Z",
            "limits": [
                "five_hour": ["percent": 23.5, "resets_at": 1_792_800_000],
                "seven_day": ["percent": 41.2, "resets_at": 1_793_300_000],
            ],
        ]
        let snapshot = ClaudeProvider.parseStatusFile(object)
        #expect(snapshot?.service == .claude)
        #expect(snapshot?.windows.count == 2)
        #expect(snapshot?.windows.first?.short == "5h")
        #expect(abs((snapshot?.windows.first?.used ?? 0) - 23.5) < 0.001)
        #expect(snapshot?.windows.last?.short == "w")
    }

    @Test func rejectsStatusFileWithoutLimits() {
        #expect(ClaudeProvider.parseStatusFile(["at": "2026-10-24T01:00:00Z"]) == nil)
    }

    @Test func parsesUsageProse() {
        let text = """
        Current session: 23% used · resets Oct 25 at 9:10pm (America/Los_Angeles)
        Current week (all models): 41% used · resets Oct 27 at 11pm (America/Los_Angeles)
        """
        let snapshot = ClaudeProvider.parseUsageText(text)
        #expect(snapshot?.windows.count == 2)
        #expect(snapshot?.windows[0].used == 23)
        #expect(snapshot?.windows[1].used == 41)
        #expect(snapshot?.windows[0].resetsAt != nil)
    }

    @Test func ignoresSessionOnlyOutput() {
        let text = "Total cost: $0.0000\nUsage: 0 input, 0 output, 0 cache read, 0 cache write"
        #expect(ClaudeProvider.parseUsageText(text) == nil)
    }
}

@Suite("Codex parser")
struct CodexParserTests {
    @Test func parsesSnakeCaseLogLimits() {
        let limits: [String: Any] = [
            "primary": ["used_percent": 2.0, "window_minutes": 300, "resets_at": 1_792_756_851],
            "secondary": ["used_percent": 1.0, "window_minutes": 10_080, "resets_at": 1_793_325_150],
            "plan_type": "plus",
        ]
        let snapshot = CodexProvider.parseRateLimits(limits, measuredAt: nil,
                                                     usedKey: "used_percent", resetKey: "resets_at")
        #expect(snapshot?.plan == "ChatGPT Plus")
        #expect(snapshot?.windows.count == 2)
        #expect(snapshot?.windows[0].label == "5-hour")
        #expect(snapshot?.windows[1].label == "Week")
        #expect(snapshot?.windows[0].used == 2)
    }

    @Test func parsesCamelCaseServerLimits() {
        let limits: [String: Any] = [
            "primary": ["usedPercent": 32, "windowDurationMins": 300, "resetsAt": 1_792_756_851],
            "secondary": ["usedPercent": 44, "windowDurationMins": 10_080, "resetsAt": 1_793_325_150],
            "planType": "pro",
        ]
        let snapshot = CodexProvider.parseRateLimits(limits, measuredAt: Date(),
                                                     usedKey: "usedPercent", resetKey: "resetsAt")
        #expect(snapshot?.plan == "ChatGPT Pro")
        #expect(snapshot?.windows[0].short == "5h")
        #expect(snapshot?.windows[1].short == "w")
    }

    @Test func rejectsLimitsWithoutPercentages() {
        #expect(CodexProvider.parseRateLimits([:], measuredAt: nil,
                                              usedKey: "used_percent", resetKey: "resets_at") == nil)
    }
}

@Suite("Gemini parser")
struct GeminiParserTests {
    @Test func parsesGroupsAndBuckets() throws {
        let json = """
        {"command":{"data":{"groups":[
          {"name":"Gemini","buckets":[
            {"id":"gemini-weekly","window":"weekly","remaining_fraction":0.22,"reset_time":"2026-10-25T12:00:00Z"},
            {"id":"gemini-5h","window":"5h","remaining_fraction":1.0,"reset_time":"2026-10-24T06:00:00Z"}
          ]},
          {"name":"3p","buckets":[
            {"id":"3p-5h","window":"5h","remaining_fraction":0.5,"reset_time":"2026-10-24T07:00:00Z"}
          ]}
        ]}}}
        """
        let snapshot = GeminiProvider.parseQuota(Data(json.utf8))
        #expect(snapshot.state == .ok)
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.windows.first?.label == "Gemini · week")
        #expect(abs((snapshot.windows.first?.used ?? 0) - 78) < 0.001)
        #expect(snapshot.windows.first?.short == "w")
    }

    @Test func reportsIneligibleAccount() {
        let json = """
        {"status":"ERROR","error":"Eligibility check failed: Your current account is not eligible for Antigravity."}
        """
        let snapshot = GeminiProvider.parseQuota(Data(json.utf8))
        #expect(snapshot.state == .failed)
        #expect(snapshot.error == "Account not eligible for Antigravity")
        #expect(!(snapshot.error ?? "").contains("accounts.google.com"))
    }

    @Test func rejectsAnswerWithoutGeminiGroup() {
        let json = #"{"command":{"data":{"groups":[{"name":"3p","buckets":[]}]}}}"#
        let snapshot = GeminiProvider.parseQuota(Data(json.utf8))
        #expect(snapshot.state == .failed)
    }
}

@Suite("Grok parser")
struct GrokParserTests {
    @Test func parsesWeeklyCredits() {
        let result: [String: Any] = [
            "config": [
                "creditUsagePercent": 1.0,
                "currentPeriod": ["type": "WEEKLY", "end": "2026-10-27T16:31:00Z"],
            ],
            "subscription_tier": "X Premium+",
        ]
        let snapshot = GrokProvider.parseBilling(result)
        #expect(snapshot.state == .ok)
        #expect(snapshot.plan == "X Premium+")
        #expect(snapshot.windows.first?.short == "w")
        #expect(snapshot.windows.first?.used == 1)
        #expect(snapshot.notes.contains("No 5-hour window"))
    }

    @Test func rejectsBillingWithoutConfig() {
        #expect(GrokProvider.parseBilling([:]).state == .failed)
    }
}
