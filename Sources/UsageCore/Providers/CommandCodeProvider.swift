import Foundation

public struct CommandCodeProvider: UsageProvider {
    public let service: Service = .commandCode
    public init() {}

    public func read() -> Snapshot {
        let found = CLI.find("cmd")
        guard case .ok(let binary) = found else {
            if case .untrusted(let path) = found {
                return .status(.commandCode, .untrusted, "\(path) could be replaced by another account — not run")
            }
            return .status(.commandCode, .missing)
        }
        guard let output = CLIRunner.run(binary, ["status", "--json"], timeout: 20),
              let status = (try? JSONSerialization.jsonObject(with: output.data)) as? [String: Any]
        else {
            return .status(.commandCode, .failed, "cmd status gave no answer")
        }
        guard (status["authenticated"] as? Bool) == true else {
            return .status(.commandCode, .signedOut)
        }

        let plan = UserDefaults.standard.string(forKey: "commandCodePlan")
            .flatMap(CommandCodePlan.init(rawValue:))
        return Self.snapshot(events: Self.localEvents(), plan: plan,
                             model: status["model"] as? String, now: Date())
    }

    struct SpendEvent: Equatable, Sendable {
        var date: Date
        var cost: Double
        var tokens: Int
        var key: String
    }

    struct ActiveWindow {
        var start: Date
        var end: Date
        var cost: Double
        var tokens: Int
    }

    /// The rolling window opens on the first request and resets exactly one window-length later.
    static func activeWindow(_ events: [SpendEvent], length: TimeInterval, now: Date) -> ActiveWindow? {
        let sorted = events.sorted { $0.date < $1.date }
        guard let first = sorted.first else { return nil }
        var start = first.date
        var bucket: [SpendEvent] = [first]
        for event in sorted.dropFirst() {
            if event.date >= start.addingTimeInterval(length) {
                start = event.date
                bucket = [event]
            } else {
                bucket.append(event)
            }
        }
        let end = start.addingTimeInterval(length)
        guard now < end else { return nil }
        return ActiveWindow(start: start, end: end,
                            cost: bucket.reduce(0) { $0 + $1.cost },
                            tokens: bucket.reduce(0) { $0 + $1.tokens })
    }

    static func snapshot(events: [SpendEvent], plan: CommandCodePlan?, model: String?, now: Date) -> Snapshot {
        let five = activeWindow(events, length: 5 * 3600, now: now)
        let week = activeWindow(events, length: 7 * 86_400, now: now)

        func window(_ active: ActiveWindow?, label: String, short: String, cap: Double?) -> LimitWindow {
            let cost = active?.cost ?? 0
            let used = cap.flatMap { $0 > 0 ? (cost / $0) * 100 : nil }
            return LimitWindow(label: label, short: short, used: used,
                               resetsAt: active?.end,
                               detail: currencyText(cost),
                               estimated: true)
        }

        let windows = [
            window(five, label: "5-hour spend", short: "5h", cap: plan?.fiveHourCap),
            window(week, label: "Weekly spend", short: "w", cap: plan?.weeklyCap),
        ]

        var notes = ["Estimated from local session logs on this Mac"]
        if let plan {
            notes.append("Compared with \(plan.title) caps: \(currencyText(plan.fiveHourCap)) / \(currencyText(plan.weeklyCap))")
        } else {
            notes.append("Pick your plan in the menu to see a percentage")
        }
        if let model, !model.isEmpty {
            notes.append("Current model: \(model)")
        }
        if events.isEmpty {
            notes.append("No local usage in the last 7 days")
        } else if let five {
            notes.append("This 5-hour window: \(five.tokens.formatted()) tokens")
        }

        let planLabel = plan?.title ?? "Signed in"
        return Snapshot(service: .commandCode, plan: planLabel, windows: windows, notes: notes,
                        measuredAt: now,
                        actionTitle: "Open Studio usage",
                        actionURL: "https://commandcode.ai/usage",
                        menuText: plan == nil ? currencyText(five?.cost ?? 0) : nil)
    }

    /// Reads only numeric usage fields from local session logs. Prompt and response text is never decoded
    /// beyond finding the line, and never stored.
    static func localEvents(now: Date = Date()) -> [SpendEvent] {
        let root = "\(CLI.home)/.commandcode/projects"
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                                                             includingPropertiesForKeys: [.contentModificationDateKey],
                                                             options: [.skipsHiddenFiles])
        else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl", !url.lastPathComponent.contains("checkpoint") else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(modified) < 8 * 86_400 else { continue }
            files.append((url, modified))
        }
        files.sort { $0.modified > $1.modified }

        let usageMarker = Data("\"usage\"".utf8)
        let costMarker = Data("\"costUsd\"".utf8)
        var seen = Set<String>()
        var events: [SpendEvent] = []
        for file in files.prefix(200) {
            guard let data = try? Data(contentsOf: file.url) else { continue }
            for (index, line) in data.split(separator: 0x0A).enumerated() {
                guard line.count > 24,
                      line.range(of: usageMarker) != nil,
                      line.range(of: costMarker) != nil
                else { continue }
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let usage = object["usage"] as? [String: Any],
                      let date = epochDate(object["timestamp"])
                else { continue }

                let message = object["message"] as? [String: Any]
                let meta = message?["meta"] as? [String: Any]
                let key = (meta?["messageId"] as? String) ?? (object["id"] as? String)
                    ?? "\(file.url.path)#\(index)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)

                let cost = number(usage["costUsd"]) ?? 0
                let tokens = ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"]
                    .reduce(0) { total, field in total + (number(usage[field]).map(Int.init) ?? 0) }
                events.append(SpendEvent(date: date, cost: cost, tokens: tokens, key: key))
            }
        }
        return events.sorted { $0.date < $1.date }
    }
}
