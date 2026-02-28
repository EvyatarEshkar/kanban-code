import Testing
import Foundation
@testable import KanbanCore

@Suite("CoordinationStore")
struct CoordinationStoreTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Empty file returns empty links")
    func emptyFile() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)
        let links = try await store.readLinks()
        #expect(links.isEmpty)
    }

    @Test("Write and read round-trip")
    func roundTrip() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(
            name: "Test session",
            projectPath: "/test/project",
            column: .inProgress,
            sessionLink: SessionLink(sessionId: "abc-123")
        )
        try await store.writeLinks([link])

        let read = try await store.readLinks()
        #expect(read.count == 1)
        #expect(read[0].sessionId == "abc-123")
        #expect(read[0].column == .inProgress)
        #expect(read[0].name == "Test session")
    }

    @Test("Upsert creates new link")
    func upsertNew() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        let link = Link(column: .backlog, sessionLink: SessionLink(sessionId: "new-1"))
        try await store.upsertLink(link)

        let links = try await store.readLinks()
        #expect(links.count == 1)
        #expect(links[0].sessionId == "new-1")
    }

    @Test("Upsert updates existing link")
    func upsertExisting() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        var link = Link(name: "Original", column: .backlog, sessionLink: SessionLink(sessionId: "update-1"))
        try await store.upsertLink(link)

        link.name = "Updated"
        link.column = .inProgress
        try await store.upsertLink(link)

        let links = try await store.readLinks()
        #expect(links.count == 1)
        #expect(links[0].name == "Updated")
        #expect(links[0].column == .inProgress)
    }

    @Test("Remove link by session ID")
    func removeLink() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        try await store.writeLinks([
            Link(column: .backlog, sessionLink: SessionLink(sessionId: "a")),
            Link(column: .inProgress, sessionLink: SessionLink(sessionId: "b")),
        ])

        try await store.removeLink(sessionId: "a")
        let links = try await store.readLinks()
        #expect(links.count == 1)
        #expect(links[0].sessionId == "b")
    }

    @Test("Corrupted file returns empty and creates backup")
    func corruptionRecovery() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        // Write garbage
        let filePath = (dir as NSString).appendingPathComponent("links.json")
        try "not valid json {{{{".write(toFile: filePath, atomically: true, encoding: .utf8)

        let links = try await store.readLinks()
        #expect(links.isEmpty)

        // Backup should exist
        let backupPath = filePath + ".bkp"
        #expect(FileManager.default.fileExists(atPath: backupPath))
    }

    @Test("File is human-readable JSON")
    func humanReadable() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        try await store.writeLinks([Link(name: "Test", column: .done, sessionLink: SessionLink(sessionId: "pretty"))])

        let filePath = (dir as NSString).appendingPathComponent("links.json")
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(content.contains("\"pretty\""))
        #expect(content.contains("\n")) // pretty-printed
    }

    @Test("Update link with closure")
    func updateLink() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = CoordinationStore(basePath: dir)

        try await store.upsertLink(Link(column: .backlog, sessionLink: SessionLink(sessionId: "upd-1")))

        try await store.updateLink(sessionId: "upd-1") { link in
            link.column = .inProgress
            link.tmuxLink = TmuxLink(sessionName: "feat-login")
        }

        let link = try await store.linkForSession("upd-1")
        #expect(link?.column == .inProgress)
        #expect(link?.tmuxSession == "feat-login")
    }

    @Test("Backward-compat: old flat JSON format is decoded correctly")
    func backwardCompatDecoding() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Write old-format JSON directly
        let filePath = (dir as NSString).appendingPathComponent("links.json")
        let oldJson = """
        {
          "links": [
            {
              "id": "old-uuid",
              "sessionId": "claude-session-1",
              "sessionPath": "/path/to/session.jsonl",
              "worktreePath": "/path/to/worktree",
              "worktreeBranch": "feat/login",
              "tmuxSession": "feat-login",
              "githubIssue": 123,
              "githubPR": 456,
              "projectPath": "/test/project",
              "column": "in_progress",
              "name": "Test session",
              "createdAt": "2026-02-28T10:00:00Z",
              "updatedAt": "2026-02-28T10:30:00Z",
              "manualOverrides": {},
              "manuallyArchived": false,
              "source": "discovered",
              "issueBody": "Fix the bug"
            }
          ]
        }
        """
        try oldJson.write(toFile: filePath, atomically: true, encoding: .utf8)

        let store = CoordinationStore(basePath: dir)
        let links = try await store.readLinks()

        #expect(links.count == 1)
        let link = links[0]
        #expect(link.id == "old-uuid")
        #expect(link.sessionLink?.sessionId == "claude-session-1")
        #expect(link.sessionLink?.sessionPath == "/path/to/session.jsonl")
        #expect(link.tmuxLink?.sessionName == "feat-login")
        #expect(link.worktreeLink?.path == "/path/to/worktree")
        #expect(link.worktreeLink?.branch == "feat/login")
        #expect(link.issueLink?.number == 123)
        #expect(link.issueLink?.body == "Fix the bug")
        #expect(link.prLink?.number == 456)

        // Backward-compat computed properties still work
        #expect(link.sessionId == "claude-session-1")
        #expect(link.tmuxSession == "feat-login")
        #expect(link.worktreePath == "/path/to/worktree")
        #expect(link.worktreeBranch == "feat/login")
        #expect(link.githubIssue == 123)
        #expect(link.githubPR == 456)
    }
}
