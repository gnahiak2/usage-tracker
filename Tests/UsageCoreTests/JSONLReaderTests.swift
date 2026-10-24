import Foundation
import XCTest
@testable import UsageCore

final class JSONLReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    private func append(_ contents: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
    }

    func testScanReadsCompleteLinesAndResumesFromCheckpoint() throws {
        let url = directory.appendingPathComponent("session.jsonl")
        // The checkpoint stores a hash of the first 1024 bytes, so keep the file
        // past that boundary for appends to leave the prefix unchanged.
        let padding = String(repeating: "x", count: 1_200)
        try write("{\"a\":1}\n{\"pad\":\"\(padding)\"}\n{\"a\":2}\n", to: url)

        let reader = JSONLReader()
        let preparation = try reader.prepare(url: url, checkpoint: nil)
        var lines: [String] = []
        let result = try reader.scan(url: url, preparation: preparation) { data, _ in
            lines.append(String(decoding: data, as: UTF8.self))
            return true
        }

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.first, "{\"a\":1}")
        XCTAssertEqual(lines.last, "{\"a\":2}")
        XCTAssertEqual(result.checkpoint.offset, preparation.fileSize)
        XCTAssertFalse(result.incompleteTrailingLine)

        try append("{\"a\":3}\n", to: url)
        let resumed = try reader.prepare(url: url, checkpoint: result.checkpoint)
        XCTAssertEqual(resumed.startOffset, preparation.fileSize)
        XCTAssertFalse(resumed.didReset)

        var more: [String] = []
        _ = try reader.scan(url: url, preparation: resumed) { data, _ in
            more.append(String(decoding: data, as: UTF8.self))
            return true
        }
        XCTAssertEqual(more, ["{\"a\":3}"])
    }

    func testTrailingPartialLineIsLeftForTheNextScan() throws {
        let url = directory.appendingPathComponent("session.jsonl")
        try write("{\"a\":1}\n{\"a\":2}", to: url)

        let reader = JSONLReader()
        let preparation = try reader.prepare(url: url, checkpoint: nil)
        var lines: [String] = []
        let result = try reader.scan(url: url, preparation: preparation) { data, _ in
            lines.append(String(decoding: data, as: UTF8.self))
            return true
        }

        XCTAssertEqual(lines, ["{\"a\":1}"])
        XCTAssertTrue(result.incompleteTrailingLine)
        XCTAssertLessThan(result.checkpoint.offset, preparation.fileSize)
    }

    func testCheckpointResetsWhenFileShrinks() throws {
        let url = directory.appendingPathComponent("session.jsonl")
        try write("{\"a\":1}\n", to: url)

        let reader = JSONLReader()
        let preparation = try reader.prepare(
            url: url,
            checkpoint: FileCheckpoint(offset: 10_000)
        )
        XCTAssertTrue(preparation.didReset)
        XCTAssertEqual(preparation.startOffset, 0)
    }

    func testMalformedLinesAreCountedWithoutAbortingTheScan() throws {
        let url = directory.appendingPathComponent("session.jsonl")
        try write("{\"a\":1}\nnot json\n{\"a\":3}\n", to: url)

        let reader = JSONLReader()
        let preparation = try reader.prepare(url: url, checkpoint: nil)
        var lines: [String] = []
        let result = try reader.scan(url: url, preparation: preparation) { data, _ in
            let line = String(decoding: data, as: UTF8.self)
            guard line != "not json" else { return false }
            lines.append(line)
            return true
        }

        XCTAssertEqual(lines, ["{\"a\":1}", "{\"a\":3}"])
        XCTAssertEqual(result.malformedLines, 1)
    }

    func testOversizedLinesAreCounted() throws {
        let url = directory.appendingPathComponent("session.jsonl")
        let hugeLine = String(repeating: "x", count: 64)
        try write("{\"a\":1}\n\(hugeLine)\n{\"a\":3}\n", to: url)

        let reader = JSONLReader(maxLineBytes: 16, chunkSize: 8)
        let preparation = try reader.prepare(url: url, checkpoint: nil)
        var lines: [String] = []
        let result = try reader.scan(url: url, preparation: preparation) { data, _ in
            lines.append(String(decoding: data, as: UTF8.self))
            return true
        }

        XCTAssertEqual(lines, ["{\"a\":1}", "{\"a\":3}"])
        XCTAssertEqual(result.oversizedLines, 1)
        XCTAssertEqual(result.malformedLines, 1)
    }

    func testMissingFileThrows() {
        let url = directory.appendingPathComponent("missing.jsonl")
        XCTAssertThrowsError(try JSONLReader().prepare(url: url, checkpoint: nil))
    }
}
