import Foundation

/// Pure reconciliation logic: matches discovered resources to existing cards,
/// preventing duplicate card creation (the "triplication bug").
///
/// Responsibilities:
/// - Match discovered sessions to existing cards (by sessionId → tmux name → worktree branch)
/// - Create new cards for truly unmatched sessions
/// - Match discovered worktrees to existing cards (by branch)
/// - Create orphan worktree cards for unmatched worktrees
/// - Add/update PR links via branch matching
/// - Clear dead tmux and worktree links
///
/// NOT responsible for: column assignment, activity detection, GitHub issue syncing.
public enum CardReconciler {

    /// A point-in-time snapshot of all discovered external resources.
    public struct DiscoverySnapshot: Sendable {
        public let sessions: [Session]
        public let tmuxSessions: [TmuxSession]
        public let worktrees: [String: [Worktree]]     // repoRoot → worktrees
        public let pullRequests: [String: PullRequest]  // branch → PR

        public init(
            sessions: [Session] = [],
            tmuxSessions: [TmuxSession] = [],
            worktrees: [String: [Worktree]] = [:],
            pullRequests: [String: PullRequest] = [:]
        ) {
            self.sessions = sessions
            self.tmuxSessions = tmuxSessions
            self.worktrees = worktrees
            self.pullRequests = pullRequests
        }
    }

    /// Reconcile existing cards with discovered resources.
    /// Returns the merged list of links (some updated, some new, some with cleared links).
    public static func reconcile(existing: [Link], snapshot: DiscoverySnapshot) -> [Link] {
        var linksById: [String: Link] = [:]
        for link in existing {
            linksById[link.id] = link
        }

        // Build reverse indexes for matching
        var cardIdBySessionId: [String: String] = [:]
        var cardIdByTmuxName: [String: String] = [:]
        var cardIdsByBranch: [String: [String]] = [:]

        for link in existing {
            if let sid = link.sessionLink?.sessionId {
                cardIdBySessionId[sid] = link.id
            }
            if let tmux = link.tmuxLink?.sessionName {
                cardIdByTmuxName[tmux] = link.id
            }
            if let branch = link.worktreeLink?.branch {
                cardIdsByBranch[branch, default: []].append(link.id)
            }
        }

        // Track which sessions we've matched so we can detect new ones
        var matchedSessionIds: Set<String> = []

        // A. Match sessions to existing cards
        for session in snapshot.sessions {
            let cardId = findCardForSession(
                session: session,
                cardIdBySessionId: cardIdBySessionId,
                cardIdByTmuxName: cardIdByTmuxName,
                cardIdsByBranch: cardIdsByBranch,
                linksById: linksById
            )

            if let cardId, var link = linksById[cardId] {
                // Update existing card with session data
                if link.sessionLink == nil {
                    // First time linking session to this card
                    link.sessionLink = SessionLink(
                        sessionId: session.id,
                        sessionPath: session.jsonlPath
                    )
                    cardIdBySessionId[session.id] = link.id
                } else {
                    // Update existing session link
                    link.sessionLink?.sessionPath = session.jsonlPath
                }
                link.lastActivity = session.modifiedTime
                if link.projectPath == nil, let pp = session.projectPath {
                    link.projectPath = pp
                }
                linksById[cardId] = link
                matchedSessionIds.insert(session.id)
            } else {
                // Truly new session — create discovered card
                let newLink = Link(
                    projectPath: session.projectPath,
                    column: .allSessions,
                    lastActivity: session.modifiedTime,
                    source: .discovered,
                    sessionLink: SessionLink(
                        sessionId: session.id,
                        sessionPath: session.jsonlPath
                    )
                )
                linksById[newLink.id] = newLink
                cardIdBySessionId[session.id] = newLink.id
                matchedSessionIds.insert(session.id)
            }
        }

        // B. Match worktrees to existing cards
        let liveTmuxNames = Set(snapshot.tmuxSessions.map(\.name))
        var liveWorktreePaths: Set<String> = []
        let didScanWorktrees = !snapshot.worktrees.isEmpty

        for (_, worktrees) in snapshot.worktrees {
            for worktree in worktrees {
                guard !worktree.isBare else { continue }
                liveWorktreePaths.insert(worktree.path)

                guard let branch = worktree.branch else { continue }
                // Skip main/master branches — they're not worktrees we track
                let baseName = branch.replacingOccurrences(of: "refs/heads/", with: "")
                if baseName == "main" || baseName == "master" { continue }

                let existingCardIds = cardIdsByBranch[baseName] ?? []
                if existingCardIds.isEmpty {
                    // Orphan worktree — create a new card
                    let newLink = Link(
                        column: .allSessions,
                        source: .discovered,
                        worktreeLink: WorktreeLink(path: worktree.path, branch: baseName)
                    )
                    linksById[newLink.id] = newLink
                    cardIdsByBranch[baseName, default: []].append(newLink.id)
                } else {
                    // Update existing card's worktree path
                    for cardId in existingCardIds {
                        if var link = linksById[cardId] {
                            link.worktreeLink?.path = worktree.path
                            linksById[cardId] = link
                        }
                    }
                }
            }
        }

        // C. Match PRs to existing cards via branch
        for (branch, pr) in snapshot.pullRequests {
            let cardIds = cardIdsByBranch[branch] ?? []
            for cardId in cardIds {
                if var link = linksById[cardId] {
                    link.prLink = PRLink(number: pr.number)
                    linksById[cardId] = link
                }
            }
        }

        // D. Clear dead links
        for (id, var link) in linksById {
            var changed = false

            // Clear dead tmux links (tmux session no longer exists)
            if let tmuxName = link.tmuxLink?.sessionName,
               !link.manualOverrides.tmuxSession,
               !liveTmuxNames.contains(tmuxName) {
                link.tmuxLink = nil
                changed = true
            }

            // Clear dead worktree links (path no longer exists on disk)
            if let wtPath = link.worktreeLink?.path,
               !wtPath.isEmpty,
               !link.manualOverrides.worktreePath,
               didScanWorktrees, // only clear if we actually scanned worktrees
               !liveWorktreePaths.contains(wtPath) {
                link.worktreeLink = nil
                changed = true
            }

            if changed {
                linksById[id] = link
            }
        }

        return Array(linksById.values)
    }

    // MARK: - Private

    /// Find an existing card that should own this session.
    /// Match priority: exact sessionId → tmux name → worktree branch.
    private static func findCardForSession(
        session: Session,
        cardIdBySessionId: [String: String],
        cardIdByTmuxName: [String: String],
        cardIdsByBranch: [String: [String]],
        linksById: [String: Link]
    ) -> String? {
        // 1. Exact match by sessionId
        if let cardId = cardIdBySessionId[session.id] {
            return cardId
        }

        // 2. Match by worktree branch (session has gitBranch matching a card's worktreeLink)
        if let branch = session.gitBranch {
            let baseName = branch.replacingOccurrences(of: "refs/heads/", with: "")
            if let cardIds = cardIdsByBranch[baseName] {
                // Prefer cards that don't already have a session (pending cards)
                let pendingCards = cardIds.filter { linksById[$0]?.sessionLink == nil }
                if let cardId = pendingCards.first { return cardId }
                // Otherwise use the first match
                if let cardId = cardIds.first { return cardId }
            }
        }

        // 3. Match by project path + tmux (card has tmuxLink, same project, no sessionLink yet)
        if let projectPath = session.projectPath {
            for (_, link) in linksById {
                if link.tmuxLink != nil,
                   link.sessionLink == nil,
                   link.projectPath == projectPath {
                    return link.id
                }
            }
        }

        return nil
    }
}
