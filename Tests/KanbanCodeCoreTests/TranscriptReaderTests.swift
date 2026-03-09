import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("TranscriptReader")
struct TranscriptReaderTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-transcript-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Reads user and assistant turns")
    func readTurns() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello"},"cwd":"/test","timestamp":"2026-01-01T00:00:00Z"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Hi there! How can I help?"}]}}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Fix the bug"},"cwd":"/test"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 3)
        #expect(turns[0].role == "user")
        #expect(turns[0].textPreview == "Hello")
        #expect(turns[0].timestamp == "2026-01-01T00:00:00Z")
        #expect(turns[1].role == "assistant")
        #expect(turns[1].textPreview == "Hi there! How can I help?")
        #expect(turns[2].role == "user")
        #expect(turns[2].textPreview == "Fix the bug")
    }

    @Test("Skips non-message lines")
    func skipsNonMessages() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"file-history-snapshot","data":"lots of data"}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello"},"cwd":"/test"}"#,
            #"{"type":"progress","data":"loading"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        #expect(turns[0].textPreview == "Hello")
    }

    @Test("Returns empty for nonexistent file")
    func nonexistent() async throws {
        let turns = try await TranscriptReader.readTurns(from: "/nonexistent/path.jsonl")
        #expect(turns.isEmpty)
    }

    @Test("Handles tool-use-only assistant responses")
    func toolUseOnly() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        #expect(turns[0].textPreview == "[tool: Read]")
    }

    @Test("Line numbers are correct")
    func lineNumbers() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"file-history-snapshot","data":"stuff"}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Hello"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Hi"}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns[0].lineNumber == 2) // first message line is line 2
        #expect(turns[1].lineNumber == 3)
    }

    // MARK: - Rich content block tests

    @Test("Parses Bash tool_use blocks")
    func bashToolUse() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la","description":"List files"}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        #expect(turns[0].contentBlocks.count == 1)
        let block = turns[0].contentBlocks[0]
        if case .toolUse(let name, let input) = block.kind {
            #expect(name == "Bash")
            #expect(input["command"] == "ls -la")
            #expect(input["description"] == "List files")
        } else {
            Issue.record("Expected toolUse block")
        }
        #expect(block.text == "Bash(List files)")
    }

    @Test("Parses Read tool_use blocks")
    func readToolUse() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/Users/test/src/main.swift"}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        let block = turns[0].contentBlocks[0]
        if case .toolUse(let name, let input) = block.kind {
            #expect(name == "Read")
            #expect(input["file_path"] == "/Users/test/src/main.swift")
        } else {
            Issue.record("Expected toolUse block")
        }
        #expect(block.text.contains("main.swift"))
    }

    @Test("Parses Edit tool_use blocks")
    func editToolUse() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/src/app.swift","old_string":"foo","new_string":"bar"}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        let block = turns[0].contentBlocks[0]
        if case .toolUse(let name, let input) = block.kind {
            #expect(name == "Edit")
            #expect(input["file_path"] == "/src/app.swift")
        } else {
            Issue.record("Expected toolUse block")
        }
        #expect(block.text.contains("app.swift"))
    }

    @Test("Parses multiple content blocks in one message")
    func multipleBlocks() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Let me read the file."},{"type":"tool_use","name":"Read","input":{"file_path":"/test.swift"}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns[0].contentBlocks.count == 2)
        if case .text = turns[0].contentBlocks[0].kind {
            #expect(turns[0].contentBlocks[0].text == "Let me read the file.")
        } else {
            Issue.record("Expected text block")
        }
        if case .toolUse(let name, _) = turns[0].contentBlocks[1].kind {
            #expect(name == "Read")
        } else {
            Issue.record("Expected toolUse block")
        }
    }

    @Test("Parses tool_result blocks in user messages")
    func toolResultBlocks() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_123","content":"file contents here\nline 2\nline 3"}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        #expect(turns[0].contentBlocks.count == 1)
        if case .toolResult = turns[0].contentBlocks[0].kind {
            #expect(turns[0].contentBlocks[0].text == "Result (3 lines)")
        } else {
            Issue.record("Expected toolResult block")
        }
    }

    @Test("Mixed text and tool_use — textPreview only from text blocks")
    func textPreviewFromTextOnly() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"I will fix this."},{"type":"tool_use","name":"Edit","input":{"file_path":"/test.swift"}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns[0].textPreview == "I will fix this.")
        // textPreview should NOT contain "Edit" tool name
        #expect(!turns[0].textPreview.contains("Edit"))
    }

    @Test("Parses thinking blocks")
    func thinkingBlocks() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"thinking","thinking":"Let me analyze this..."},{"type":"text","text":"Here is my answer."}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns[0].contentBlocks.count == 2)
        if case .thinking = turns[0].contentBlocks[0].kind {
            #expect(turns[0].contentBlocks[0].text == "Let me analyze this...")
        } else {
            Issue.record("Expected thinking block")
        }
        #expect(turns[0].textPreview == "Here is my answer.")
    }

    @Test("Grep tool input extraction")
    func grepToolInput() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"TODO","path":"/Users/test/src/"}}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        let block = turns[0].contentBlocks[0]
        if case .toolUse(let name, let input) = block.kind {
            #expect(name == "Grep")
            #expect(input["pattern"] == "TODO")
            #expect(input["path"] == "/Users/test/src/")
        } else {
            Issue.record("Expected toolUse block")
        }
        #expect(block.text.contains("\"TODO\""))
    }

    @Test("Existing contentBlocks field defaults to empty for backward compat")
    func backwardCompat() async throws {
        let turn = ConversationTurn(index: 0, lineNumber: 1, role: "user", textPreview: "hello")
        #expect(turn.contentBlocks.isEmpty)
    }

    @Test("Path shortening for display")
    func pathShortening() {
        let short = TranscriptReader.shortenPath("/Users/test/Projects/remote/kanban/Sources/Kanban/App.swift")
        #expect(short == ".../Sources/Kanban/App.swift")

        let alreadyShort = TranscriptReader.shortenPath("/src/main.swift")
        #expect(alreadyShort == "/src/main.swift")
    }

    // MARK: - Metadata filtering

    @Test("Hides caveat messages from history")
    func hidesCaveatFromHistory() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","isMeta":true,"sessionId":"s1","message":{"content":"<local-command-caveat>wrapped</local-command-caveat>"},"cwd":"/test"}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Real prompt"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"OK"}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        // Caveat message should be completely hidden — only 2 turns
        #expect(turns.count == 2)
        #expect(turns[0].role == "user")
        #expect(turns[0].textPreview == "Real prompt")
        #expect(turns[1].role == "assistant")
    }

    @Test("Shows /clear command cleanly in history")
    func showsCommandCleanly() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"<command-name>/clear</command-name><command-message></command-message><command-args></command-args>"},"cwd":"/test"}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Next prompt"},"cwd":"/test"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 2)
        #expect(turns[0].textPreview == "/clear")
        #expect(turns[1].textPreview == "Next prompt")
    }

    @Test("Shows command stdout as assistant-style turn in history")
    func showsStdoutAsAssistant() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"<local-command-stdout>file contents here</local-command-stdout>"},"cwd":"/test"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        #expect(turns.count == 1)
        #expect(turns[0].role == "assistant")
        #expect(turns[0].textPreview == "file contents here")
    }
}
