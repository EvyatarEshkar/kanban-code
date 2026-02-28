import Testing
import Foundation
@testable import KanbanCore

@Suite("AssignColumn")
struct AssignColumnTests {

    @Test("Manual column override is respected")
    func manualOverride() {
        var link = Link(column: .done, sessionLink: SessionLink(sessionId: "s1"))
        link.manualOverrides.column = true
        let col = AssignColumn.assign(link: link, activityState: .activelyWorking)
        #expect(col == .done)
    }

    @Test("Manually archived goes to allSessions")
    func manuallyArchived() {
        let link = Link(column: .inProgress, manuallyArchived: true, sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .activelyWorking)
        #expect(col == .allSessions)
    }

    @Test("PR merged → done")
    func prMerged() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, prMerged: true)
        #expect(col == .done)
    }

    @Test("PR exists + idle → inReview")
    func prExistsIdle() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting, hasPR: true)
        #expect(col == .inReview)
    }

    @Test("PR exists + actively working → inProgress (not inReview)")
    func prExistsActive() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .activelyWorking, hasPR: true)
        #expect(col == .inProgress)
    }

    @Test("Actively working → inProgress")
    func activelyWorking() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .activelyWorking)
        #expect(col == .inProgress)
    }

    @Test("Needs attention → requiresAttention")
    func needsAttention() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .needsAttention)
        #expect(col == .requiresAttention)
    }

    @Test("Idle with worktree → inProgress")
    func idleWithWorktree() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting, hasWorktree: true)
        #expect(col == .inProgress)
    }

    @Test("Idle without worktree, recent → requiresAttention")
    func idleNoWorktreeRecent() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-3600), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting)
        #expect(col == .requiresAttention)
    }

    @Test("Idle without worktree, old → allSessions")
    func idleNoWorktreeOld() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-90000), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting)
        #expect(col == .allSessions)
    }

    @Test("Ended with worktree → requiresAttention")
    func endedWithWorktree() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .ended, hasWorktree: true)
        #expect(col == .requiresAttention)
    }

    @Test("Stale + recent → requiresAttention (falls through to recency check)")
    func staleRecent() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-3600), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .stale)
        #expect(col == .requiresAttention)
    }

    @Test("Stale + old → allSessions")
    func staleOld() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-90000), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .stale)
        #expect(col == .allSessions)
    }

    @Test("Ended without worktree, recent → requiresAttention")
    func endedNoWorktreeRecent() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-3600), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .ended)
        #expect(col == .requiresAttention)
    }

    @Test("Ended without worktree, old → allSessions")
    func endedNoWorktreeOld() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-90000), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .ended)
        #expect(col == .allSessions)
    }

    @Test("GitHub issue without session → backlog")
    func githubIssueBacklog() {
        let link = Link(source: .githubIssue)
        let col = AssignColumn.assign(link: link)
        #expect(col == .backlog)
    }

    @Test("Manual task without session → backlog")
    func manualTaskBacklog() {
        let link = Link(source: .manual)
        let col = AssignColumn.assign(link: link)
        #expect(col == .backlog)
    }

    @Test("No signals → allSessions")
    func noSignals() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link)
        #expect(col == .allSessions)
    }

    @Test("Recently active session (within 24h) → requiresAttention (not inProgress)")
    func recentlyActive() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-3600), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link)
        #expect(col == .requiresAttention)
    }

    @Test("Session active 2h ago → requiresAttention")
    func activeToday() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-7200), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link)
        #expect(col == .requiresAttention)
    }

    @Test("Only activelyWorking activity state → inProgress")
    func onlyActivelyWorkingIsInProgress() {
        // Without activityState, recent sessions should NOT be inProgress
        let recentLink = Link(lastActivity: Date.now.addingTimeInterval(-60), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: recentLink)
        #expect(col == .requiresAttention)

        // With activityState = activelyWorking → inProgress
        let col2 = AssignColumn.assign(link: recentLink, activityState: .activelyWorking)
        #expect(col2 == .inProgress)
    }

    @Test("Archive sets manuallyArchived → allSessions regardless of recency")
    func archivedRecentSession() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-300), manuallyArchived: true, sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link)
        #expect(col == .allSessions)
    }

    @Test("Session active 25h ago → allSessions (stale)")
    func staleSession() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-90000), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link)
        #expect(col == .allSessions)
    }
}
