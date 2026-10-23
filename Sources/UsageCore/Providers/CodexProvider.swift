import Foundation

/// Reads Codex CLI rollout files under `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// Verified from the official Codex protocol:
/// - `event_msg` / `payload.type == "token_count"`
/// - `payload.info.total_token_usage` is cumulative for that session file.
/// - `payload.info == null` and `payload.rate_limits == null` are valid; neither may be shown as zero.
/// - Rate-limit windows expose `used_percent`, optional `window_minutes`, and optional `resets_at`.
///
/// Deltas are computed from cumulative totals. Repeated totals are ignored. A total that moves
/// backwards is treated as a new accounting segment (compaction/resume) and the new total is
/// counted once. Cross-file replay is deduplicated by timestamp plus cumulative tuple.
public struct CodexProvider: UsageProvider {
    public let id: ProviderID = .codex
    public let refreshCadence: RefreshCadence = .local
    public let root: URL

    private let reader = JSONLReader()
    private let estimator: CostEstimator

    public init(root: URL? = nil, estimator: CostEstimator = CostEstimator()) {
        self.root = root ?? Self.defaultRoot
        self.estimator = estimator
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    public var sourceDescription: String {
        "Local rollouts · \(displayPath(root))"
    }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            reportsQuota: true,
            reportsResetTimes: true,
            reportsLocalTokens: true,
            reportsReportedCost: false,
            reportsEstimatedCost: true,
            supportsVerifiedSignIn: false,
            accountUsageURL: nil
        )
    }

    public func refresh(cache: ProviderCache?, now: Date) async -> ProviderRefreshResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return snapshotResult(
                status: .notConfigured,
                now: now,
                cache: cache,
                quotas: [],
                notes: [
                    MetricNote(
                        kind: .unavailable,
                        message: "Codex sessions folder was not found.",
                        recovery: "Run Codex CLI once or choose the folder in Settings."
                    )
                ]
            )
        }
        guard isDirectory.boolValue else {
            return errorResult(message: "Codex sessions path is not a folder.", now: now, cache: cache)
        }

        let files: [URL]
        do {
            files = try discoverRolloutFiles()
        } catch {
            return errorResult(
                message: "Could not read Codex sessions: \(error.localizedDescription)",
                now: now,
                cache: cache
            )
        }

        var knownKeys = cache?.dedupeKeys ?? []
        var newEvents: [UsageEvent] = []
        var checkpoints: [String: FileCheckpoint] = [:]
        var malformed = 0
        var fileFailures = 0
        var successfulFiles = 0
        var resets = 0

        var latestQuotaWindows = cache?.lastSnapshot?.quotas ?? []
        var latestQuotaObservedAt = latestQuotaWindows.map(\.observedAt).max()

        for file in files {
            let key = file.path
            let previous = cache?.checkpoints[key]
            do {
                let preparation = try reader.prepare(url: file, checkpoint: previous)
                if preparation.startOffset == preparation.fileSize && !preparation.didReset {
                    var checkpoint = previous ?? FileCheckpoint()
                    checkpoint.fileSize = preparation.fileSize
                    checkpoint.modifiedAt = preparation.modifiedAt
                    checkpoint.prefixHash = preparation.prefixHash
                    checkpoint.offset = preparation.fileSize
                    checkpoints[key] = checkpoint
                    successfulFiles += 1
                    continue
                }

                let initialTotal = preparation.didReset ? nil : previous?.lastTotal
                let initialModel = preparation.didReset ? nil : previous?.lastModel
                let parser = CodexLineParser(
                    lastTotal: initialTotal,
                    lastModel: initialModel,
                    estimator: estimator
                )
                let result = try reader.scan(url: file, preparation: preparation) { data, _ in
                    parser.parse(data: data, now: now)
                }
                malformed += result.malformedLines
                successfulFiles += 1
                resets += parser.resetCount

                for event in parser.events where !knownKeys.contains(event.dedupeKey) {
                    knownKeys.insert(event.dedupeKey)
                    newEvents.append(event)
                }

                if let quota = parser.latestQuota, let observedAt = parser.latestQuotaObservedAt,
                   latestQuotaObservedAt == nil || observedAt >= latestQuotaObservedAt! {
                    latestQuotaWindows = quota
                    latestQuotaObservedAt = observedAt
                }

                var checkpoint = result.checkpoint
                checkpoint.lastTotal = parser.lastTotal
                checkpoint.lastFingerprint = parser.lastFingerprint
                checkpoint.lastModel = parser.lastModel
                checkpoints[key] = checkpoint
            } catch is CancellationError {
                return snapshotResult(status: .error, now: now, cache: cache, quotas: latestQuotaWindows, notes: [])
            } catch {
                fileFailures += 1
                if let previous { checkpoints[key] = previous }
            }
        }

        var notes: [MetricNote] = []
        notes.append(MetricNote(
            kind: .info,
            message: "Token totals are from local Codex sessions and may lag account-wide activity."
        ))
        if latestQuotaWindows.isEmpty {
            notes.append(MetricNote(
                kind: .unavailable,
                message: "Codex did not persist rate-limit windows in these rollout files.",
                recovery: "Run /status in Codex or check usage in ChatGPT. Rollout rate limits are frequently null."
            ))
        } else {
            notes.append(MetricNote(
                kind: .info,
                message: "Quota windows are the latest local Codex snapshot; they may lag account-wide usage."
            ))
            if let observed = latestQuotaObservedAt, now.timeIntervalSince(observed) > 600 {
                notes.append(MetricNote(
                    kind: .stale,
                    message: "The latest local rate-limit snapshot is older than 10 minutes.",
                    recovery: "Run /status in Codex for a fresh account reading."
                ))
            }
        }
        if fileFailures > 0 {
            notes.append(MetricNote(
                kind: .unavailable,
                message: "\(fileFailures) rollout file\(fileFailures == 1 ? "" : "s") could not be read.",
                recovery: "Check file permissions, then refresh."
            ))
        }
        if malformed > 0 {
            notes.append(MetricNote(
                kind: .unavailable,
                message: "Skipped \(malformed) malformed rollout line\(malformed == 1 ? "" : "s").",
                recovery: "Malformed lines are isolated; other usage is still counted."
            ))
        }
        if resets > 0 {
            notes.append(MetricNote(
                kind: .info,
                message: "Codex cumulative totals reset \(resets) time\(resets == 1 ? "" : "s"); each new segment was counted once."
            ))
        }

        let allEvents = (cache?.events ?? []) + newEvents
        let status: ProviderStatus
        if fileFailures > 0 && successfulFiles == 0 && !files.isEmpty {
            status = .error
        } else if files.isEmpty || allEvents.isEmpty {
            status = .empty
        } else {
            status = .ok
        }

        let observedAt = max(
            allEvents.map(\.timestamp).max() ?? now,
            latestQuotaObservedAt ?? now
        )
        let snapshot = UsageSnapshot(
            provider: id,
            status: status,
            observedAt: observedAt,
            lastCheckedAt: now,
            source: sourceDescription,
            accountScope: "Local token history; quota snapshots are account-wide",
            quotas: latestQuotaWindows,
            notes: notes,
            capabilities: capabilities
        )
        return ProviderRefreshResult(
            provider: id,
            snapshot: snapshot,
            newEvents: newEvents,
            checkpoints: checkpoints,
            filesDiscovered: files.count,
            malformedLines: malformed
        )
    }

    private func discoverRolloutFiles() throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == false { continue }
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    private func snapshotResult(
        status: ProviderStatus,
        now: Date,
        cache: ProviderCache?,
        quotas: [QuotaWindow],
        notes: [MetricNote]
    ) -> ProviderRefreshResult {
        let snapshot = UsageSnapshot(
            provider: id,
            status: status,
            observedAt: cache?.lastSnapshot?.observedAt ?? now,
            lastCheckedAt: now,
            source: sourceDescription,
            accountScope: "Local token history; quota snapshots are account-wide",
            quotas: quotas,
            notes: notes,
            capabilities: capabilities
        )
        return ProviderRefreshResult(
            provider: id,
            snapshot: snapshot,
            checkpoints: cache?.checkpoints ?? [:]
        )
    }

    private func errorResult(message: String, now: Date, cache: ProviderCache?) -> ProviderRefreshResult {
        var notes = cache?.lastSnapshot?.notes ?? []
        notes.insert(MetricNote(kind: .error, message: message, recovery: "Check the folder in Settings."), at: 0)
        return snapshotResult(
            status: .error,
            now: now,
            cache: cache,
            quotas: cache?.lastSnapshot?.quotas ?? [],
            notes: notes
        )
    }

    private func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}

private final class CodexLineParser {
    private struct Line: Decodable {
        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private struct Payload: Decodable {
        let type: String?
        let info: TokenInfo?
        let rateLimits: RateLimits?
        let model: String?
    }

    private struct TokenInfo: Decodable {
        let totalTokenUsage: TokenUsage?
    }

    private struct TokenUsage: Decodable {
        let inputTokens: Int64?
        let cachedInputTokens: Int64?
        let cacheWriteInputTokens: Int64?
        let outputTokens: Int64?
        let reasoningOutputTokens: Int64?
        let totalTokens: Int64?
    }

    private struct RateLimits: Decodable {
        let primary: RateLimitWindow?
        let secondary: RateLimitWindow?
        let planType: String?
    }

    private struct RateLimitWindow: Decodable {
        let usedPercent: Double?
        let windowMinutes: Int?
        let resetsAt: Int64?
    }

    private let decoder: JSONDecoder
    private let dates = DateParser()
    private let estimator: CostEstimator

    private(set) var events: [UsageEvent] = []
    private(set) var lastTotal: TokenTotals?
    private(set) var lastFingerprint: String?
    private(set) var lastModel: String?
    private(set) var resetCount = 0
    private(set) var latestQuota: [QuotaWindow]?
    private(set) var latestQuotaObservedAt: Date?

    init(lastTotal: TokenTotals?, lastModel: String?, estimator: CostEstimator) {
        self.lastTotal = lastTotal
        self.lastModel = lastModel
        self.estimator = estimator
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func parse(data: Data, now: Date) -> Bool {
        guard let line = try? decoder.decode(Line.self, from: data) else { return false }
        guard let payload = line.payload else { return true }

        if line.type == "turn_context" {
            if let model = payload.model, !model.isEmpty { lastModel = model }
            return true
        }

        guard line.type == "event_msg", payload.type == "token_count" else { return true }

        let timestamp = dates.parse(line.timestamp) ?? now

        if let rateLimits = payload.rateLimits,
           let windows = makeQuotaWindows(from: rateLimits, observedAt: timestamp),
           !windows.isEmpty {
            latestQuota = windows
            latestQuotaObservedAt = timestamp
        }

        guard let usage = payload.info?.totalTokenUsage else { return true }

        let current = TokenTotals(
            input: usage.inputTokens ?? 0,
            output: usage.outputTokens ?? 0,
            cacheRead: usage.cachedInputTokens ?? 0,
            cacheWrite: usage.cacheWriteInputTokens ?? 0,
            reasoning: usage.reasoningOutputTokens ?? 0,
            total: usage.totalTokens ?? (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0)
        )

        let delta: TokenTotals
        if let previous = lastTotal {
            if current.isMonotonic(over: previous) {
                delta = current.subtracting(previous)
            } else {
                delta = current
                resetCount += 1
            }
        } else {
            delta = current
        }
        lastTotal = current

        let fingerprint = "codex:\(Int64(timestamp.timeIntervalSince1970 * 1000)):\(current.input):\(current.cacheRead):\(current.cacheWrite):\(current.output):\(current.reasoning):\(current.total)"
        lastFingerprint = fingerprint

        guard !delta.isEmpty else { return true }

        let tokens = TokenBreakdown(
            inputTokens: delta.input,
            outputTokens: delta.output,
            cacheReadTokens: delta.cacheRead,
            cacheWriteTokens: delta.cacheWrite,
            reasoningTokens: delta.reasoning
        )

        var estimate: Decimal?
        var estimateNote: String?
        switch estimator.estimate(tokens: delta, model: lastModel) {
        case .available(let value):
            estimate = value
        case .unavailable(let reason):
            estimateNote = reason
        }

        events.append(UsageEvent(
            provider: .codex,
            dedupeKey: fingerprint,
            timestamp: timestamp,
            model: lastModel,
            tokens: tokens,
            reportedCostUSD: nil,
            estimatedCostUSD: estimate,
            estimateNote: estimateNote
        ))
        return true
    }

    private func makeQuotaWindows(from rateLimits: RateLimits, observedAt: Date) -> [QuotaWindow]? {
        var windows: [QuotaWindow] = []
        if let primary = rateLimits.primary, let used = primary.usedPercent, used.isFinite {
            windows.append(makeWindow(
                idPrefix: "primary",
                labelFallback: "Primary window",
                window: primary,
                usedPercent: used,
                observedAt: observedAt
            ))
        }
        if let secondary = rateLimits.secondary, let used = secondary.usedPercent, used.isFinite {
            windows.append(makeWindow(
                idPrefix: "secondary",
                labelFallback: "Secondary window",
                window: secondary,
                usedPercent: used,
                observedAt: observedAt
            ))
        }
        return windows.isEmpty ? nil : windows
    }

    private func makeWindow(
        idPrefix: String,
        labelFallback: String,
        window: RateLimitWindow,
        usedPercent: Double,
        observedAt: Date
    ) -> QuotaWindow {
        let minutes = window.windowMinutes
        let kind: QuotaWindowKind
        let label: String
        if let minutes {
            switch minutes {
            case 300:
                kind = .session
                label = "5-hour window"
            case 10_080:
                kind = .weekly
                label = "Weekly window"
            case 43_200...:
                kind = .monthly
                label = "\(max(1, minutes / 43_200))-month window"
            case 1_440...:
                kind = .other
                label = "\(max(1, minutes / 1_440))-day window"
            case 60...:
                kind = .other
                label = "\(max(1, minutes / 60))-hour window"
            default:
                kind = .other
                label = "\(minutes)-minute window"
            }
        } else {
            kind = .other
            label = labelFallback
        }
        let resetsAt = window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return QuotaWindow(
            id: "codex-\(idPrefix)-\(minutes ?? 0)",
            kind: kind,
            label: label,
            usedPercent: usedPercent,
            windowMinutes: minutes,
            resetsAt: resetsAt,
            observedAt: observedAt,
            scope: "Account-wide",
            source: "Codex rollout rate_limits"
        )
    }
}
