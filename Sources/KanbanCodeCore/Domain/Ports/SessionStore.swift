import Foundation

/// Port for reading and modifying Claude Code session files.
public protocol SessionStore: Sendable {
    /// Read conversation turns from a session file.
    func readTranscript(sessionPath: String) async throws -> [ConversationTurn]

    /// Fork (duplicate) a session, returning the new session ID.
    /// If targetDirectory is provided, the fork is placed there instead of the original directory.
    func forkSession(sessionPath: String, targetDirectory: String?) async throws -> String

    /// Truncate a session to a given turn (checkpoint). Creates a .bkp backup.
    func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws

    /// Full-text search across all session files.
    func searchSessions(query: String, paths: [String]) async throws -> [SearchResult]
}

extension SessionStore {
    public func forkSession(sessionPath: String) async throws -> String {
        try await forkSession(sessionPath: sessionPath, targetDirectory: nil)
    }
}

/// A search result from full-text session search.
public struct SearchResult: Sendable {
    public let sessionPath: String
    public let score: Double
    public let snippet: String

    public init(sessionPath: String, score: Double, snippet: String) {
        self.sessionPath = sessionPath
        self.score = score
        self.snippet = snippet
    }
}
