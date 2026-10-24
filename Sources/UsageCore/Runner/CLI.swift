import Darwin
import Foundation

/// Finding, checking and starting a vendor CLI.
///
/// The app never searches `PATH` from its own environment: a directory some other tool added would be
/// trusted without checking. Only fixed, known install locations are searched, and only binaries whose
/// path, target and ancestors are owned by this user (or root) and not writable by anyone else are run.
public enum CLI {
    public static let home = FileManager.default.homeDirectoryForCurrentUser.path

    public static let searchPath = [
        "\(home)/.local/bin",
        "\(home)/.grok/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(home)/.npm-global/bin",
        "\(home)/.bun/bin",
        "\(home)/.volta/bin",
    ]

    public static let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// A private, empty working directory. A CLI is never run inside a project.
    public static let workDir: String = {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("usage-tracker-cwd")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return directory
    }()

    public enum Found {
        case ok(String)
        case missing
        case untrusted(String)
    }

    public static func find(_ name: String) -> Found {
        if let override = UserDefaults.standard.string(forKey: "\(name)Path"), override.hasPrefix("/") {
            guard FileManager.default.fileExists(atPath: override) else { return .missing }
            return trusted(override) ? .ok(override) : .untrusted(override)
        }
        for directory in searchPath {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return trusted(candidate) ? .ok(candidate) : .untrusted(candidate)
            }
        }
        return .missing
    }

    public static func trusted(_ path: String) -> Bool {
        guard let resolved = realpath(path, nil) else { return false }
        let target = String(cString: resolved)
        free(resolved)
        guard FileManager.default.isExecutableFile(atPath: target), safeNode(path, isLink: true) else { return false }
        return safeChain(target) && safeChain((path as NSString).deletingLastPathComponent)
    }

    public static func safeChain(_ path: String) -> Bool {
        var current = path
        while true {
            guard safeNode(current, isLink: false) else { return false }
            if current == "/" || current.isEmpty { return true }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static let adminGroup: gid_t = 80

    static func safeNode(_ path: String, isLink: Bool) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        guard info.st_uid == getuid() || info.st_uid == 0 else { return false }
        if isLink && (info.st_mode & S_IFMT) == S_IFLNK { return true }
        if (info.st_mode & S_IWOTH) != 0 { return false }
        if (info.st_mode & S_IWGRP) != 0 && info.st_gid != adminGroup && info.st_gid != 0 { return false }
        return !aclGrantsWrite(path)
    }

    static func aclGrantsWrite(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let writes: [acl_perm_t] = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                                    ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY,
                                    ACL_CHANGE_OWNER]
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0, let entry {
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_ALLOW else { continue }
            var permissions: acl_permset_t?
            guard acl_get_permset(entry, &permissions) == 0, let permissions else { return true }
            if writes.contains(where: { acl_get_perm_np(permissions, $0) == 1 }) { return true }
        }
        return false
    }

    /// An allowlist, not the app's environment minus secrets. API keys, tokens and SSH agent sockets stay out.
    public static func environment(for binary: String) -> [String: String] {
        let mine = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["USER", "LOGNAME", "TMPDIR"] {
            if let value = mine[key] { environment[key] = value }
        }
        let link = (binary as NSString).deletingLastPathComponent
        let real = ((binary as NSString).resolvingSymlinksInPath as NSString).deletingLastPathComponent
        var path: [String] = []
        for directory in [link, real] + searchPath + systemPath {
            if !path.contains(directory) && safeChain(directory) { path.append(directory) }
        }
        environment["PATH"] = path.joined(separator: ":")
        environment["HOME"] = home
        environment["LANG"] = "en_US.UTF-8"
        environment["NO_COLOR"] = "1"
        return environment
    }

    /// The argv needed to start a binary. Scripts get their interpreter resolved and checked here, so
    /// nothing is looked up through an untrusted PATH later.
    public static func launchArgs(_ binary: String) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: binary) else { return nil }
        let head = handle.readData(ofLength: 512)
        try? handle.close()
        guard head.starts(with: Array("#!".utf8)) else { return [binary] }
        guard let firstLine = String(decoding: head, as: UTF8.self).split(separator: "\n").first else { return nil }
        var parts = firstLine.dropFirst(2).split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts[0] == "/usr/bin/env" {
            parts.removeFirst()
            while let flag = parts.first, flag.hasPrefix("-") { parts.removeFirst() }
            guard let name = parts.first, case .ok(let found) = find(name), let resolved = realpath(found, nil) else { return nil }
            parts[0] = String(cString: resolved)
            free(resolved)
        }
        guard parts[0].hasPrefix("/"), trusted(parts[0]) else { return nil }
        return parts + [binary]
    }
}
