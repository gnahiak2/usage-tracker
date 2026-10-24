import Foundation

public struct GrokProvider: UsageProvider {
    public let service: Service = .grok
    public init() {}

    public func read() -> Snapshot {
        let found = CLI.find("grok")
        guard case .ok(let binary) = found else {
            if case .untrusted(let path) = found {
                return .status(.grok, .untrusted, "\(path) could be replaced by another account — not run")
            }
            return .status(.grok, .missing)
        }
        guard let box = Sandbox.wrap(.grok, binary, ["agent", "stdio"]) else {
            return .status(.grok, .failed, "sandbox unavailable — grok not run")
        }

        let result = CLIRunner.rpc(
            argv: box.argv,
            binary: box.binary,
            initialize: ["protocolVersion": 1, "clientCapabilities": [String: Any]()],
            method: "_x.ai/billing",
            timeout: 30,
            extraEnvironment: box.environment.merging([
                "GROK_SUBAGENTS": "0", "GROK_MEMORY": "0", "GROK_WEB_FETCH": "0",
            ]) { $1 }
        )

        switch result {
        case .failed(let message):
            return .status(.grok, signedOutText(message) ? .signedOut : .failed,
                           signedOutText(message) ? nil : "grok gave no billing answer")
        case .ok(let answer):
            return Self.parseBilling(answer)
        }
    }

    static func parseBilling(_ result: [String: Any]) -> Snapshot {
        guard let config = result["config"] as? [String: Any],
              let used = percent(config["creditUsagePercent"])
        else {
            return .status(.grok, .failed, "grok gave no billing")
        }
        let period = config["currentPeriod"] as? [String: Any]
        let periodType = (period?["type"] as? String) ?? ""
        let weekly = periodType.isEmpty || periodType.uppercased().contains("WEEKLY")
        let reset = epochDate(period?["end"] ?? config["billingPeriodEnd"])
        let window = LimitWindow(label: weekly ? "Weekly credits" : "Credits",
                                 short: weekly ? "w" : "",
                                 used: used, resetsAt: reset)
        var notes: [String] = []
        if weekly { notes.append("No 5-hour window") }
        return Snapshot(service: .grok,
                        plan: (result["subscription_tier"] as? String) ?? "",
                        windows: [window], notes: notes, measuredAt: Date())
    }
}
