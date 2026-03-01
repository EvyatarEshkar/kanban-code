import Foundation

/// Manages tmux sessions via the tmux CLI.
public final class TmuxAdapter: TmuxManagerPort, @unchecked Sendable {
    private let tmuxPath: String

    public init(tmuxPath: String? = nil) {
        self.tmuxPath = tmuxPath ?? ShellCommand.findExecutable("tmux") ?? "tmux"
    }

    public func listSessions() async throws -> [TmuxSession] {
        let result = try await ShellCommand.run(
            tmuxPath,
            arguments: ["list-sessions", "-F", "#{session_name}\t#{session_path}\t#{session_attached}"]
        )

        // tmux returns exit code 1 with "no server running" when there are no sessions
        guard result.succeeded, !result.stdout.isEmpty else { return [] }

        return result.stdout.components(separatedBy: "\n").compactMap { line -> TmuxSession? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { return nil }
            return TmuxSession(
                name: parts[0],
                path: parts[1],
                attached: parts[2] == "1"
            )
        }
    }

    public func createSession(name: String, path: String, command: String?) async throws {
        // If a session with this name already exists, reuse it.
        // This prevents killing an active extra terminal whose SwiftTerm view
        // has already attached via the retry loop — killing it would clear the
        // terminal contents (the user sees a blank shell).
        let check = try await ShellCommand.run(tmuxPath, arguments: ["has-session", "-t", name])
        if check.succeeded {
            return
        }

        // Create session with a shell (no command argument).
        // Then send the command via send-keys so the shell stays alive
        // if the command exits — the user can see errors and take charge.
        let args = ["new-session", "-d", "-s", name, "-c", path]
        let result = try await ShellCommand.run(tmuxPath, arguments: args)
        if !result.succeeded {
            throw TmuxError.createFailed(name: name, message: result.stderr)
        }

        if let command, !command.isEmpty {
            let sendResult = try await ShellCommand.run(
                tmuxPath,
                arguments: ["send-keys", "-t", name, command, "Enter"]
            )
            if !sendResult.succeeded {
                KanbanCodeLog.error("tmux", "send-keys failed for \(name): \(sendResult.stderr)")
            }
        }
    }

    public func killSession(name: String) async throws {
        let result = try await ShellCommand.run(
            tmuxPath,
            arguments: ["kill-session", "-t", name]
        )
        if !result.succeeded {
            throw TmuxError.killFailed(name: name, message: result.stderr)
        }
    }

    public func findSessionForWorktree(
        sessions: [TmuxSession],
        worktreePath: String,
        branch: String?
    ) -> TmuxSession? {
        // Priority 1: Exact path match
        if let match = sessions.first(where: { $0.path == worktreePath }) {
            return match
        }

        // Priority 2: Session name matches directory name
        let dirName = (worktreePath as NSString).lastPathComponent
        if let match = sessions.first(where: { $0.name == dirName }) {
            return match
        }

        // Priority 3: Branch name match
        if let branch {
            if let match = sessions.first(where: { $0.name == branch }) {
                return match
            }

            // Priority 4: Branch with slashes replaced by dashes
            let dashBranch = branch.replacingOccurrences(of: "/", with: "-")
            if dashBranch != branch {
                if let match = sessions.first(where: { $0.name == dashBranch }) {
                    return match
                }
            }
        }

        return nil
    }

    public func isAvailable() async -> Bool {
        ShellCommand.findExecutable("tmux") != nil
    }
}

public enum TmuxError: Error, LocalizedError {
    case createFailed(name: String, message: String)
    case killFailed(name: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let name, let message): "Failed to create tmux session '\(name)': \(message)"
        case .killFailed(let name, let message): "Failed to kill tmux session '\(name)': \(message)"
        }
    }
}
