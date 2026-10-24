import Foundation

public protocol UsageProvider: Sendable {
    var service: Service { get }
    func read() -> Snapshot
}

public enum Paths {
    public static let cacheDirectory: String = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/usage-tracker", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(base, 0o700)
        return base
    }()

    public static let stateFile = "\(cacheDirectory)/state.json"
    public static let claudeStatusFile = "\(cacheDirectory)/claude-status.json"

    public static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func write(_ data: Data, to path: String) {
        let temporary = path + ".\(getpid())"
        guard FileManager.default.createFile(atPath: temporary, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary, path) != 0 { unlink(temporary) }
    }
}
