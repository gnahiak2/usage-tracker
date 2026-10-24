import Foundation

public enum CLIRunner {
    public struct Output {
        public let data: Data
        public let code: Int32
    }

    public enum RPCResult {
        case ok([String: Any])
        case failed(String)
    }

    /// Run a trusted CLI to completion under a hard deadline.
    public static func run(_ binary: String, _ arguments: [String], timeout: TimeInterval = 20,
                           extraEnvironment: [String: String] = [:], environmentFor: String? = nil) -> Output? {
        guard let start = CLI.launchArgs(binary) else { return nil }
        return run(argv: start + arguments, binary: environmentFor ?? binary, timeout: timeout,
                   extraEnvironment: extraEnvironment)
    }

    /// Run an already assembled argv (for example a sandbox wrapper) and build the environment for `binary`.
    public static func run(argv: [String], binary: String, timeout: TimeInterval = 20,
                           extraEnvironment: [String: String] = [:]) -> Output? {
        let environment = CLI.environment(for: binary).merging(extraEnvironment) { $1 }
        guard let child = Child(argv, environment: environment, cwd: CLI.workDir) else { return nil }
        child.closeInput()
        let (data, timedOut) = child.readAll(until: Date().addingTimeInterval(timeout))
        if timedOut {
            child.terminate()
            return nil
        }
        let code = child.finish()
        guard code >= 0 else { return nil }
        return Output(data: data, code: code)
    }

    /// One JSON-RPC exchange over stdio: initialize, optional notification, one call, then stop.
    public static func rpc(argv: [String], binary: String, initialize: [String: Any], notify: String? = nil,
                           method: String, params: [String: Any] = [:], timeout: TimeInterval = 20,
                           extraEnvironment: [String: String] = [:]) -> RPCResult {
        let environment = CLI.environment(for: binary).merging(extraEnvironment) { $1 }
        guard let child = Child(argv, environment: environment, cwd: CLI.workDir) else {
            return .failed("could not start")
        }
        defer { child.terminate() }

        let deadline = Date().addingTimeInterval(timeout)
        func send(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            child.write(String(decoding: data, as: UTF8.self) + "\n")
        }
        func reply(id: Int) -> [String: Any]? {
            while let line = child.readLine(until: deadline) {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if (object["id"] as? Int) == id { return object }
            }
            return nil
        }
        func failure(_ object: [String: Any]?) -> String {
            guard let object else { return Date() >= deadline ? "timed out" : "no answer" }
            return ((object["error"] as? [String: Any])?["message"] as? String) ?? "unexpected answer"
        }

        send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": initialize])
        let initialized = reply(id: 1)
        guard initialized?["result"] != nil else { return .failed(failure(initialized)) }
        if let notify {
            send(["jsonrpc": "2.0", "method": notify, "params": [String: Any]()])
        }
        send(["jsonrpc": "2.0", "id": 2, "method": method, "params": params])
        let answer = reply(id: 2)
        guard let result = answer?["result"] as? [String: Any] else { return .failed(failure(answer)) }
        return .ok(result)
    }
}
