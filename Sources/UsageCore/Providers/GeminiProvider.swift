import Foundation

public struct GeminiProvider: UsageProvider {
    public let service: Service = .gemini
    public init() {}

    public func read() -> Snapshot {
        let found = CLI.find("agy")
        guard case .ok(let binary) = found else {
            if case .untrusted(let path) = found {
                return .status(.gemini, .untrusted, "\(path) could be replaced by another account — not run")
            }
            return .status(.gemini, .missing)
        }
        guard let box = Sandbox.wrap(.gemini, binary,
                                     ["-p", "/quota", "--output-format", "json", "--print-timeout", "30s"])
        else {
            return .status(.gemini, .failed, "sandbox unavailable — agy not run")
        }
        guard let output = CLIRunner.run(argv: box.argv, binary: box.binary, timeout: 45,
                                         extraEnvironment: box.environment)
        else {
            return .status(.gemini, .failed, "agy timed out")
        }
        return Self.parseQuota(output.data)
    }

    static func parseQuota(_ data: Data) -> Snapshot {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let raw = String(decoding: data.prefix(2_000), as: UTF8.self)
            return .status(.gemini, signedOutText(raw) ? .signedOut : .failed,
                           signedOutText(raw) ? nil : "agy gave no quota")
        }

        if let error = object["error"] as? String {
            return errorSnapshot(error)
        }
        guard let command = object["command"] as? [String: Any],
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]]
        else {
            if let status = object["status"] as? String, status == "ERROR" {
                return .status(.gemini, .failed, "agy reported an error")
            }
            return .status(.gemini, .failed, "agy gave no quota")
        }

        var gemini: [LimitWindow] = []
        var other: [LimitWindow] = []
        var notes: [String] = []

        for group in groups {
            let groupName = group["name"] as? String ?? "Models"
            let isGemini = groupName.localizedCaseInsensitiveContains("Gemini")
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let remaining = number(bucket["remaining_fraction"]), remaining.isFinite,
                      remaining >= 0, remaining <= 1
                else { continue }
                let identifier = ((bucket["id"] as? String ?? "") + " " +
                                  (bucket["name"] as? String ?? "") + " " +
                                  (bucket["window"] as? String ?? "")).lowercased()
                let fiveHour = identifier.contains("5h") || identifier.contains("5-hour")
                if (bucket["disabled"] as? Bool) == true {
                    notes.append("\(groupName) \(fiveHour ? "5-hour" : "weekly") window disabled")
                    continue
                }
                let window = LimitWindow(label: "\(groupName) · \(fiveHour ? "5-hour" : "week")",
                                         short: fiveHour ? "5h" : "w",
                                         used: (1 - remaining) * 100,
                                         resetsAt: epochDate(bucket["reset_time"]))
                if isGemini { gemini.append(window) } else if remaining < 1 { other.append(window) }
            }
        }

        guard !gemini.isEmpty else {
            return Snapshot(service: .gemini, state: .failed, notes: notes,
                            measuredAt: Date(), error: "no Gemini quota in agy's answer")
        }
        gemini.sort { ($0.used ?? 0) > ($1.used ?? 0) }
        other.sort { ($0.used ?? 0) > ($1.used ?? 0) }
        return Snapshot(service: .gemini, windows: gemini + other, notes: notes, measuredAt: Date())
    }

    private static func errorSnapshot(_ raw: String) -> Snapshot {
        if raw.localizedCaseInsensitiveContains("eligibility") {
            return .status(.gemini, .failed, "Account not eligible for Antigravity")
        }
        if signedOutText(raw) {
            return .status(.gemini, .signedOut)
        }
        return .status(.gemini, .failed, "agy reported an error")
    }
}

func number(_ any: Any?) -> Double? {
    switch any {
    case let value as Double: return value
    case let value as Int: return Double(value)
    case let value as NSNumber: return value.doubleValue
    default: return nil
    }
}
