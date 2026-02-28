import Testing
import Foundation
@testable import KanbanCore

@Suite("Card Lifecycle")
struct CardLifecycleTests {

    @Test("Active session moves to inProgress")
    func activeToInProgress() {
        var link = Link(column: .allSessions, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking, pr: nil, hasWorktree: false)
        #expect(link.column == .inProgress)
    }

    @Test("Stop with no follow-up moves to requiresAttention")
    func stopToRequiresAttention() {
        var link = Link(column: .inProgress, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .needsAttention, pr: nil, hasWorktree: false)
        #expect(link.column == .requiresAttention)
    }

    @Test("PR exists + idle → inReview")
    func prIdleToInReview() {
        var link = Link(
            column: .inProgress,
            sessionLink: SessionLink(sessionId: "s1"),
            worktreeLink: WorktreeLink(path: "", branch: "feature-x")
        )
        let pr = PullRequest(number: 42, title: "Add feature", state: "open", url: "https://github.com/test/pr/42", headRefName: "feature-x")
        UpdateCardColumn.update(link: &link, activityState: .idleWaiting, pr: pr, hasWorktree: true)
        #expect(link.column == .inReview)
    }

    @Test("PR merged → done")
    func prMergedToDone() {
        var link = Link(column: .inReview, sessionLink: SessionLink(sessionId: "s1"))
        let pr = PullRequest(number: 42, title: "Add feature", state: "merged", url: "https://github.com/test/pr/42", headRefName: "feature-x")
        UpdateCardColumn.update(link: &link, activityState: .ended, pr: pr, hasWorktree: false)
        #expect(link.column == .done)
    }

    @Test("Manual override is respected even with conflicting state")
    func manualOverride() {
        var link = Link(column: .done, sessionLink: SessionLink(sessionId: "s1"))
        link.manualOverrides.column = true
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking, pr: nil, hasWorktree: true)
        #expect(link.column == .done)
    }

    @Test("Ended session with worktree → requiresAttention")
    func endedWithWorktree() {
        var link = Link(
            column: .inProgress,
            sessionLink: SessionLink(sessionId: "s1"),
            worktreeLink: WorktreeLink(path: "", branch: "feature-x")
        )
        UpdateCardColumn.update(link: &link, activityState: .ended, pr: nil, hasWorktree: true)
        #expect(link.column == .requiresAttention)
    }

    @Test("Stale session → allSessions")
    func staleToAllSessions() {
        var link = Link(column: .inProgress, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .stale, pr: nil, hasWorktree: false)
        #expect(link.column == .allSessions)
    }

    @Test("Batch update processes all links")
    func batchUpdate() {
        var links = [
            Link(column: .allSessions, sessionLink: SessionLink(sessionId: "s1")),
            Link(column: .allSessions, sessionLink: SessionLink(sessionId: "s2")),
        ]
        let states: [String: ActivityState] = [
            "s1": .activelyWorking,
            "s2": .needsAttention,
        ]
        UpdateCardColumn.updateAll(links: &links, activityStates: states, prs: [:], worktreeBranches: [])
        #expect(links[0].column == .inProgress)
        #expect(links[1].column == .requiresAttention)
    }

    @Test("Column doesn't change when state results in same column")
    func noUnnecessaryUpdate() {
        var link = Link(column: .inProgress, sessionLink: SessionLink(sessionId: "s1"))
        let originalUpdatedAt = link.updatedAt
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking, pr: nil, hasWorktree: false)
        // Column is already inProgress, so updatedAt should not change
        #expect(link.updatedAt == originalUpdatedAt)
    }
}
