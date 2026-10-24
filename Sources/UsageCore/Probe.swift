import Foundation

public enum Probe {
    public static func run() {
        let providers: [any UsageProvider] = [
            ClaudeProvider(), CodexProvider(), GeminiProvider(), GrokProvider(), CommandCodeProvider(),
        ]
        let snapshots = providers.map { $0.read() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshots),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}

public enum Statusline {
    /// Reads Claude Code's status line JSON on stdin, keeps only the plan percentages and reset times,
    /// and prints a short line. This makes live Claude limits available without touching credentials.
    public static func run() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rate = object["rate_limits"] as? [String: Any]
        else {
            print("Claude · no plan limits")
            return
        }

        var limits: [String: Any] = [:]
        for key in ["five_hour", "seven_day"] {
            guard let window = rate[key] as? [String: Any],
                  let used = percent(window["used_percentage"])
            else { continue }
            var entry: [String: Any] = ["percent": used]
            if let reset = window["resets_at"] { entry["resets_at"] = reset }
            limits[key] = entry
        }

        guard !limits.isEmpty else {
            print("Claude · no plan limits")
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: Any] = ["at": formatter.string(from: Date()), "limits": limits]
        if let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            Paths.write(encoded, to: Paths.claudeStatusFile)
        }

        func value(_ key: String) -> String? {
            guard let entry = limits[key] as? [String: Any],
                  let used = entry["percent"] as? Double
            else { return nil }
            return percentText(used)
        }
        var parts: [String] = []
        if let five = value("five_hour") { parts.append("5h \(five)%") }
        if let week = value("seven_day") { parts.append("7d \(week)%") }
        print((["Claude"] + parts).joined(separator: " · "))
    }
}
