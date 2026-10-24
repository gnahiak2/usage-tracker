import Foundation

public struct CodexProvider: UsageProvider {
    public let service: Service = .codex
    public init() {}

    public func read() -> Snapshot {
        let found = CLI.find("codex")
        guard case .ok(let binary) = found else {
            if case .untrusted(let path) = found {
                return .status(.codex, .untrusted, "\(path) could be replaced by another account — not run")
            }
            return .status(.codex, .missing)
        }

        if let fromLogs = Self.snapshotFromLogs() {
            return fromLogs
        }
        if let fromServer = serverSnapshot(binary) {
            return fromServer
        }
        if signedOut(binary) {
            return .status(.codex, .signedOut)
        }
        return .status(.codex, .failed, "codex gave no limits")
    }

    // MARK: - Session logs (free, written by Codex itself)

    static func snapshotFromLogs(now: Date = Date()) -> Snapshot? {
        let root = "\(CLI.home)/.codex/sessions"
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                                                             includingPropertiesForKeys: [.contentModificationDateKey],
                                                             options: [.skipsHiddenFiles])
        else { return nil }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(modified) < 7 * 86_400 else { continue }
            files.append((url, modified))
        }
        files.sort { $0.modified > $1.modified }

        for file in files.prefix(20) {
            guard let handle = FileHandle(forReadingAtPath: file.url.path) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
            let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            for line in tail.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let data = line.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] as? [String: Any]
                else { continue }
                let measured = epochDate(object["timestamp"]) ?? file.modified
                if let snapshot = parseRateLimits(limits, measuredAt: measured, usedKey: "used_percent", resetKey: "resets_at") {
                    return snapshot
                }
            }
        }
        return nil
    }

    static func parseRateLimits(_ limits: [String: Any], measuredAt: Date?,
                                usedKey: String, resetKey: String) -> Snapshot? {
        func window(_ key: String) -> LimitWindow? {
            guard let raw = limits[key] as? [String: Any],
                  let used = percent(raw[usedKey])
            else { return nil }
            let minutes = (raw["window_minutes"] ?? raw["windowDurationMins"]) as? Int ?? 0
            let fiveHour = minutes > 0 ? minutes <= 300 : key == "primary"
            return LimitWindow(label: fiveHour ? "5-hour" : "Week",
                               short: fiveHour ? "5h" : "w",
                               used: used,
                               resetsAt: epochDate(raw[resetKey]))
        }
        let five = window("primary")
        let week = window("secondary")
        guard five != nil || week != nil else { return nil }
        let planRaw = (limits["plan_type"] ?? limits["planType"]) as? String
        let plan = planRaw.map { "ChatGPT " + $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        return Snapshot(service: .codex, plan: plan,
                        windows: [five, week].compactMap { $0 },
                        measuredAt: measuredAt)
    }

    // MARK: - app-server fallback

    func serverSnapshot(_ binary: String) -> Snapshot? {
        guard let box = Sandbox.wrap(.codex, binary, ["app-server"]) else { return nil }
        let result = CLIRunner.rpc(
            argv: box.argv,
            binary: box.binary,
            initialize: ["clientInfo": ["name": "UsageTracker", "version": "1"]],
            notify: "initialized",
            method: "account/rateLimits/read",
            timeout: 15,
            extraEnvironment: box.environment
        )
        guard case .ok(let answer) = result else { return nil }
        guard let limits = answer["rateLimits"] as? [String: Any],
              var snapshot = Self.parseRateLimits(limits, measuredAt: Date(),
                                                  usedKey: "usedPercent", resetKey: "resetsAt")
        else { return nil }

        if let credits = ((answer["rateLimitResetCredits"] as? [String: Any])?["credits"] as? [[String: Any]]) {
            let available = credits.filter { ($0["status"] as? String) == "available" }
                .compactMap { epochDate($0["expiresAt"]) }.sorted()
            if let next = available.first {
                snapshot.notes.append("\(available.count) free full reset\(available.count == 1 ? "" : "s") · next expires \(resetText(next, kind: "on"))")
            }
        }
        return snapshot
    }

    func signedOut(_ binary: String) -> Bool {
        guard let box = Sandbox.wrap(.codex, binary, ["login", "status"]),
              let output = CLIRunner.run(argv: box.argv, binary: box.binary, timeout: 15,
                                         extraEnvironment: box.environment)
        else { return false }
        let text = String(decoding: output.data, as: UTF8.self)
        return signedOutText(text)
    }
}
