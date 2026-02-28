import Foundation

/// Updates a link's column based on current activity state, PR status, and worktree existence.
/// Wraps AssignColumn with persistence via CoordinationStore.
public enum UpdateCardColumn {

    /// Update a single link's column assignment.
    public static func update(
        link: inout Link,
        activityState: ActivityState?,
        pr: PullRequest?,
        hasWorktree: Bool
    ) {
        let hasPR = pr != nil
        let prMerged = pr?.state == "merged"

        let newColumn = AssignColumn.assign(
            link: link,
            activityState: activityState,
            hasPR: hasPR,
            prMerged: prMerged,
            hasWorktree: hasWorktree
        )

        if newColumn != link.column {
            link.column = newColumn
            link.updatedAt = .now
        }
    }

    /// Batch update all links.
    public static func updateAll(
        links: inout [Link],
        activityStates: [String: ActivityState],
        prs: [String: PullRequest],
        worktreeBranches: Set<String>
    ) {
        for i in links.indices {
            guard let sessionId = links[i].sessionLink?.sessionId else { continue }
            let activityState = activityStates[sessionId]
            let pr = links[i].worktreeLink?.branch.flatMap { prs[$0] }
            let hasWorktree = links[i].worktreeLink?.branch != nil && worktreeBranches.contains(links[i].worktreeLink!.branch!)

            update(
                link: &links[i],
                activityState: activityState,
                pr: pr,
                hasWorktree: hasWorktree
            )
        }
    }
}
