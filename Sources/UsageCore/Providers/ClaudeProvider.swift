import Foundation

public struct ClaudeProvider: UsageProvider {
    public let service: Service = .claude
    public init() {}

    static let isolation = [
        "-p", "/usage", "--output-format", "json", "--max-turns", "1",
        "--restricted", "--strict-mcp-config", "--no-session-persistence",
        "--settings", #"{"disableAllHooks":true,"language":"English"}"#,
    ]

    public func read() -> Snapshot {
        guard case .ok(let binary) = CLI.find("claude") else {
            if case .untrusted(let path) = CLI.find("claude") {
                return .status(.claude, .untrusted, "\(path) could be replaced by another account — not run")
            }
            return .status(.claude, .missing)
        }

        let account = account(binary)
        if account.signedIn == false {
            return .status(.claude, .signedOut)
        }
        let plan = account.plan

        if let cached = cachedStatus(plan: plan) {
            return cached
        }

        guard let output = CLIRunner.run(binary, Self.isolation, timeout: 45) else {
            return .status(.claude, .failed, "claude timed out")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: output.data)) as? [String: Any],
              let text = object["result"] as? String
        else {
            return .status(.claude, .failed, "claude gave no usage (exit \(output.code))")
        }

        if signedOutText(text) { return .status(.claude, .signedOut) }

        if var snapshot = Self.parseUsageText(text) {
            snapshot.plan = plan
            return snapshot
        }

        return Snapshot(
            service: .claude,
            state: .unavailable,
            plan: plan,
            notes: ["Add the optional Claude status line for live 5-hour and weekly limits (README)."],
            measuredAt: Date(),
            error: "No plan limits in `claude /usage` (API-key account?)"
        )
    }

    func account(_ binary: String) -> (signedIn: Bool?, plan: String) {
        guard let output = CLIRunner.run(binary, ["auth", "status", "--json"], timeout: 20),
              let object = (try? JSONSerialization.jsonObject(with: output.data)) as? [String: Any]
        else { return (nil, "") }
        let plan = (object["subscriptionType"] as? String).map {
            $0.prefix(1).uppercased() + $0.dropFirst()
        } ?? ""
        return (object["loggedIn"] as? Bool, plan)
    }

    func cachedStatus(plan: String) -> Snapshot? {
        guard let object = Paths.readJSON(Paths.claudeStatusFile),
              var snapshot = Self.parseStatusFile(object)
        else { return nil }
        snapshot.plan = plan
        return snapshot
    }

    // MARK: - Parsing

    /// Shape written by `--statusline`: only percentages and reset times.
    static func parseStatusFile(_ object: [String: Any]) -> Snapshot? {
        guard let limits = object["limits"] as? [String: Any] else { return nil }
        func window(_ key: String, label: String, short: String) -> LimitWindow? {
            guard let raw = limits[key] as? [String: Any] else { return nil }
            let value = percent(raw["percent"] ?? raw["used_percentage"])
            guard value != nil else { return nil }
            return LimitWindow(label: label, short: short, used: value,
                               resetsAt: epochDate(raw["resets_at"]))
        }
        let five = window("five_hour", label: "5-hour", short: "5h")
        let week = window("seven_day", label: "Week", short: "w")
        guard five != nil || week != nil else { return nil }
        var windows = [five, week].compactMap { $0 }
        windows.sort { ($0.short == "5h" ? 0 : 1) < ($1.short == "5h" ? 0 : 1) }
        return Snapshot(service: .claude, windows: windows,
                        measuredAt: epochDate(object["at"]) ?? Date())
    }

    /// Text from `claude -p /usage`. The format is stable prose, so it is matched, never echoed.
    static func parseUsageText(_ text: String) -> Snapshot? {
        func window(_ title: String, label: String, short: String) -> LimitWindow? {
            let titlePattern = NSRegularExpression.escapedPattern(for: title)
            let pattern = titlePattern + #":\s*(\d+(?:\.\d+)?)%\s*used(?:\s*·\s*resets\s+([^(\n]+?)\s*\(([^)]+)\))?"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let valueRange = Range(match.range(at: 1), in: text),
                  let used = Double(text[valueRange])
            else { return nil }
            var reset: Date?
            if let range = Range(match.range(at: 2), in: text),
               let zoneRange = Range(match.range(at: 3), in: text) {
                reset = parseReset(String(text[range]), zone: String(text[zoneRange]))
            }
            return LimitWindow(label: label, short: short, used: used, resetsAt: reset)
        }

        let five = window("Current session", label: "5-hour", short: "5h")
        let week = window("Current week (all models)", label: "Week", short: "w")
        var extra: [LimitWindow] = []
        if let regex = try? NSRegularExpression(pattern: #"Current week \(([^)]+)\)"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let model = String(text[range])
                guard model != "all models",
                      let item = window("Current week (\(model))", label: "\(model) week", short: "w")
                else { continue }
                extra.append(item)
            }
        }
        guard five != nil || week != nil else { return nil }
        var windows = [five, week].compactMap { $0 } + extra
        windows.sort { ($0.short == "5h" ? 0 : 1) < ($1.short == "5h" ? 0 : 1) }
        return Snapshot(service: .claude, windows: windows, measuredAt: Date())
    }

    static func parseReset(_ value: String, zone: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone) ?? .current
        let year = Calendar.current.component(.year, from: Date())
        let clean = value.replacingOccurrences(of: " at ", with: " ").uppercased()
        for format in ["MMM d h:mma yyyy", "MMM d ha yyyy", "MMM d H:mm yyyy"] {
            formatter.dateFormat = format
            for candidateYear in [year, year + 1] {
                if let date = formatter.date(from: "\(clean) \(candidateYear)"),
                   date > Date().addingTimeInterval(-86_400) {
                    return date
                }
            }
        }
        return nil
    }
}

func signedOutText(_ text: String) -> Bool {
    let lower = text.lowercased()
    let needles = ["not logged in", "not signed in", "please log in", "please sign in",
                   "login required", "unauthenticated", "unauthorized", "no credentials",
                   "not authenticated", "authentication required"]
    return needles.contains { lower.contains($0) }
}
