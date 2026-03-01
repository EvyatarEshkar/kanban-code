import Foundation

/// Port for launching and resuming AI CLI sessions.
public protocol SessionLauncher: Sendable {
    /// Launch a new session with a prompt in a project directory.
    func launch(
        projectPath: String,
        prompt: String,
        worktreeName: String?,
        shellOverride: String?,
        extraEnv: [String: String],
        commandOverride: String?
    ) async throws -> String // returns session ID or tmux session name

    /// Resume an existing session by its ID.
    func resume(
        sessionId: String,
        projectPath: String,
        shellOverride: String?,
        extraEnv: [String: String]
    ) async throws -> String // returns tmux session name
}

/// Default parameter extension so callers that don't need extraEnv aren't broken.
extension SessionLauncher {
    public func launch(
        projectPath: String,
        prompt: String,
        worktreeName: String?,
        shellOverride: String?
    ) async throws -> String {
        try await launch(
            projectPath: projectPath,
            prompt: prompt,
            worktreeName: worktreeName,
            shellOverride: shellOverride,
            extraEnv: [:],
            commandOverride: nil
        )
    }

    public func resume(
        sessionId: String,
        projectPath: String,
        shellOverride: String?
    ) async throws -> String {
        try await resume(
            sessionId: sessionId,
            projectPath: projectPath,
            shellOverride: shellOverride,
            extraEnv: [:]
        )
    }
}
