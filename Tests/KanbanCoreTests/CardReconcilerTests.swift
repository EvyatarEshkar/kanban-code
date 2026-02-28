import Testing
import Foundation
@testable import KanbanCore

@Suite("CardReconciler")
struct CardReconcilerTests {

    // MARK: - Session matching

    @Test("New session creates a discovered card")
    func newSessionCreatesCard() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", messageCount: 1, modifiedTime: .now)]
        )
        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].sessionLink?.sessionId == "s1")
        #expect(result[0].source == .discovered)
        #expect(result[0].column == .allSessions)
    }

    @Test("Existing card matched by sessionId is updated, not duplicated")
    func matchBySessionId() {
        let existing = [
            Link(
                column: .inProgress,
                lastActivity: Date.now.addingTimeInterval(-3600),
                sessionLink: SessionLink(sessionId: "s1", sessionPath: "/old/path.jsonl")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", messageCount: 5, modifiedTime: .now, jsonlPath: "/new/path.jsonl")]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].id == existing[0].id) // Same card
        #expect(result[0].sessionLink?.sessionPath == "/new/path.jsonl") // Updated path
    }

    @Test("Session matched to pending card by worktree branch")
    func matchByWorktreeBranch() {
        let existing = [
            Link(
                name: "#42: Fix login",
                projectPath: "/project",
                column: .backlog,
                source: .githubIssue,
                worktreeLink: WorktreeLink(path: "/worktree", branch: "fix-login"),
                issueLink: IssueLink(number: 42)
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", projectPath: "/project", gitBranch: "fix-login", messageCount: 1, modifiedTime: .now)]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].id == existing[0].id) // Reused existing card
        #expect(result[0].sessionLink?.sessionId == "s1") // Session linked
        #expect(result[0].issueLink?.number == 42) // Issue still there
        #expect(result[0].name == "#42: Fix login") // Name preserved
    }

    @Test("Session matched to pending card by tmux + project path")
    func matchByTmuxAndProject() {
        let existing = [
            Link(
                name: "My task",
                projectPath: "/project",
                column: .inProgress,
                source: .manual,
                tmuxLink: TmuxLink(sessionName: "my-task")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", projectPath: "/project", messageCount: 1, modifiedTime: .now)]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].id == existing[0].id)
        #expect(result[0].sessionLink?.sessionId == "s1")
        #expect(result[0].name == "My task")
    }

    // MARK: - Triplication bug

    @Test("Manual task + start + session discovery = 1 card (not 3!)")
    func noTriplication() {
        // Step 1: User creates manual task and clicks Start Immediately
        // This creates a card with tmuxLink + worktreeLink, no sessionLink yet
        let manualCard = Link(
            name: "Fix auth bug",
            projectPath: "/project",
            column: .inProgress,
            source: .manual,
            promptBody: "Fix the authentication bug in the login flow",
            tmuxLink: TmuxLink(sessionName: "fix-auth"),
            worktreeLink: WorktreeLink(path: "/project/.claude/worktrees/fix-auth", branch: "fix-auth")
        )

        // Step 2: Session discovery finds the Claude session running in the worktree
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(
                    id: "claude-uuid-123",
                    projectPath: "/project",
                    gitBranch: "fix-auth",
                    messageCount: 10,
                    modifiedTime: .now,
                    jsonlPath: "/path/to/session.jsonl"
                )
            ],
            tmuxSessions: [
                TmuxSession(name: "fix-auth", path: "/project/.claude/worktrees/fix-auth", attached: false)
            ]
        )

        let result = CardReconciler.reconcile(existing: [manualCard], snapshot: snapshot)

        // Should be exactly 1 card — the manual card, now with a sessionLink attached
        #expect(result.count == 1)
        #expect(result[0].id == manualCard.id)
        #expect(result[0].name == "Fix auth bug")
        #expect(result[0].source == .manual)
        #expect(result[0].sessionLink?.sessionId == "claude-uuid-123")
        #expect(result[0].tmuxLink?.sessionName == "fix-auth")
        #expect(result[0].worktreeLink?.branch == "fix-auth")
    }

    @Test("GitHub issue + start work = 1 card (issue gains sessionLink)")
    func issueGainsSession() {
        let issueCard = Link(
            name: "#123: Fix the bug",
            projectPath: "/project",
            column: .backlog,
            source: .githubIssue,
            tmuxLink: TmuxLink(sessionName: "issue-123"),
            worktreeLink: WorktreeLink(path: "/worktree", branch: "issue-123"),
            issueLink: IssueLink(number: 123, body: "Fix the bug")
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "s1", projectPath: "/project", gitBranch: "issue-123", messageCount: 5, modifiedTime: .now)
            ],
            tmuxSessions: [
                TmuxSession(name: "issue-123", path: "/worktree", attached: false)
            ]
        )

        let result = CardReconciler.reconcile(existing: [issueCard], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].id == issueCard.id)
        #expect(result[0].sessionLink?.sessionId == "s1")
        #expect(result[0].issueLink?.number == 123)
    }

    // MARK: - Worktree handling

    @Test("Orphan worktree creates new card with just worktreeLink")
    func orphanWorktree() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: [
                "/project": [
                    Worktree(path: "/project/.worktrees/fix-auth", branch: "fix-auth", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].worktreeLink?.branch == "fix-auth")
        #expect(result[0].worktreeLink?.path == "/project/.worktrees/fix-auth")
        #expect(result[0].sessionLink == nil)
        #expect(result[0].source == .discovered)
    }

    @Test("Bare worktree is skipped")
    func bareWorktreeSkipped() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: [
                "/project": [
                    Worktree(path: "/project", branch: "main", isBare: true)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        #expect(result.isEmpty)
    }

    @Test("Main branch worktree is skipped")
    func mainBranchSkipped() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: [
                "/project": [
                    Worktree(path: "/project/.worktrees/main", branch: "main", isBare: false),
                    Worktree(path: "/project/.worktrees/master", branch: "master", isBare: false),
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        #expect(result.isEmpty)
    }

    @Test("Existing card's worktree path is updated")
    func worktreePathUpdated() {
        let existing = [
            Link(
                column: .inProgress,
                sessionLink: SessionLink(sessionId: "s1"),
                worktreeLink: WorktreeLink(path: "/old/path", branch: "feat-x")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", gitBranch: "feat-x", messageCount: 1, modifiedTime: .now)],
            worktrees: [
                "/project": [
                    Worktree(path: "/new/path", branch: "feat-x", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].worktreeLink?.path == "/new/path")
    }

    // MARK: - PR matching

    @Test("PR linked to card via branch")
    func prLinkedViaBranch() {
        let existing = [
            Link(
                column: .inProgress,
                sessionLink: SessionLink(sessionId: "s1"),
                worktreeLink: WorktreeLink(path: "/wt", branch: "feat-login")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", gitBranch: "feat-login", messageCount: 1, modifiedTime: .now)],
            pullRequests: [
                "feat-login": PullRequest(number: 42, title: "Add login", state: "open", url: "https://github.com/test/pr/42", headRefName: "feat-login")
            ]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].prLink?.number == 42)
    }

    // MARK: - Dead link cleanup

    @Test("Dead tmux link is cleared")
    func deadTmuxCleared() {
        let existing = [
            Link(
                column: .inProgress,
                sessionLink: SessionLink(sessionId: "s1"),
                tmuxLink: TmuxLink(sessionName: "dead-session")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", messageCount: 1, modifiedTime: .now)],
            tmuxSessions: [] // No tmux sessions alive
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].tmuxLink == nil) // Cleared
        #expect(result[0].sessionLink?.sessionId == "s1") // Session still there
    }

    @Test("Dead worktree link is cleared when worktrees were scanned")
    func deadWorktreeCleared() {
        let existing = [
            Link(
                column: .done,
                worktreeLink: WorktreeLink(path: "/deleted/worktree", branch: "old-branch")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: [
                "/project": [
                    // Only a bare worktree exists (won't create orphan card)
                    Worktree(path: "/project", branch: "main", isBare: true)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].worktreeLink == nil) // Cleared
    }

    @Test("Manual tmux override is preserved even when tmux is dead")
    func manualTmuxOverridePreserved() {
        var link = Link(
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "my-session")
        )
        link.manualOverrides.tmuxSession = true

        let snapshot = CardReconciler.DiscoverySnapshot(
            tmuxSessions: [] // Dead
        )

        let result = CardReconciler.reconcile(existing: [link], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].tmuxLink?.sessionName == "my-session") // Preserved
    }

    // MARK: - Multiple sessions

    @Test("Multiple sessions each get their own card")
    func multipleSessions() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "s1", messageCount: 1, modifiedTime: .now),
                Session(id: "s2", messageCount: 1, modifiedTime: .now),
                Session(id: "s3", messageCount: 1, modifiedTime: .now),
            ]
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        #expect(result.count == 3)
        let sessionIds = Set(result.compactMap(\.sessionLink?.sessionId))
        #expect(sessionIds == ["s1", "s2", "s3"])
    }

    @Test("Existing cards without matching sessions are preserved")
    func existingCardsPreserved() {
        let existing = [
            Link(name: "Manual task", column: .backlog, source: .manual),
            Link(name: "Issue", column: .backlog, source: .githubIssue, issueLink: IssueLink(number: 42)),
        ]
        let snapshot = CardReconciler.DiscoverySnapshot() // No sessions

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 2)
        #expect(result.contains(where: { $0.name == "Manual task" }))
        #expect(result.contains(where: { $0.name == "Issue" }))
    }

    @Test("No double reconciliation — running twice produces same result")
    func idempotent() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "s1", projectPath: "/p", gitBranch: "feat-x", messageCount: 5, modifiedTime: .now)
            ],
            worktrees: [
                "/p": [Worktree(path: "/p/.wt/feat-x", branch: "feat-x", isBare: false)]
            ],
            pullRequests: [
                "feat-x": PullRequest(number: 1, title: "PR", state: "open", url: "url", headRefName: "feat-x")
            ]
        )

        let first = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        let second = CardReconciler.reconcile(existing: first, snapshot: snapshot)

        #expect(first.count == second.count)
        // Same card IDs
        #expect(Set(first.map(\.id)) == Set(second.map(\.id)))
    }

    @Test("Project path filled from session when card has none")
    func projectPathFilledFromSession() {
        // Card has tmuxLink + matching project path context (same project)
        let existing = [
            Link(
                projectPath: "/my/project",
                column: .backlog,
                source: .manual,
                tmuxLink: TmuxLink(sessionName: "task-1"),
                worktreeLink: WorktreeLink(path: "/wt", branch: "task-1")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "s1", projectPath: "/my/project", gitBranch: "task-1", messageCount: 1, modifiedTime: .now)
            ]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].sessionLink?.sessionId == "s1")
        #expect(result[0].projectPath == "/my/project")
    }
}
