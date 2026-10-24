import Darwin
import Foundation

/// A child process in its own session, so a timeout can kill the CLI and everything it started.
final class Child {
    let pid: pid_t
    private let input: Int32
    private let output: Int32
    private var buffer = Data()
    private var inputClosed = false
    private var reaped = false
    private var eof = false

    /// A quota question never justifies more output than this.
    static let maxOutput = 4 << 20

    private static let setsid: Int16 = 0x0400
    private static let closeOnExec: Int16 = 0x4000

    init?(_ argv: [String], environment: [String: String], cwd: String) {
        guard !argv.isEmpty else { return nil }
        var stdinPipe: [Int32] = [0, 0]
        var stdoutPipe: [Int32] = [0, 0]
        guard pipe(&stdinPipe) == 0 else { return nil }
        guard pipe(&stdoutPipe) == 0 else {
            close(stdinPipe[0]); close(stdinPipe[1])
            return nil
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Child.setsid | Child.closeOnExec)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        var childPid: pid_t = 0
        let environmentList = environment.map { "\($0.key)=\($0.value)" }
        let result = withCStrings(argv) { cArgv in
            withCStrings(environmentList) { cEnv in
                posix_spawn(&childPid, argv[0], &actions, &attributes, cArgv, cEnv)
            }
        }

        close(stdinPipe[0])
        close(stdoutPipe[1])
        guard result == 0 else {
            close(stdinPipe[1])
            close(stdoutPipe[0])
            return nil
        }

        pid = childPid
        input = stdinPipe[1]
        output = stdoutPipe[0]
        _ = fcntl(output, F_SETFL, fcntl(output, F_GETFL) | O_NONBLOCK)
        _ = fcntl(input, F_SETNOSIGPIPE, 1)
    }

    func write(_ text: String) {
        guard !inputClosed else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { _ = Darwin.write(input, $0.baseAddress, bytes.count) }
    }

    func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        close(input)
    }

    func readLine(until deadline: Date) -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            guard fill(until: deadline) else {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return String(decoding: buffer, as: UTF8.self)
            }
        }
    }

    func readAll(until deadline: Date) -> (data: Data, timedOut: Bool) {
        while Date() < deadline && !eof {
            if !fill(until: deadline) {
                if eof || Date() >= deadline { break }
                // Poll can return early on a signal; try again rather than calling it a finished run.
                usleep(5_000)
            }
        }
        return (buffer, Date() >= deadline && !eof)
    }

    private func fill(until deadline: Date) -> Bool {
        guard buffer.count < Child.maxOutput else { return false }
        let milliseconds = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
        guard milliseconds > 0 else { return false }
        var descriptor = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, milliseconds) > 0 else { return false }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = read(output, &chunk, chunk.count)
        guard count > 0 else {
            eof = true
            return false
        }
        buffer.append(contentsOf: chunk[0..<count])
        return true
    }

    func terminate() {
        guard !reaped else { return }
        kill(-pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0..<20 {
            if waitpid(pid, &status, WNOHANG) == pid {
                kill(-pid, SIGKILL)
                cleanup()
                return
            }
            usleep(50_000)
        }
        kill(-pid, SIGKILL)
        waitpid(pid, &status, 0)
        cleanup()
    }

    func finish(within seconds: TimeInterval = 2) -> Int32 {
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid {
                kill(-pid, SIGKILL)
                cleanup()
                return (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
            }
            usleep(50_000)
        }
        terminate()
        return -1
    }

    private func cleanup() {
        guard !reaped else { return }
        reaped = true
        close(output)
        closeInput()
    }
}

private func withCStrings<Result>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result) -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
