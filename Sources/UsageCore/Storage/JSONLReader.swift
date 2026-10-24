import Foundation

public struct FileCheckpoint: Codable, Sendable, Equatable {
    public var offset: Int64
    public var fileSize: Int64
    public var modifiedAt: Date
    public var prefixHash: UInt64
    /// Codex only: last cumulative token total observed in this file.
    public var lastTotal: TokenTotals?
    /// Codex only: last event fingerprint, used to detect replayed rollouts.
    public var lastFingerprint: String?
    /// Codex only: most recent model from a turn_context entry.
    public var lastModel: String?

    public init(
        offset: Int64 = 0,
        fileSize: Int64 = 0,
        modifiedAt: Date = .distantPast,
        prefixHash: UInt64 = 0,
        lastTotal: TokenTotals? = nil,
        lastFingerprint: String? = nil,
        lastModel: String? = nil
    ) {
        self.offset = offset
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.prefixHash = prefixHash
        self.lastTotal = lastTotal
        self.lastFingerprint = lastFingerprint
        self.lastModel = lastModel
    }
}

public struct JSONLFilePreparation: Sendable, Equatable {
    public let fileSize: Int64
    public let modifiedAt: Date
    public let prefixHash: UInt64
    public let startOffset: Int64
    public let didReset: Bool
}

public struct JSONLScanResult: Sendable, Equatable {
    public let checkpoint: FileCheckpoint
    public let startOffset: Int64
    public let didReset: Bool
    public let linesProcessed: Int
    public let malformedLines: Int
    public let oversizedLines: Int
    public let incompleteTrailingLine: Bool
}

public enum JSONLReaderError: Error, Equatable {
    case missingFile(String)
    case unreadableFile(String)
    case invalidOffset
}

public struct JSONLReader: Sendable {
    public let maxLineBytes: Int
    private let chunkSize: Int

    public init(maxLineBytes: Int = 4 * 1024 * 1024, chunkSize: Int = 64 * 1024) {
        self.maxLineBytes = maxLineBytes
        self.chunkSize = chunkSize
    }

    public func prepare(url: URL, checkpoint: FileCheckpoint?) throws -> JSONLFilePreparation {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw JSONLReaderError.missingFile(url.path)
        }
        guard let sizeNumber = attributes[.size] as? NSNumber else {
            throw JSONLReaderError.unreadableFile(url.path)
        }
        let size = sizeNumber.int64Value
        let modifiedAt = (attributes[.modificationDate] as? Date) ?? .distantPast
        let hash = try prefixHash(url: url)

        var start: Int64 = 0
        var didReset = false
        if let checkpoint {
            if size < checkpoint.offset || checkpoint.offset < 0 || checkpoint.offset > size {
                didReset = true
            } else if checkpoint.prefixHash != hash {
                didReset = true
            } else if checkpoint.offset > 0 && !byteBeforeOffsetIsNewline(url: url, offset: checkpoint.offset) {
                didReset = true
            } else {
                start = checkpoint.offset
            }
        }

        return JSONLFilePreparation(
            fileSize: size,
            modifiedAt: modifiedAt,
            prefixHash: hash,
            startOffset: start,
            didReset: didReset
        )
    }

    /// Scans complete lines from the prepared offset. A trailing line without a newline is left
    /// unread so the next refresh can retry it after the writer finishes appending.
    ///
    /// `onLine` returns false for a malformed line. Malformed lines are isolated and counted; they
    /// never abort the rest of the file.
    public func scan(
        url: URL,
        preparation: JSONLFilePreparation,
        onLine: (Data, Int64) -> Bool
    ) throws -> JSONLScanResult {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw JSONLReaderError.unreadableFile(url.path)
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: UInt64(preparation.startOffset))
        } catch {
            throw JSONLReaderError.invalidOffset
        }

        var streamPosition = preparation.startOffset
        var checkpointOffset = preparation.startOffset
        var pending = Data()
        var skippingOversized = false
        var linesProcessed = 0
        var malformedLines = 0
        var oversizedLines = 0

        while true {
            if Task.isCancelled { throw CancellationError() }
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw JSONLReaderError.unreadableFile(url.path)
            }
            if chunk.isEmpty { break }
            pending.append(chunk)

            var searchStart = pending.startIndex
            while let newline = pending[searchStart...].firstIndex(of: 0x0A) {
                if Task.isCancelled { throw CancellationError() }
                let lineStart = streamPosition + Int64(pending.distance(from: pending.startIndex, to: searchStart))
                let lineEnd = newline
                let afterNewline = pending.index(after: newline)

                if skippingOversized {
                    skippingOversized = false
                    malformedLines += 1
                    oversizedLines += 1
                } else {
                    let lineData = pending[searchStart..<lineEnd]
                    if lineData.count > maxLineBytes {
                        malformedLines += 1
                        oversizedLines += 1
                    } else {
                        var line = Data(lineData)
                        if line.last == 0x0D { line.removeLast() }
                        if !line.isEmpty {
                            linesProcessed += 1
                            if !onLine(line, lineStart) {
                                malformedLines += 1
                            }
                        }
                    }
                }

                searchStart = afterNewline
                checkpointOffset = streamPosition + Int64(pending.distance(from: pending.startIndex, to: afterNewline))
            }

            let consumed = pending.distance(from: pending.startIndex, to: searchStart)
            if consumed > 0 {
                pending.removeFirst(consumed)
                streamPosition += Int64(consumed)
            }

            if pending.count > maxLineBytes {
                // No newline in a very large line. Discard it and skip to the next newline.
                streamPosition += Int64(pending.count)
                pending.removeAll(keepingCapacity: true)
                skippingOversized = true
            }
        }

        let incomplete = !pending.isEmpty || skippingOversized
        let checkpoint = FileCheckpoint(
            offset: checkpointOffset,
            fileSize: preparation.fileSize,
            modifiedAt: preparation.modifiedAt,
            prefixHash: preparation.prefixHash
        )

        return JSONLScanResult(
            checkpoint: checkpoint,
            startOffset: preparation.startOffset,
            didReset: preparation.didReset,
            linesProcessed: linesProcessed,
            malformedLines: malformedLines,
            oversizedLines: oversizedLines,
            incompleteTrailingLine: incomplete
        )
    }

    private func prefixHash(url: URL) throws -> UInt64 {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw JSONLReaderError.unreadableFile(url.path)
        }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 1024)) ?? Data()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in prefix {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private func byteBeforeOffsetIsNewline(url: URL, offset: Int64) -> Bool {
        guard offset > 0 else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset - 1))) != nil else { return false }
        let byte = try? handle.read(upToCount: 1)
        return byte == Data([0x0A])
    }
}
