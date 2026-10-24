import Foundation
import Testing
@testable import UsageCore

@Suite("CLI runner")
struct RunnerTests {
    @Test func environmentIsAnAllowlist() {
        let environment = CLI.environment(for: "/bin/ls")
        #expect(environment["HOME"] == CLI.home)
        #expect(environment["PATH"] != nil)
        #expect(environment["COMMAND_CODE_API_KEY"] == nil)
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment.count <= 8)
    }

    @Test func timeoutKillsTheProcess() {
        let started = Date()
        let output = CLIRunner.run("/bin/sleep", ["3"], timeout: 0.4)
        #expect(output == nil)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func runsAShortCommand() throws {
        let output = try #require(CLIRunner.run("/bin/echo", ["hello"], timeout: 5))
        #expect(String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test func trustedSystemBinary() {
        #expect(CLI.trusted("/bin/ls"))
    }

    @Test func rejectsWorldWritableBinary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-tracker-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("tool")
        #expect(FileManager.default.createFile(atPath: binary.path, contents: Data("#!/bin/sh\n".utf8),
                                               attributes: [.posixPermissions: 0o777]))
        #expect(!CLI.trusted(binary.path))
    }
}
