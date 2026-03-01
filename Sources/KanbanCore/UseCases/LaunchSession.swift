import Foundation

/// Launches a new Claude Code session inside a tmux session.
/// Does NOT manage Link records — the caller owns link lifecycle.
public final class LaunchSession: SessionLauncher, @unchecked Sendable {
    private let tmux: TmuxManagerPort

    public init(tmux: TmuxManagerPort) {
        self.tmux = tmux
    }

    public func launch(
        projectPath: String,
        prompt: String,
        worktreeName: String?,
        shellOverride: String?,
        extraEnv: [String: String] = [:]
    ) async throws -> String {
        let sessionName = Self.tmuxSessionName(project: projectPath, worktree: worktreeName)

        // Build the claude command
        var cmd = "claude"
        if let worktreeName {
            if worktreeName.isEmpty {
                // Empty string = auto-generate worktree name
                cmd += " --worktree"
            } else {
                cmd += " --worktree \(worktreeName)"
            }
        }

        cmd += " -p \(shellEscape(prompt))"

        // Prepend environment variables (SHELL override + KANBAN_* vars)
        let envPrefix = buildEnvPrefix(shellOverride: shellOverride, extraEnv: extraEnv)
        if !envPrefix.isEmpty {
            cmd = envPrefix + " " + cmd
        }

        try await tmux.createSession(name: sessionName, path: projectPath, command: cmd)
        return sessionName
    }

    public func resume(
        sessionId: String,
        projectPath: String,
        shellOverride: String?,
        extraEnv: [String: String] = [:]
    ) async throws -> String {
        // Check if there's already a tmux session for this
        let existing = try await tmux.listSessions()
        if let match = existing.first(where: { $0.name.contains(String(sessionId.prefix(8))) }) {
            return match.name
        }

        // Create new tmux session with resume command
        let sessionName = "claude-\(String(sessionId.prefix(8)))"
        var cmd = "claude --resume \(sessionId)"

        // Prepend environment variables
        let envPrefix = buildEnvPrefix(shellOverride: shellOverride, extraEnv: extraEnv)
        if !envPrefix.isEmpty {
            cmd = envPrefix + " " + cmd
        }

        try await tmux.createSession(name: sessionName, path: projectPath, command: cmd)
        return sessionName
    }

    // MARK: - Private

    /// Build a string of VAR=value assignments to prepend to the command.
    private func buildEnvPrefix(shellOverride: String?, extraEnv: [String: String]) -> String {
        var parts: [String] = []

        if let shellOverride {
            parts.append("SHELL=\(shellOverride)")
        }

        // Sort for deterministic output
        for key in extraEnv.keys.sorted() {
            if let value = extraEnv[key] {
                parts.append("\(key)=\(shellEscape(value))")
            }
        }

        return parts.joined(separator: " ")
    }

    public static func tmuxSessionName(project: String, worktree: String?) -> String {
        let projectName = (project as NSString).lastPathComponent
        if let worktree {
            return "\(projectName)-\(worktree)"
        }
        return projectName
    }

    private func shellEscape(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
