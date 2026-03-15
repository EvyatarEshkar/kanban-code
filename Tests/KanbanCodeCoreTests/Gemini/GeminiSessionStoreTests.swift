import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("GeminiSessionStore")
struct GeminiSessionStoreTests {

    // MARK: - Helpers

    private func writeTempSession(_ json: String) throws -> String {
        let path = "/tmp/kanban-test-gemini-store-\(UUID().uuidString).json"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func cleanup(_ paths: String...) {
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private let sampleSession = """
    {
        "sessionId": "store-test-1",
        "messages": [
            {
                "type": "user",
                "content": [{"text": "Fix the bug"}]
            },
            {
                "type": "gemini",
                "content": "I'll fix it.",
                "toolCalls": [
                    {
                        "name": "editFile",
                        "displayName": "Edit File",
                        "args": {"path": "src/main.ts"},
                        "result": "File edited successfully",
                        "status": "completed"
                    }
                ],
                "thoughts": [
                    {"text": "Need to find the bug first"}
                ]
            },
            {
                "type": "info",
                "content": "Checkpoint saved"
            },
            {
                "type": "user",
                "content": [{"text": "Now add tests"}]
            },
            {
                "type": "gemini",
                "content": "Adding tests now."
            }
        ]
    }
    """

    // MARK: - Read Transcript

    @Test("Reads transcript from session file")
    func readTranscript() async throws {
        let path = try writeTempSession(sampleSession)
        defer { cleanup(path) }

        let store = GeminiSessionStore()
        let turns = try await store.readTranscript(sessionPath: path)

        #expect(turns.count == 5)
    }

    @Test("Maps message types to roles correctly")
    func messageTypeMapping() async throws {
        let path = try writeTempSession(sampleSession)
        defer { cleanup(path) }

        let store = GeminiSessionStore()
        let turns = try await store.readTranscript(sessionPath: path)

        #expect(turns[0].role == "user")
        #expect(turns[1].role == "assistant")
        #expect(turns[2].role == "system")     // info
        #expect(turns[3].role == "user")
        #expect(turns[4].role == "assistant")
    }

    @Test("Extracts text content from user messages")
    func userTextContent() async throws {
        let path = try writeTempSession(sampleSession)
        defer { cleanup(path) }

        let store = GeminiSessionStore()
        let turns = try await store.readTranscript(sessionPath: path)

        #expect(turns[0].textPreview == "Fix the bug")
        #expect(turns[3].textPreview == "Now add tests")
    }

    @Test("Includes tool calls in content blocks")
    func toolCallBlocks() async throws {
        let path = try writeTempSession(sampleSession)
        defer { cleanup(path) }

        let store = GeminiSessionStore()
        let turns = try await store.readTranscript(sessionPath: path)

        let assistantTurn = turns[1]
        let toolBlocks = assistantTurn.contentBlocks.filter {
            if case .toolUse = $0.kind { return true }
            return false
        }
        #expect(toolBlocks.count == 1)
        if case .toolUse(let name, let input, _) = toolBlocks.first?.kind {
            #expect(name == "Edit File")
            #expect(input["path"] == "src/main.ts")
        }
    }

    @Test("Includes thinking blocks")
    func thinkingBlocks() async throws {
        let path = try writeTempSession(sampleSession)
        defer { cleanup(path) }

        let store = GeminiSessionStore()
        let turns = try await store.readTranscript(sessionPath: path)

        let assistantTurn = turns[1]
        let thinkBlocks = assistantTurn.contentBlocks.filter {
            if case .thinking = $0.kind { return true }
            return false
        }
        #expect(thinkBlocks.count == 1)
        #expect(thinkBlocks.first?.text == "Need to find the bug first")
    }

    @Test("Turn indices are sequential")
    func sequentialIndices() async throws {
        let path = try writeTempSession(sampleSession)
        defer { cleanup(path) }

        let store = GeminiSessionStore()
        let turns = try await store.readTranscript(sessionPath: path)

        for (i, turn) in turns.enumerated() {
            #expect(turn.index == i)
        }
    }

    @Test("Line numbers are 1-based")
    func oneBasedLineNumbers() async throws {
        let path = try writeTempSession(sampleSession)
        defer { cleanup(path) }

        let store = GeminiSessionStore()
        let turns = try await store.readTranscript(sessionPath: path)

        #expect(turns[0].lineNumber == 1)
        #expect(turns[1].lineNumber == 2)
        #expect(turns[2].lineNumber == 3)
    }

    @Test("Throws for non-existent file")
    func readMissingFile() async {
        let store = GeminiSessionStore()
        await #expect(throws: SessionStoreError.self) {
            _ = try await store.readTranscript(sessionPath: "/nonexistent/session.json")
        }
    }

    @Test("Returns empty for unparseable file")
    func unparseableFile() async throws {
        let path = try writeTempSession("not json")
        defer { cleanup(path) }

        let store = GeminiSessionStore()
        await #expect(throws: Error.self) {
            _ = try await store.readTranscript(sessionPath: path)
        }
    }

    // MARK: - Fork Session

    @Test("Fork creates new file with new sessionId")
    func forkCreatesNewFile() async throws {
        let path = try writeTempSession(sampleSession)
        defer { cleanup(path) }

        let store = GeminiSessionStore()
        let newId = try await store.forkSession(sessionPath: path)

        #expect(!newId.isEmpty)
        #expect(newId != "store-test-1")

        // Verify new file exists
        let dir = (path as NSString).deletingLastPathComponent
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
        let forkedFiles = files.filter { $0.contains("forked") && $0.contains(newId) }
        #expect(forkedFiles.count == 1)

        // Cleanup forked file
        if let forked = forkedFiles.first {
            cleanup((dir as NSString).appendingPathComponent(forked))
        }
    }

    @Test("Forked session has replaced sessionId in content")
    func forkReplacesSessionId() async throws {
        let path = try writeTempSession(sampleSession)
        defer { cleanup(path) }

        let store = GeminiSessionStore()
        let newId = try await store.forkSession(sessionPath: path)

        let dir = (path as NSString).deletingLastPathComponent
        let newFileName = "session-forked-\(newId).json"
        let newPath = (dir as NSString).appendingPathComponent(newFileName)
        defer { cleanup(newPath) }

        let content = try String(contentsOfFile: newPath, encoding: .utf8)
        #expect(content.contains(newId))
        #expect(!content.contains("store-test-1"))
    }

    @Test("Fork to custom directory")
    func forkToCustomDirectory() async throws {
        let path = try writeTempSession(sampleSession)
        let targetDir = "/tmp/kanban-test-fork-target-\(UUID().uuidString)"
        defer {
            cleanup(path)
            cleanup(targetDir)
        }

        let store = GeminiSessionStore()
        let newId = try await store.forkSession(sessionPath: path, targetDirectory: targetDir)

        let newPath = (targetDir as NSString).appendingPathComponent("session-forked-\(newId).json")
        #expect(FileManager.default.fileExists(atPath: newPath))
    }

    @Test("Fork throws for non-existent file")
    func forkMissingFile() async {
        let store = GeminiSessionStore()
        await #expect(throws: SessionStoreError.self) {
            _ = try await store.forkSession(sessionPath: "/nonexistent/session.json")
        }
    }

    // MARK: - Truncate Session

    @Test("Truncate keeps only first N messages")
    func truncateKeepsFirstN() async throws {
        let path = try writeTempSession(sampleSession)
        defer {
            cleanup(path)
            cleanup(path + ".bkp")
        }

        let store = GeminiSessionStore()
        let turns = try await store.readTranscript(sessionPath: path)

        // Truncate after turn at lineNumber 2 (keep messages 0 and 1)
        try await store.truncateSession(sessionPath: path, afterTurn: turns[1])

        // Re-read and verify
        let truncated = try await store.readTranscript(sessionPath: path)
        #expect(truncated.count == 2)
        #expect(truncated[0].role == "user")
        #expect(truncated[1].role == "assistant")
    }

    @Test("Truncate creates backup file")
    func truncateCreatesBackup() async throws {
        let path = try writeTempSession(sampleSession)
        let backupPath = path + ".bkp"
        defer {
            cleanup(path)
            cleanup(backupPath)
        }

        let store = GeminiSessionStore()
        let turns = try await store.readTranscript(sessionPath: path)
        try await store.truncateSession(sessionPath: path, afterTurn: turns[0])

        #expect(FileManager.default.fileExists(atPath: backupPath))
    }

    @Test("Truncate throws for non-existent file")
    func truncateMissingFile() async {
        let store = GeminiSessionStore()
        let turn = ConversationTurn(index: 0, lineNumber: 1, role: "user", textPreview: "test")
        await #expect(throws: SessionStoreError.self) {
            try await store.truncateSession(sessionPath: "/nonexistent/session.json", afterTurn: turn)
        }
    }

    // MARK: - Search

    @Test("Search finds matching sessions")
    func searchFindsMatches() async throws {
        let session1 = """
        {
            "sessionId": "search-1",
            "messages": [
                {"type": "user", "content": [{"text": "Fix the login validation bug"}]},
                {"type": "gemini", "content": "I'll fix the validation."}
            ]
        }
        """
        let session2 = """
        {
            "sessionId": "search-2",
            "messages": [
                {"type": "user", "content": [{"text": "Add dark mode support"}]},
                {"type": "gemini", "content": "Adding dark mode."}
            ]
        }
        """

        let path1 = try writeTempSession(session1)
        let path2 = try writeTempSession(session2)
        defer {
            cleanup(path1)
            cleanup(path2)
        }

        let store = GeminiSessionStore()
        let results = try await store.searchSessions(query: "login validation", paths: [path1, path2])

        #expect(!results.isEmpty)
        // The login session should rank higher
        #expect(results[0].sessionPath == path1)
    }

    @Test("Search returns empty for no matches")
    func searchNoMatches() async throws {
        let session = """
        {
            "sessionId": "search-nomatch",
            "messages": [
                {"type": "user", "content": [{"text": "Hello world"}]},
                {"type": "gemini", "content": "Hi"}
            ]
        }
        """
        let path = try writeTempSession(session)
        defer { cleanup(path) }

        let store = GeminiSessionStore()
        let results = try await store.searchSessions(query: "zzzznonexistentterm", paths: [path])
        #expect(results.isEmpty)
    }

    @Test("Search handles empty query")
    func searchEmptyQuery() async throws {
        let path = try writeTempSession(sampleSession)
        defer { cleanup(path) }

        let store = GeminiSessionStore()
        let results = try await store.searchSessions(query: "", paths: [path])
        #expect(results.isEmpty)
    }
}
