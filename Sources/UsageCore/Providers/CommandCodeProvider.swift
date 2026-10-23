import Foundation

/// Reads Command Code's local session transcripts. The verified record shape is:
/// a `session` header followed by `message` entries; assistant entries may carry `usage`
/// (`inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`, `costUsd`) and `model`.
/// Usage is per turn, not cumulative. Forked and cloned sessions copy entries, so the stable
/// `message.meta.messageId` is used for global dedupe.
public struct CommandCodeProvider: UsageProvider {
    public let id: ProviderID = .commandCode
    public let refreshCadence: RefreshCadence = .local
    public let root: URL

    private let reader = JSONLReader()

    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".commandcode", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    public var sourceDescription: String {
        "Local sessions · \(displayPath(root))"
    }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            reportsQuota: false,
            reportsResetTimes: false,
            reportsLocalTokens: true,
            reportsReportedCost: true,
            reportsEstimatedCost: false,
            supportsVerifiedSignIn: false,
            accountUsageURL: URL(string: "https://commandcode.ai/docs/resources/usage-limits")
        )
    }

    public func refresh(cache: ProviderCache?, now: Date) async -> ProviderRefreshResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return snapshotResult(
                status: .notConfigured,
                now: now,
                cache: cache,
                notes: [
                    MetricNote(
                        kind: .unavailable,
                        message: "Command Code sessions folder was not found.",
                        recovery: "Choose the folder in Settings, or run Command Code once to create it.",
                        actionURL: URL(string: "https://commandcode.ai/docs")
                    )
                ]
            )
        }
        guard isDirectory.boolValue else {
            return errorResult(message: "Command Code sessions path is not a folder.", now: now, cache: cache)
        }

        let files: [URL]
        do {
            files = try discoverSessionFiles()
        } catch {
            return errorResult(
                message: "Could not read Command Code sessions: \(error.localizedDescription)",
                now: now,
                cache: cache
            )
        }

        var knownKeys = cache?.dedupeKeys ?? []
        var newEvents: [UsageEvent] = []
        var checkpoints: [String: FileCheckpoint] = [:]
        var notes: [MetricNote] = []
        var malformed = 0
        var fileFailures = 0
        var successfulFiles = 0
        var unknownVersions: Set<Int> = []

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

                let parser = CommandCodeLineParser()
                var version: Int? = nil
                let result = try reader.scan(url: file, preparation: preparation) { data, offset in
                    parser.parse(data: data, lineOffset: offset, version: &version)
                }
                malformed += result.malformedLines
                successfulFiles += 1
                if let version, version > 3 { unknownVersions.insert(version) }
                for event in parser.events where !knownKeys.contains(event.dedupeKey) {
                    knownKeys.insert(event.dedupeKey)
                    newEvents.append(event)
                }
                checkpoints[key] = result.checkpoint
            } catch is CancellationError {
                return snapshotResult(status: .error, now: now, cache: cache, notes: [])
            } catch {
                fileFailures += 1
                if let previous { checkpoints[key] = previous }
            }
        }

        if fileFailures > 0 {
            notes.append(MetricNote(
                kind: .unavailable,
                message: "\(fileFailures) session file\(fileFailures == 1 ? "" : "s") could not be read.",
                recovery: "Check file permissions, then refresh."
            ))
        }
        if malformed > 0 {
            notes.append(MetricNote(
                kind: .unavailable,
                message: "Skipped \(malformed) malformed session line\(malformed == 1 ? "" : "s").",
                recovery: "Malformed lines are isolated; other usage is still counted."
            ))
        }
        if let version = unknownVersions.sorted().last {
            notes.append(MetricNote(
                kind: .info,
                message: "Session schema version \(version) is newer than the verified version 3.",
                recovery: "Known usage fields were still parsed."
            ))
        }

        notes.append(quotaNote)

        let allEvents = (cache?.events ?? []) + newEvents
        let status: ProviderStatus
        if fileFailures > 0 && successfulFiles == 0 && !files.isEmpty {
            status = .error
        } else if files.isEmpty || allEvents.isEmpty {
            status = .empty
        } else {
            status = .ok
        }

        let observedAt = allEvents.map(\.timestamp).max() ?? now
        let snapshot = UsageSnapshot(
            provider: id,
            status: status,
            observedAt: observedAt,
            lastCheckedAt: now,
            source: sourceDescription,
            accountScope: "Local device activity",
            quotas: [],
            notes: notes,
            capabilities: capabilities
        )
        let result = ProviderRefreshResult(
            provider: id,
            snapshot: snapshot,
            newEvents: newEvents,
            checkpoints: checkpoints,
            filesDiscovered: files.count,
            malformedLines: malformed
        )
        return result
    }

    private var quotaNote: MetricNote {
        MetricNote(
            kind: .unavailable,
            message: "Subscription quota and reset times are not readable from local session files.",
            recovery: "Run /usage in Command Code, or open the usage-limits page.",
            actionURL: URL(string: "https://commandcode.ai/docs/resources/usage-limits")
        )
    }

    private func discoverSessionFiles() throws -> [URL] {
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
            guard url.pathExtension == "jsonl" else { continue }
            let name = url.lastPathComponent
            if name.contains(".checkpoints.jsonl") || name.contains(".prompts.jsonl") { continue }
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
        notes: [MetricNote]
    ) -> ProviderRefreshResult {
        let snapshot = UsageSnapshot(
            provider: id,
            status: status,
            observedAt: cache?.lastSnapshot?.observedAt ?? now,
            lastCheckedAt: now,
            source: sourceDescription,
            accountScope: "Local device activity",
            quotas: [],
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
        return snapshotResult(status: .error, now: now, cache: cache, notes: notes)
    }

    private func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}

private final class CommandCodeLineParser {
    private struct Line: Decodable {
        let type: String?
        let id: String?
        let timestamp: String?
        let version: Int?
        let model: String?
        let usage: Usage?
        let message: Message?
    }

    private struct Usage: Decodable {
        let inputTokens: Int64?
        let outputTokens: Int64?
        let cacheReadTokens: Int64?
        let cacheWriteTokens: Int64?
        let costUsd: Decimal?
    }

    private struct Message: Decodable {
        let role: String?
        let meta: Meta?
    }

    private struct Meta: Decodable {
        let messageId: String?
        let createdAt: Int64?
    }

    private let decoder = JSONDecoder()
    private let dates = DateParser()
    private var sessionID: String?
    private(set) var events: [UsageEvent] = []

    func parse(data: Data, lineOffset: Int64, version: inout Int?) -> Bool {
        guard let line = try? decoder.decode(Line.self, from: data) else { return false }

        if line.type == "session" {
            sessionID = line.id
            version = line.version
            return true
        }

        if let parsedVersion = line.version { version = parsedVersion }

        guard line.type == "message" else { return true }
        guard line.message?.role == "assistant", let usage = line.usage else { return true }

        let timestamp = dates.parse(line.timestamp) ?? line.message?.meta?.createdAt.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
        } ?? Date(timeIntervalSince1970: 0)

        let metaID = line.message?.meta?.messageId
        let fallback = sessionID ?? "unknown-session"
        let entryID = line.id ?? "line-\(lineOffset)"
        let dedupeKey: String
        if let metaID, !metaID.isEmpty {
            dedupeKey = "cc:\(metaID)"
        } else {
            dedupeKey = "cc:\(fallback):\(entryID)"
        }

        let tokens = TokenBreakdown(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens
        )
        guard tokens.hasAnyTokenValue || usage.costUsd != nil else { return true }

        events.append(UsageEvent(
            provider: .commandCode,
            dedupeKey: dedupeKey,
            timestamp: timestamp,
            model: line.model,
            tokens: tokens,
            reportedCostUSD: usage.costUsd
        ))
        return true
    }
}
