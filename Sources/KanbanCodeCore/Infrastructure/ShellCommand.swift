import Foundation

/// Runs shell commands and returns their output.
public enum ShellCommand {

    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public var succeeded: Bool { exitCode == 0 }
    }

    /// Run a command and capture its output.
    public static func run(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: String? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let dir = currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Read pipe data BEFORE waitUntilExit to avoid deadlock when output
        // exceeds the pipe buffer (~64KB). If we wait first, the child process
        // blocks on write and we block on exit — classic pipe deadlock.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    /// Check if a command is available on the system.
    public static func isAvailable(_ command: String) async -> Bool {
        findExecutable(command) != nil
    }

    /// Resolve a command name to an absolute path by checking common locations.
    /// macOS .app bundles have a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin),
    /// so Homebrew and other tools aren't found via `env` or `which`.
    /// Returns nil if the command isn't found anywhere.
    public static func findExecutable(_ command: String) -> String? {
        let home = NSHomeDirectory()
        let searchPaths = [
            "\(home)/.claude/local",   // Claude Code managed install
            "\(home)/.local/bin",      // XDG local bin / claude installer
            "/opt/homebrew/bin",       // Homebrew (Apple Silicon)
            "/usr/local/bin",          // Homebrew (Intel) / npm global
            "/usr/bin",                // System binaries
            "/bin",                    // Core system binaries
        ]
        for dir in searchPaths {
            let path = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
