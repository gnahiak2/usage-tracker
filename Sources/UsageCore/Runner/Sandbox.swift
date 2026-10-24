import Foundation

/// Runs a vendor CLI inside the macOS kernel sandbox. If the profile or `sandbox-exec` is missing the
/// CLI is not run at all: the caller reports that instead of falling back to an unrestricted process.
public enum Sandbox {
    public struct Box {
        public let argv: [String]
        public let binary: String
        public let environment: [String: String]
    }

    static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func wrap(_ service: Service, _ binary: String, _ arguments: [String]) -> Box? {
        guard let profile = Bundle.module.url(forResource: "cli", withExtension: "sb")?.path,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
              let executable = real(binary),
              let work = real(CLI.workDir),
              let home = real(CLI.home),
              let start = CLI.launchArgs(binary),
              let interpreter = start.first
        else { return nil }

        let state: String
        let execDirectory: String
        let helper: String
        let keychains: String
        let sharedTemp: String

        switch service {
        case .grok:
            state = "\(home)/.grok"
            execDirectory = (executable as NSString).deletingLastPathComponent
            helper = "/nonexistent-usage-tracker"
            keychains = "/nonexistent-usage-tracker"
            sharedTemp = "/nonexistent-usage-tracker"
        case .codex:
            state = "\(home)/.codex"
            let directory = (executable as NSString).deletingLastPathComponent
            let package = (directory as NSString).deletingLastPathComponent
            let parent = (package as NSString).deletingLastPathComponent
            execDirectory = (parent as NSString).lastPathComponent.hasPrefix("@") ? parent : package
            helper = "/nonexistent-usage-tracker"
            keychains = "/nonexistent-usage-tracker"
            sharedTemp = "/nonexistent-usage-tracker"
        case .gemini:
            state = "\(home)/.gemini"
            execDirectory = (home as NSString).appendingPathComponent(".gemini/antigravity-cli/bin")
            helper = "/usr/bin/security"
            keychains = "\(home)/Library/Keychains"
            sharedTemp = "/private/tmp"
        case .claude, .commandCode:
            return nil
        }

        let interpreterDirectory = (interpreter as NSString).deletingLastPathComponent
        let argv = [
            "/usr/bin/sandbox-exec", "-f", profile,
            "-D", "HOME=\(home)",
            "-D", "STATE=\(state)",
            "-D", "EXEC=\(executable)",
            "-D", "EXECDIR=\(execDirectory)",
            "-D", "INTERP=\(interpreter)",
            "-D", "INTERPDIR=\(interpreterDirectory)",
            "-D", "PTMP=\(work)",
            "-D", "HELPER=\(helper)",
            "-D", "KEYCHAINS=\(keychains)",
            "-D", "SHAREDTMP=\(sharedTemp)",
        ] + start + arguments

        return Box(argv: argv, binary: executable, environment: ["TMPDIR": work + "/"])
    }
}
